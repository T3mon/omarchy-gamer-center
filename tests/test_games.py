"""Tests for bin/gamercenter-games against fake app-menu folders.

    python3 -m unittest discover -s tests
"""

import importlib.machinery
import importlib.util
import os
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("gamercenter_games", str(REPO / "bin" / "gamercenter-games"))
spec = importlib.util.spec_from_loader(loader.name, loader)
games = importlib.util.module_from_spec(spec)
spec.loader.exec_module(games)


def desktop(folder, name, body):
    path = Path(folder) / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("[Desktop Entry]\nType=Application\n" + body)
    return path


class Scan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.home = self.root / "home"
        self.user = self.home / ".local/share/applications"
        self.system = self.root / "usr/share/applications"
        self.home.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def scan(self):
        return games.scan([str(self.user), str(self.system)], str(self.home))

    def test_games_only(self):
        desktop(self.user, "game.desktop", "Name=A Game\nComment=Fun\x07 times\nIcon=a-game\nExec=/bin/true\nCategories=Game;\n")
        desktop(self.user, "editor.desktop", "Name=Editor\nExec=/bin/true\nCategories=Utility;\n")
        desktop(self.user, "gamer.desktop", "Name=Not quite\nExec=/bin/true\nCategories=Gamer;\n")
        desktop(self.user, "hidden.desktop", "Name=Hidden\nExec=/bin/true\nCategories=Game;\nNoDisplay=true\n")
        desktop(self.user, "gone.desktop", "Name=Gone\nTryExec=/nonexistent/game\nExec=/nonexistent/game\nCategories=Game;\n")
        desktop(self.user, "noname.desktop", "Exec=/bin/true\nCategories=Game;\n")
        self.assertEqual(self.scan(), [{"id": "game.desktop", "name": "A Game", "comment": "Fun times",
                                        "icon": "a-game", "folder": "", "size": 0}])

    def test_steam_games_are_left_to_the_steam_tabs(self):
        desktop(self.system, "steam.desktop", "Name=Steam\nExec=/usr/bin/steam %U\nCategories=Network;Game;\n")
        desktop(self.user, "Probably Stolen.desktop", "Name=Probably Stolen\nExec=steam steam://rungameid/4348910\nCategories=Game;\n")
        desktop(self.user, "other.desktop", "Name=Other\nExec=xdg-open steam://rungameid/1\nCategories=Game;\n")
        self.assertEqual(self.scan(), [])

    def test_the_first_entry_for_an_id_wins(self):
        desktop(self.user, "game.desktop", "Name=Mine\nCategories=Utility;\n")
        desktop(self.system, "game.desktop", "Name=System\nCategories=Game;\n")
        desktop(self.system, "kde/chess.desktop", "Name=Chess\nCategories=Game;BoardGame;\n")
        self.assertEqual([g["id"] for g in self.scan()], ["kde-chess.desktop"])

    def test_folder_and_size(self):
        install = self.root / "games/Rent Day"
        (install / "data").mkdir(parents=True)
        (install / "game.bin").write_bytes(b"x" * 100)
        (install / "data/pak").write_bytes(b"x" * 50)
        os.symlink("/usr", install / "link")
        icon = install / "icon.png"
        icon.write_bytes(b"png")
        desktop(self.user, "rent.desktop", f"Name=Rent Day\nPath={install}\nIcon={icon}\nCategories=Game;\n")
        desktop(self.user, "home.desktop", f"Name=At home\nPath={self.home}\nIcon=/etc/passwd\nCategories=Game;\n")
        desktop(self.user, "root.desktop", "Name=At root\nPath=/\nIcon=../x\nCategories=Game;\n")
        found = {g["id"]: g for g in self.scan()}
        self.assertEqual((found["rent.desktop"]["folder"], found["rent.desktop"]["size"], found["rent.desktop"]["icon"]),
                         (str(install), 153, str(icon)))
        for other in ("home.desktop", "root.desktop"):
            self.assertEqual((found[other]["folder"], found[other]["size"], found[other]["icon"]), ("", 0, ""))

    def test_only_the_main_group_and_plain_keys_count(self):
        desktop(self.user, "game.desktop", "Name=Game\nName[de]=Spiel\nCategories=Game;\n\n[Desktop Action x]\nName=Action\nNoDisplay=true\n")
        desktop(self.user, "bad id;.desktop", "Name=Bad\nCategories=Game;\n")
        self.assertEqual([g["name"] for g in self.scan()], ["Game"])


if __name__ == "__main__":
    unittest.main()
