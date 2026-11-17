"""Tests for bin/gamercenter-steam against a fake Steam folder built in a
temp dir: text manifests, binary appinfo.vdf and packageinfo.vdf, and a
scrambled license cache. Nothing outside the temp dir is read.

    python3 -m unittest discover -s tests
"""

import importlib.machinery
import importlib.util
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "bin" / "gamercenter-steam"

loader = importlib.machinery.SourceFileLoader("gamercenter_steam", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
steam = importlib.util.module_from_spec(spec)
spec.loader.exec_module(steam)

ACCOUNT = 12345678
STEAMID = str(steam.STEAMID64_BASE + ACCOUNT)

# App ids
MANOR, TEAMFIGHT, PROTON, RIMWORLD, REFUNDED, DLC = 1363080, 1372810, 1493710, 294100, 400, 500
APPS = {
    MANOR: ("Manor Lords", "Game"),
    TEAMFIGHT: ("Teamfight Manager", "game"),
    PROTON: ("Proton 9.0", "Tool"),
    RIMWORLD: ("RimWorld", "Game"),
    REFUNDED: ("Refunded Game", "Game"),
    DLC: ("Some DLC", "DLC"),
}
# Package id -> app ids, and the license flags the account holds for it.
PACKAGES = {10: [MANOR], 11: [TEAMFIGHT], 12: [RIMWORLD, DLC], 13: [REFUNDED]}
LICENSES = {10: 0, 11: 0, 12: 0, 13: 0x10}   # 13 was refunded (CancelledByUser)


def text_vdf(name, body, indent=0):
    pad = "\t" * indent
    out = '%s"%s"\n%s{\n' % (pad, name, pad)
    for key, value in body.items():
        if isinstance(value, dict):
            out += text_vdf(key, value, indent + 1)
        else:
            out += '%s\t"%s"\t\t"%s"\n' % (pad, key, value)
    return out + "%s}\n" % pad


def kv_bytes(node, strings=None):
    """Binary KeyValues: cstring keys, or indexes into strings when given."""
    out = b""
    for key, value in node.items():
        if strings is not None:
            if key not in strings:
                strings.append(key)
            name = struct.pack("<I", strings.index(key))
        else:
            name = key.encode() + b"\0"
        if isinstance(value, dict):
            out += b"\x00" + name + kv_bytes(value, strings)
        elif isinstance(value, int):
            out += b"\x02" + name + struct.pack("<i", value)
        else:
            out += b"\x01" + name + value.encode() + b"\0"
    return out + b"\x08"


def appinfo_bytes(apps, covers=None, decks=None, extra=None):
    """covers: app id -> the capsule file appinfo names for it. decks: app id -> Deck category.
    extra: app id -> more keys for the appinfo node (depots, extended) and "oslist"."""
    strings, body = [], b""
    for appid, (name, kind) in apps.items():
        more = dict((extra or {}).get(appid, {}))
        common = {"name": name, "type": kind}
        if "oslist" in more:
            common["oslist"] = more.pop("oslist")
        if covers and appid in covers:
            common["library_assets_full"] = {"library_capsule": {"image": {"english": covers[appid]}}}
        if decks and appid in decks:
            block = decks[appid]
            common["steam_deck_compatibility"] = block if isinstance(block, dict) else {"category": block, "tests": {"0": {"display": 4}}}
        kv = kv_bytes({"appinfo": dict({"appid": appid, "common": common}, **more)}, strings)
        body += struct.pack("<II", appid, 60 + len(kv)) + b"\0" * 60 + kv
    body += struct.pack("<I", 0)
    table = 16 + len(body)
    tail = struct.pack("<I", len(strings)) + b"".join(s.encode() + b"\0" for s in strings)
    return struct.pack("<IIq", 0x07564429, 1, table) + body + tail


def packageinfo_bytes(packages):
    out = struct.pack("<II", 0x06565528, 1)
    for package, appids in packages.items():
        kv = kv_bytes({str(package): {"packageid": package, "appids": {str(i): a for i, a in enumerate(appids)}}})
        out += struct.pack("<I", package) + b"\0" * 20 + struct.pack("<I", 1) + b"\0" * 8 + kv
    return out + struct.pack("<I", 0xFFFFFFFF)


def varint(value):
    out = b""
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out += bytes([byte | 0x80])
        else:
            return out + bytes([byte])


def licensecache_bytes(licenses, account):
    body = b""
    for package, flags in licenses.items():
        inner = b"\x08" + varint(package) + b"\x38" + varint(flags)   # field 1 and field 7, varints
        body += b"\x12" + varint(len(inner)) + inner                    # field 2, length-delimited
    plain = body + struct.pack("<I", zlib.crc32(body))
    return steam.scramble(plain, account)


class FakeSteam:
    def __init__(self, base):
        self.root = os.path.join(base, "Steam")
        self.extra = os.path.join(base, "games")
        self.user = os.path.join(self.root, "userdata", str(ACCOUNT), "config")
        for path in (os.path.join(self.root, "steamapps"), os.path.join(self.extra, "steamapps"),
                     os.path.join(self.root, "config"), os.path.join(self.root, "appcache"), self.user):
            os.makedirs(path, exist_ok=True)
        self.write("steamapps/libraryfolders.vdf", text_vdf("libraryfolders", {
            "0": {"path": self.root, "label": ""},
            "1": {"path": self.extra, "label": "Games disk"},
        }))
        self.manifest(self.root, MANOR, "Manor Lords", 15544958400, last=1700000100)
        self.manifest(self.root, PROTON, "Proton 9.0", 900000000)
        self.manifest(self.extra, TEAMFIGHT, "Teamfight Manager", 930184933, last=10)
        self.write("config/loginusers.vdf", text_vdf("users", {STEAMID: {"AccountName": "x", "MostRecent": "1"}}))
        self.write("userdata/%d/config/localconfig.vdf" % ACCOUNT, text_vdf("UserLocalConfigStore", {
            "Software": {"Valve": {"Steam": {"apps": {
                str(MANOR): {"LastPlayed": "1700000000", "Playtime": "1781", "LaunchOptions": "mangohud\x07 %command%"},
                str(TEAMFIGHT): {"LastPlayed": "1700000500", "Playtime": "726"},
                str(RIMWORLD): {"LastPlayed": "1600000000", "Playtime": "6000"},
            }}}}}))
        self.write_bytes("appcache/appinfo.vdf", appinfo_bytes(APPS))
        self.write_bytes("appcache/packageinfo.vdf", packageinfo_bytes(PACKAGES))
        self.write_bytes("userdata/%d/config/licensecache" % ACCOUNT, licensecache_bytes(LICENSES, ACCOUNT))

    def manifest(self, library, appid, name, size, last=0, installdir=None, **more):
        path = os.path.join(library, "steamapps", "appmanifest_%d.acf" % appid)
        state = {"appid": appid, "name": name, "StateFlags": 4, "SizeOnDisk": size, "LastPlayed": last}
        state.update(more)
        if installdir is not None:
            state["installdir"] = installdir
        with open(path, "w") as handle:
            handle.write(text_vdf("AppState", state))

    def write(self, rel, text):
        with open(os.path.join(self.root, rel), "w") as handle:
            handle.write(text)

    def write_bytes(self, rel, data):
        path = os.path.join(self.root, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as handle:
            handle.write(data)


def run(root):
    out = subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), "--root", root],
                         capture_output=True, text=True, timeout=30)
    return json.loads(out.stdout)


class SteamLibraryTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.fake = FakeSteam(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def games(self):
        return {g["name"]: g for g in steam.library(self.fake.root)["games"]}

    def test_installed_and_owned_games_are_listed(self):
        games = self.games()
        self.assertEqual(sorted(games), ["Manor Lords", "RimWorld", "Teamfight Manager"])
        manor = games["Manor Lords"]
        self.assertTrue(manor["installed"])
        self.assertEqual((manor["id"], manor["size"], manor["playtime"]), (str(MANOR), 15544958400, 1781))
        self.assertEqual(manor["lastPlayed"], 1700000100)   # the manifest's is newer than localconfig's
        self.assertEqual(games["Teamfight Manager"]["lastPlayed"], 1700000500)
        rim = games["RimWorld"]
        self.assertFalse(rim["installed"])
        self.assertEqual((rim["size"], rim["drive"], rim["playtime"]), (0, -1, 6000))

    def test_tools_dlc_and_refunds_are_left_out(self):
        names = self.games()
        for name in ("Proton 9.0", "Some DLC", "Refunded Game"):
            self.assertNotIn(name, names)

    def test_drives_share_a_disk(self):
        data = steam.library(self.fake.root)
        # Both library folders sit in the same temp filesystem: one drive.
        self.assertEqual(len(data["drives"]), 1)
        drive = data["drives"][0]
        self.assertEqual(drive["label"], "Steam")
        self.assertEqual((drive["games"], drive["used"]), (2, 15544958400 + 930184933))
        self.assertGreater(drive["total"], 0)
        self.assertLessEqual(drive["free"], drive["total"])
        self.assertTrue(all(g["drive"] == 0 for g in data["games"] if g["installed"]))

    def test_without_the_license_cache_every_cached_package_counts(self):
        os.remove(os.path.join(self.fake.user, "licensecache"))
        self.assertIn("Refunded Game", self.games())

    def test_a_license_cache_with_a_bad_checksum_is_ignored(self):
        path = os.path.join(self.fake.user, "licensecache")
        data = bytearray(Path(path).read_bytes())
        data[3] ^= 0xFF
        Path(path).write_bytes(bytes(data))
        self.assertIsNone(steam.load_licenses(self.fake.root, str(ACCOUNT)))
        self.assertIn("Refunded Game", self.games())

    def test_damaged_binary_files_still_list_installed_games(self):
        self.fake.write_bytes("appcache/appinfo.vdf", b"\x29\x44\x56\x07" + os.urandom(64))
        self.fake.write_bytes("appcache/packageinfo.vdf", b"garbage")
        games = self.games()
        self.assertIn("Manor Lords", games)
        self.assertIn("Teamfight Manager", games)
        self.assertNotIn("RimWorld", games)

    def test_control_characters_are_stripped_from_names(self):
        self.fake.manifest(self.fake.root, 777, "Bad\x1b[31m\nName", 1)
        self.assertIn("Bad [31m Name", self.games())

    def test_covers_come_from_steams_own_cache(self):
        sha = "0123456789abcdef0123456789abcdef01234567"
        cache = "appcache/librarycache/%d/"
        # Manor Lords: the file appinfo names. Teamfight: the older fixed name.
        # RimWorld: appinfo names nothing, a hashed folder holds one.
        self.fake.write_bytes(cache % MANOR + sha + "/library_capsule.jpg", b"jpg")
        self.fake.write_bytes(cache % MANOR + "library_600x900.jpg", b"older")
        self.fake.write_bytes(cache % TEAMFIGHT + "library_600x900.jpg", b"jpg")
        self.fake.write_bytes(cache % RIMWORLD + "f" * 40 + "/library_capsule.jpg", b"jpg")
        self.fake.write_bytes("appcache/appinfo.vdf", appinfo_bytes(APPS, {MANOR: sha + "/library_capsule.jpg"}))
        games = self.games()
        base = os.path.join(self.fake.root, "appcache", "librarycache")
        self.assertEqual(games["Manor Lords"]["cover"], os.path.join(base, str(MANOR), sha, "library_capsule.jpg"))
        self.assertEqual(games["Teamfight Manager"]["cover"], os.path.join(base, str(TEAMFIGHT), "library_600x900.jpg"))
        self.assertEqual(games["RimWorld"]["cover"], os.path.join(base, str(RIMWORLD), "f" * 40, "library_capsule.jpg"))

    def test_no_cover_without_cached_art_and_no_paths_out_of_the_cache(self):
        outside = os.path.join(self.tmp.name, "secret.jpg")
        Path(outside).write_bytes(b"x")
        self.fake.write_bytes("appcache/appinfo.vdf", appinfo_bytes(APPS, {
            MANOR: "../../../../secret.jpg", TEAMFIGHT: "/etc/passwd.jpg"}))
        os.makedirs(os.path.join(self.fake.root, "appcache", "librarycache", str(MANOR)))
        games = self.games()
        self.assertEqual(games["Manor Lords"]["cover"], "")
        self.assertEqual(games["Teamfight Manager"]["cover"], "")
        self.assertEqual(games["RimWorld"]["cover"], "")
        for bad in ("../x.jpg", "a/b.jpg", "x.svg", "%s/x.jpg" % ("g" * 40), ""):
            self.assertEqual(steam.capsule_asset({"library_assets_full": {"library_capsule": {"image": {"english": bad}}}}), "")

    def test_deck_status_comes_from_appinfo(self):
        self.fake.write_bytes("appcache/appinfo.vdf", appinfo_bytes(APPS, decks={MANOR: 2, TEAMFIGHT: 9}))
        games = self.games()
        self.assertEqual([games[n]["deck"] for n in ("Manor Lords", "Teamfight Manager", "RimWorld")], [2, 0, 0])

    def test_launch_options_come_from_localconfig(self):
        games = self.games()
        self.assertEqual(games["Manor Lords"]["launchOptions"], "mangohud  %command%")
        self.assertEqual(games["RimWorld"]["launchOptions"], "")

    def test_install_folder_is_a_real_folder_under_steamapps_common(self):
        os.makedirs(os.path.join(self.fake.root, "steamapps", "common", "Manor Lords"))
        os.makedirs(os.path.join(self.fake.extra, "steamapps", "common"))
        os.symlink(self.tmp.name, os.path.join(self.fake.extra, "steamapps", "common", "Teamfight"))
        self.fake.manifest(self.fake.root, MANOR, "Manor Lords", 1, installdir="Manor Lords")
        self.fake.manifest(self.fake.extra, TEAMFIGHT, "Teamfight Manager", 1, installdir="Teamfight")
        games = self.games()
        self.assertEqual(games["Manor Lords"]["folder"], os.path.join(self.fake.root, "steamapps", "common", "Manor Lords"))
        self.assertEqual(games["Teamfight Manager"]["folder"], "")      # a link out of the library
        self.assertEqual(games["RimWorld"]["folder"], "")
        for bad in ("..", ".", "", "a/../../x", "x\n", "Missing", None, 5):
            self.assertEqual(steam.game_folder(self.fake.root, bad), "")

    def test_build_update_and_workshop_come_from_the_manifests(self):
        self.fake.manifest(self.fake.root, MANOR, "Manor Lords", 100, buildid=26185246, LastUpdated=1794746039,
                           StateFlags=6, TargetBuildID=26185300)
        self.fake.manifest(self.fake.extra, TEAMFIGHT, "Teamfight Manager", 100, StateFlags=4 | 0x100000,
                           BytesToDownload=200, BytesDownloaded=50)
        self.fake.write_bytes("steamapps/workshop/appworkshop_%d.acf" % MANOR, text_vdf("AppWorkshop", {
            "SizeOnDisk": 5000, "NeedsUpdate": "1",
            "WorkshopItemsInstalled": {"1": {"size": 1}, "2": {"size": 2}, "x": {}}}).encode())
        games = self.games()
        manor, team = games["Manor Lords"], games["Teamfight Manager"]
        self.assertEqual((manor["build"], manor["updated"], manor["update"], manor["workshop"], manor["mods"]),
                         ("26185246", 1794746039, "required", 5000, 2))
        self.assertEqual((team["update"], team["progress"], team["build"]), ("downloading", 25, ""))
        self.assertEqual(games["RimWorld"]["update"], "")
        self.assertEqual(steam.update_state({"StateFlags": "4"}, {"NeedsDownload": "1"}), ["mods", 0])
        self.assertEqual(steam.update_state({"StateFlags": str(4 | 0x200), "BytesToDownload": "10",
                                             "BytesDownloaded": "10"}), ["paused", 100])

    def test_linux_native_or_proton(self):
        extra = {MANOR: {"oslist": "windows", "depots": {"1363081": {"config": {"oslist": "windows"}}}},
                 TEAMFIGHT: {"oslist": "windows,linux", "depots": {"1372811": {"config": {"oslist": "linux"}}}},
                 RIMWORLD: {"oslist": "windows,macos,linux"}}
        self.fake.write_bytes("appcache/appinfo.vdf", appinfo_bytes(APPS, extra=extra))
        self.fake.manifest(self.fake.root, MANOR, "Manor Lords", 1, InstalledDepots={"1363081": {"size": 1}})
        self.fake.manifest(self.fake.extra, TEAMFIGHT, "Teamfight Manager", 1, InstalledDepots={"1372811": {"size": 1}})
        prefix = os.path.join(self.fake.root, "steamapps/compatdata/%d" % MANOR)
        os.makedirs(prefix)
        Path(prefix, "version").write_text("11.0-100\n")
        Path(prefix, "config_info").write_text("11.0-100\n/x/steamapps/common/Proton - Experimental/files/share/fonts/\n")
        games = self.games()
        self.assertEqual((games["Manor Lords"]["platform"], games["Manor Lords"]["proton"]),
                         ("proton", "Proton - Experimental 11.0-100"))
        self.assertEqual((games["Teamfight Manager"]["platform"], games["Teamfight Manager"]["proton"]), ("linux", ""))
        self.assertEqual(games["RimWorld"]["platform"], "linux")
        self.fake.write("config/config.vdf", text_vdf("InstallConfigStore", {"Software": {"Valve": {"Steam": {
            "CompatToolMapping": {"0": {"name": "proton_9"}, str(TEAMFIGHT): {"name": "GE-Proton9-20\x07"}}}}}}))
        team = self.games()["Teamfight Manager"]
        self.assertEqual((team["platform"], team["forcedTool"]), ("proton", "GE-Proton9-20"))
        self.assertEqual(self.games()["Manor Lords"]["forcedTool"], "")

    def test_dlc_owned_installed_or_missing(self):
        apps = {**APPS, 600: ("Missing DLC", "DLC"), 700: ("Unlock DLC", "DLC")}
        extra = {RIMWORLD: {"extended": {"listofdlc": "%d,600,700,999" % DLC},
                            "depots": {"5001": {"dlcappid": DLC}}}}
        self.fake.write_bytes("appcache/appinfo.vdf", appinfo_bytes(apps, extra=extra))
        packages = {**PACKAGES, 14: [700]}
        self.fake.write_bytes("appcache/packageinfo.vdf", packageinfo_bytes(packages))
        self.fake.write_bytes("userdata/%d/config/licensecache" % ACCOUNT, licensecache_bytes({**LICENSES, 14: 0}, ACCOUNT))
        dlc = lambda: [(d["name"], d["state"]) for d in self.games()["RimWorld"]["dlc"]]
        self.assertEqual(dlc(), [("Some DLC", "owned"), ("Missing DLC", "missing"), ("Unlock DLC", "owned")])
        self.fake.manifest(self.fake.root, RIMWORLD, "RimWorld", 1, InstalledDepots={"5001": {"size": 1}})
        self.assertEqual(dlc()[0], ("Some DLC", "installed"))

    def test_favorites_come_from_the_collections_cache(self):
        folder = "userdata/%d/config/cloudstorage/" % ACCOUNT
        fav = lambda added: ["user-collections.favorite", {"key": "x", "value": json.dumps({"added": added})}]
        self.fake.write_bytes(folder + "cloud-storage-namespace-1.json", json.dumps([fav([MANOR, "x"])]).encode())
        self.assertEqual([n for n, g in self.games().items() if g["favorite"]], ["Manor Lords"])
        self.fake.write_bytes(folder + "cloud-storage-namespace-1.modified.json", json.dumps([fav([RIMWORLD])]).encode())
        self.assertEqual([n for n, g in self.games().items() if g["favorite"]], ["RimWorld"])
        self.fake.write_bytes(folder + "cloud-storage-namespace-1.modified.json", b"not json")
        self.assertEqual([n for n, g in self.games().items() if g["favorite"]], ["Manor Lords"])

    def test_steam_status(self):
        self.fake.write("config/loginusers.vdf", text_vdf("users", {STEAMID: {"PersonaName": "Temon\x07", "MostRecent": "1"}}))
        proc = os.path.join(self.tmp.name, "proc")
        os.makedirs(os.path.join(proc, "42"))
        Path(proc, "42", "comm").write_text("steam\n")
        pidfile = os.path.join(self.tmp.name, "steam.pid")
        Path(pidfile).write_text("42\n")
        self.assertEqual(steam.steam_status(self.fake.root, pidfile, proc), {"running": True, "persona": "Temon"})
        Path(proc, "42", "comm").write_text("bash\n")
        self.assertFalse(steam.steam_status(self.fake.root, pidfile, proc)["running"])
        self.assertFalse(steam.steam_status(self.fake.root, os.path.join(self.tmp.name, "none"), proc)["running"])

    def test_sizes_walk_the_prefix_and_shader_cache(self):
        for part, size in (("compatdata", 300), ("shadercache", 20)):
            folder = os.path.join(self.fake.root, "steamapps", part, str(MANOR), "sub")
            os.makedirs(folder)
            Path(folder, "f").write_bytes(b"x" * size)
        sizes = steam.extra_sizes(self.fake.root)
        self.assertEqual(sizes[str(MANOR)], [300, 20])
        self.assertEqual(sizes[str(TEAMFIGHT)], [0, 0])

    def test_deck_report_has_every_rating_test_and_setting(self):
        block = {
            "category": 2, "steam_machine_compatibility": 3, "steamos_compatibility": 2,
            "test_timestamp": 1667865600, "tested_build_id": 9679726,
            "tests": {"0": {"display": 3, "token": "#SteamDeckVerified_TestResult_InterfaceTextIsNotLegible"},
                      "1": {"display": 4, "token": "#SteamDeckVerified_TestResult_DefaultConfigurationIsPerformant"},
                      "2": {"display": 4, "token": "#Bad Token; rm -rf"}},
            "steamos_tests": {"0": {"display": 1, "token": "#SteamOS_TestResult_GameStartupFunctional"}},
            "configuration": {"small_text": 1, "recommended_runtime": "proton-stable", "Bad-Key": 1},
        }
        self.fake.write_bytes("appcache/appinfo.vdf", appinfo_bytes(APPS, decks={MANOR: block}))
        report = steam.deck_report(self.fake.root, MANOR)
        self.assertEqual((report["deck"], report["machine"], report["steamos"]), (2, 3, 2))
        self.assertEqual((report["testedAt"], report["testedBuild"]), (1667865600, "9679726"))
        self.assertEqual([t["result"] for t in report["results"]["deck"]],
                         ["InterfaceTextIsNotLegible", "DefaultConfigurationIsPerformant"])
        self.assertEqual(report["results"]["steamos"], [{"result": "GameStartupFunctional", "display": 1}])
        self.assertEqual(report["results"]["machine"], [])
        self.assertEqual(report["config"], {"small_text": "1", "recommended_runtime": "proton-stable"})
        self.assertEqual(self.games()["Manor Lords"]["steamos"], 2)
        self.assertEqual(self.games()["Teamfight Manager"]["steamos"], 0)
        self.assertIsNone(steam.deck_report(self.fake.root, RIMWORLD))
        self.assertIsNone(steam.deck_report(self.fake.root, 123456))

    def test_scramble_is_its_own_inverse(self):
        data = os.urandom(200)
        self.assertEqual(steam.scramble(steam.scramble(data, ACCOUNT), ACCOUNT), data)
        self.assertNotEqual(steam.scramble(data, ACCOUNT), data)

    def test_the_command_line_prints_json_and_writes_nothing(self):
        before = sorted(str(p) for p in Path(self.tmp.name).rglob("*"))
        data = run(self.fake.root)
        self.assertTrue(data["ok"])
        self.assertIsInstance(data["uwsm"], bool)
        self.assertEqual(len(data["games"]), 3)
        self.assertEqual(sorted(str(p) for p in Path(self.tmp.name).rglob("*")), before)

    def test_no_steam_folder(self):
        self.assertEqual(run(os.path.join(self.tmp.name, "nowhere")), {"ok": False, "error": "steam-not-found"})


if __name__ == "__main__":
    unittest.main()
