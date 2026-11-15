"""Tests for bin/gamercenter-deals with Steam's answers faked: nothing goes
out to the network.

    python3 -m unittest discover -s tests
"""

import importlib.machinery
import importlib.util
import json
import unittest
import urllib.parse
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("gamercenter_deals", str(REPO / "bin" / "gamercenter-deals"))
spec = importlib.util.spec_from_loader(loader.name, loader)
deals = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deals)


def row(appid, title, final="0,00₴", initial="400,00₴"):
    return (f'<a href="https://store.steampowered.com/app/{appid}/x/" data-ds-appid="{appid}" '
            f'class="search_result_row ds_collapse_flag " data-gpnav="item">'
            f'<div class="search_name ellipsis"><span class="title">{title}</span></div>'
            f'<div class="discount_original_price">{initial}</div>'
            f'<div class="discount_final_price">{final}</div></a>')


SEARCH = {"success": 1, "results_html": "\n".join([
    row("10", "Free &amp; Easy"),
    row("10", "Duplicate"),
    row("11,12", "A Bundle"),
    row("13", ""),
    row("14", "<b>Bold</b>\x07 Name"),
])}


class Steam:
    """Answers by URL, and counts the calls."""

    def __init__(self, wishlist, prices, names):
        self.wishlist, self.prices, self.names, self.urls = wishlist, prices, names, []

    def __call__(self, url):
        self.urls.append(url)
        if url == deals.FREE_URL:
            return SEARCH
        if url.startswith(deals.WISHLIST_URL):
            return {"response": {"items": [{"appid": a} for a in self.wishlist]}}
        if url.startswith(deals.PRICES_URL):
            ids = url[len(deals.PRICES_URL):].split(",")
            return {a: self.prices[a] for a in ids if a in self.prices}
        if url.startswith(deals.NAMES_URL):
            request = json.loads(urllib.parse.unquote(url[len(deals.NAMES_URL):]))
            ids = [str(i["appid"]) for i in request["ids"]]
            return {"response": {"store_items": [{"appid": int(a), "name": self.names[a]} for a in ids if a in self.names]}}
        raise AssertionError(url)


def price(discount, final="50₴", initial="100₴"):
    return {"success": True, "data": {"price_overview": {"discount_percent": discount,
                                                         "final_formatted": final, "initial_formatted": initial}}}


class FreeGames(unittest.TestCase):
    def test_rows_become_games(self):
        games = deals.parse_free(SEARCH)
        self.assertEqual([g["id"] for g in games], ["10", "14"])
        self.assertEqual(games[0], {"id": "10", "name": "Free & Easy", "discount": 100, "final": "0,00₴", "initial": "400,00₴"})
        self.assertEqual(games[1]["name"], "Bold Name")

    def test_anything_else_is_refused(self):
        for bad in (None, [], {}, {"results_html": 5}):
            with self.assertRaises(ValueError):
                deals.parse_free(bad)


class Wishlist(unittest.TestCase):
    def test_only_discounted_games_with_names(self):
        steam = Steam(["1", "2", "3", "4", "bad"],
                      {"1": price(75), "2": price(0), "3": price(50), "4": {"success": False}},
                      {"1": "Seventy Five", "3": ""})
        self.assertEqual(deals.wishlist("765", steam),
                         [{"id": "1", "name": "Seventy Five", "discount": 75, "final": "50₴", "initial": "100₴"}])
        self.assertEqual(sum(u.startswith(deals.NAMES_URL) for u in steam.urls), 1)

    def test_big_wishlists_go_in_batches(self):
        ids = [str(i) for i in range(1, 251)]
        steam = Steam(ids, {a: price(10) for a in ids}, {a: "G" + a for a in ids})
        self.assertEqual(len(deals.wishlist("765", steam)), 250)
        self.assertEqual(sum(u.startswith(deals.PRICES_URL) for u in steam.urls), 3)

    def test_odd_prices_are_dropped(self):
        self.assertEqual(deals.parse_prices({"1": price(101), "2": price("x"), "x": price(50), "3": {"success": True, "data": []}}), {})


class Reading(unittest.TestCase):
    def test_a_failed_wishlist_still_gives_the_free_games(self):
        def get(url):
            if url == deals.FREE_URL:
                return SEARCH
            raise OSError("offline")
        out = deals.deals("765", get)
        self.assertEqual((out["ok"], out["wishlistOk"], len(out["free"]), out["wishlist"]), (True, False, 2, []))

    def test_no_account_skips_the_wishlist(self):
        steam = Steam([], {}, {})
        out = deals.deals(None, steam)
        self.assertEqual((out["wishlistOk"], steam.urls), (False, [deals.FREE_URL]))


if __name__ == "__main__":
    unittest.main()
