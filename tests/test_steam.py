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


def appinfo_bytes(apps):
    strings, body = [], b""
    for appid, (name, kind) in apps.items():
        kv = kv_bytes({"appinfo": {"appid": appid, "common": {"name": name, "type": kind}}}, strings)
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
                str(MANOR): {"LastPlayed": "1700000000", "Playtime": "1781"},
                str(TEAMFIGHT): {"LastPlayed": "1700000500", "Playtime": "726"},
                str(RIMWORLD): {"LastPlayed": "1600000000", "Playtime": "6000"},
            }}}}}))
        self.write_bytes("appcache/appinfo.vdf", appinfo_bytes(APPS))
        self.write_bytes("appcache/packageinfo.vdf", packageinfo_bytes(PACKAGES))
        self.write_bytes("userdata/%d/config/licensecache" % ACCOUNT, licensecache_bytes(LICENSES, ACCOUNT))

    def manifest(self, library, appid, name, size, last=0):
        path = os.path.join(library, "steamapps", "appmanifest_%d.acf" % appid)
        with open(path, "w") as handle:
            handle.write(text_vdf("AppState", {"appid": appid, "name": name, "StateFlags": 4,
                                               "SizeOnDisk": size, "LastPlayed": last}))

    def write(self, rel, text):
        with open(os.path.join(self.root, rel), "w") as handle:
            handle.write(text)

    def write_bytes(self, rel, data):
        with open(os.path.join(self.root, rel), "wb") as handle:
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
