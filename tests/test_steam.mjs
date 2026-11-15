// node --test tests/test_steam.mjs
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../steam/Library.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const L = {}
vm.createContext(L)
vm.runInContext(source, L)

const plain = value => JSON.parse(JSON.stringify(value))

const reading = () => ({
  ok: true,
  uwsm: true,
  drives: [{ label: "Steam", free: 400, total: 500, used: 60, games: 2 }],
  games: [
    { id: "1", name: "Manor Lords", installed: true, size: 50, drive: 0, lastPlayed: 100, playtime: 1781 },
    { id: "2", name: "teamfight Manager", installed: true, size: 10, drive: 0, lastPlayed: 300, playtime: 726 },
    { id: "3", name: "RimWorld", installed: false, size: 0, drive: -1, lastPlayed: 200, playtime: 6000 },
    { id: "4", name: "Among Us", installed: false, size: 0, drive: -1, lastPlayed: 0, playtime: 0 }
  ]
})

test("anything that isn't a library reading is refused", () => {
  for (const raw of [null, undefined, 42, "x", [], {}, { ok: false, error: "steam-not-found" },
                     { ok: true, games: [] }, { ok: true, drives: [], games: "x" }]) {
    assert.equal(L.clean(raw), null)
  }
})

test("a reading is cleaned field by field", () => {
  const data = reading()
  data.drives.push({ label: "\u001b[31mDisk\n", free: 900, total: 100 }, "junk")
  data.games.push(
    { id: "5; rm -rf ~", name: "Bad id", installed: true },
    { id: "1", name: "Duplicate", installed: true },
    { id: "6", name: "   ", installed: true },
    { id: "7", name: "<img src=\"https://example.invalid/x\">", installed: true, size: -5, drive: 9 },
    { id: "8", name: "Not on disk", installed: false, size: 999, drive: 0 },
    { id: "9", name: "Weird numbers", installed: "yes", lastPlayed: NaN, playtime: Infinity }
  )
  const c = plain(L.clean(data))
  assert.equal(c.uwsm, true)
  assert.deepEqual(c.drives.map(d => [d.label, d.free, d.total]), [["Steam", 400, 500], ["[31mDisk", 100, 100]])
  assert.deepEqual(c.games.map(g => g.id), ["1", "2", "3", "4", "7", "8", "9"])
  const markup = c.games.find(g => g.id === "7")
  assert.equal(markup.name, "<img src=\"https://example.invalid/x\">")   // shown as plain text
  assert.deepEqual([markup.size, markup.drive], [0, -1])
  const notOnDisk = c.games.find(g => g.id === "8")
  assert.deepEqual([notOnDisk.size, notOnDisk.drive], [0, -1])
  const weird = c.games.find(g => g.id === "9")
  assert.deepEqual([weird.installed, weird.lastPlayed, weird.playtime], [false, 0, 0])
  assert.equal(L.clean({ ok: true, drives: [], games: [] }).uwsm, false)
})

test("names are capped and stripped of control characters", () => {
  const data = reading()
  data.games = [{ id: "1", name: "A\u0000B\u009fC" + "x".repeat(300), installed: false }]
  const name = L.clean(data).games[0].name
  assert.equal(name.slice(0, 5), "A B C")
  assert.equal(name.length, 120)
})

test("the lists split installed from not installed and sort", () => {
  const games = L.clean(reading()).games
  const ids = (installed, sort) => plain(L.list(games, installed, sort).map(g => g.id))
  assert.deepEqual(ids(true, "recent"), ["2", "1"])
  assert.deepEqual(ids(true, "name"), ["1", "2"])        // case doesn't matter
  assert.deepEqual(ids(true, "size"), ["1", "2"])
  assert.deepEqual(ids(false, "recent"), ["3", "4"])
  assert.deepEqual(ids(false, "size"), ["4", "3"])       // no sizes: by name
  assert.deepEqual(ids(true, "bogus"), ids(true, "recent"))
  assert.deepEqual(plain(L.list(null, true, "name")), [])
  assert.equal(L.countInstalled(games, true), 2)
  assert.equal(L.countInstalled(games, false), 2)
})

test("the sort shown falls back for games that aren't installed", () => {
  assert.equal(L.sortFor("size", true), "size")
  assert.equal(L.sortFor("size", false), "name")
  assert.equal(L.sortFor("nope", false), "recent")
})

test("steam links take only known actions and digit ids", () => {
  assert.equal(L.steamUrl("run", "1363080"), "steam://rungameid/1363080")
  assert.equal(L.steamUrl("install", "1"), "steam://install/1")
  assert.equal(L.steamUrl("uninstall", "1"), "steam://uninstall/1")
  assert.equal(L.steamUrl("options", "1"), "steam://gameproperties/1")
  for (const [action, id] of [["run", "1; rm -rf ~"], ["run", ""], ["run", 5], ["run", "12345678901"],
                              ["open", "1"], ["toString", "1"], ["hasOwnProperty", "1"]]) {
    assert.equal(L.steamUrl(action, id), "")
  }
})

test("links open through uwsm-app when it is there", () => {
  assert.deepEqual(plain(L.openCommand("steam://install/1", true)), ["uwsm-app", "--", "xdg-open", "steam://install/1"])
  assert.deepEqual(plain(L.openCommand("steam://install/1", false)), ["xdg-open", "steam://install/1"])
})

test("covers are files in Steam's cover cache only", () => {
  const good = "/home/u/.local/share/Steam/appcache/librarycache/1363080/0123abc/library_capsule.jpg"
  assert.equal(L.cover(good), good)
  assert.equal(L.cover("/s/appcache/librarycache/7/library_600x900.jpg"), "/s/appcache/librarycache/7/library_600x900.jpg")
  for (const bad of [null, 5, "", "relative/appcache/librarycache/1/a.jpg", "/etc/passwd",
                     "/s/appcache/librarycache/1/../../../etc/x.jpg", "/s/appcache/librarycache/x/a.jpg",
                     "/s/appcache/librarycache/1/a.svg", "/s/appcache/librarycache/1/a\n.jpg",
                     "/s/appcache/librarycache/1/./a.jpg", "/" + "x".repeat(1100) + "/appcache/librarycache/1/a.jpg"]) {
    assert.equal(L.cover(bad), "")
  }
  const data = reading()
  data.games[0].cover = good
  data.games[1].cover = "/etc/shadow"
  const games = L.clean(data).games
  assert.deepEqual([games[0].cover, games[1].cover, games[2].cover], [good, "", ""])
})

test("cover URLs escape every path segment", () => {
  assert.equal(L.coverUrl("/s/appcache/librarycache/1/a.jpg"), "file:///s/appcache/librarycache/1/a.jpg")
  assert.equal(L.coverUrl("/my disk/#1?/appcache/librarycache/1/a.jpg"), "file:///my%20disk/%231%3F/appcache/librarycache/1/a.jpg")
  assert.equal(L.coverUrl("/etc/passwd"), "")
})

test("days ago counts calendar days", () => {
  const now = new Date(2026, 10, 16, 0, 30).getTime()
  const at = (...parts) => new Date(...parts).getTime() / 1000
  assert.equal(L.daysAgo(at(2026, 10, 16, 0, 5), now), 0)
  assert.equal(L.daysAgo(at(2026, 10, 15, 23, 50), now), 1)    // twenty minutes, but yesterday
  assert.equal(L.daysAgo(at(2026, 10, 1, 12, 0), now), 15)
  assert.equal(L.daysAgo(at(2026, 11, 1), now), 0)              // a clock in the future
  for (const never of [0, -5, NaN, null, undefined, "x"]) assert.equal(L.daysAgo(never, now), -1)
})

test("deck status, folder and launch options are cleaned", () => {
  const data = reading()
  Object.assign(data.games[0], { deck: 3, folder: "/s/steamapps/common/Manor Lords", launchOptions: "mangohud\u0007 %command%" })
  Object.assign(data.games[1], { deck: 9, folder: "/s/steamapps/common/../../etc" })
  Object.assign(data.games[2], { deck: 1, folder: "/s/steamapps/common/RimWorld" })   // not installed: no folder
  const g = L.clean(data).games
  assert.deepEqual(plain(g.map(x => [x.deck, x.folder, x.launchOptions])), [
    ["verified", "/s/steamapps/common/Manor Lords", "mangohud  %command%"],
    ["unknown", "", ""], ["unsupported", "", ""], ["unknown", "", ""]])
  for (const bad of ["/etc", "/s/steamapps/common/", "/s/steamapps/common/a/b", "/s/steamapps/common/..",
                     "/s/steamapps/common/.", "relative/steamapps/common/a", "/s/x\n/steamapps/common/a", 5])
    assert.equal(L.folder(bad), "")
  assert.equal(L.deck(2), "playable")
  assert.equal(L.deck("3"), "unknown")
})

test("search matches every word, ignoring case and accents", () => {
  const games = L.clean(reading()).games
  games.push({ id: "9", name: "Pokémon Legends", installed: true, lastPlayed: 0, size: 0 })
  const ids = (installed, q) => plain(L.list(games, installed, "name", q).map(g => g.id))
  assert.deepEqual(ids(true, "  MANOR "), ["1"])
  assert.deepEqual(ids(true, "pokemon leg"), ["9"])
  assert.deepEqual(ids(true, "lords manor"), ["1"])
  assert.deepEqual(ids(true, "manor x"), [])
  assert.deepEqual(ids(true, ""), ids(true, undefined))
  assert.equal(L.countInstalled(games, false, "rim"), 1)
})

test("theme colors read green and yellow, named keys first", () => {
  assert.deepEqual(plain(L.themeColors('color2 = "#111111"\ngreen = "#adda78"\nyellow="#f9cc6c" # x\n')),
                   { green: "#adda78", yellow: "#f9cc6c" })
  assert.deepEqual(plain(L.themeColors("color2 = '#222222'\ncolor3 = \"#333333\"")), { green: "#222222", yellow: "#333333" })
  assert.deepEqual(plain(L.themeColors("green = red\n")), { green: "", yellow: "" })
  assert.deepEqual(plain(L.themeColors(null)), { green: "", yellow: "" })
})

test("used share stays between 0 and 1", () => {
  assert.equal(L.usedShare({ free: 400, total: 500 }), 0.2)
  assert.equal(L.usedShare({ free: 0, total: 0 }), 0)
  assert.equal(L.usedShare(null), 0)
  assert.equal(L.usedShare({ free: 900, total: 500 }), 0)
})

test("deals are cleaned, then listed free first and over the threshold", () => {
  assert.equal(L.cleanDeals({ ok: false }), null)
  assert.equal(L.cleanDeals({ ok: true, free: [] }), null)
  const d = L.cleanDeals({ ok: true, wishlistOk: true,
    free: [{ id: "10", name: "Free One", discount: 100, final: "0₴", initial: "400₴" },
           { id: "x; rm", name: "Bad", discount: 100 }, { id: "11", name: "\u0007", discount: 100 }],
    wishlist: [{ id: "20", name: "Half Off", discount: 50, final: "50₴", initial: "100₴" },
               { id: "21", name: "Small", discount: 20 }, { id: "22", name: "Big", discount: 90 },
               { id: "10", name: "Free One", discount: 100 }, { id: "23", name: "Zero", discount: 0 },
               { id: "24", name: "Weird", discount: 150 }] })
  assert.deepEqual(plain(d.free.map(g => g.id)), ["10"])
  assert.deepEqual(plain(d.wishlist.map(g => g.id)), ["20", "21", "22", "10"])
  const ids = (min, q, owned) => plain(L.dealList(d, min, q, owned).map(g => g.id))
  assert.deepEqual(ids(50), ["10", "22", "20"])
  assert.deepEqual(ids(95), ["10"])
  assert.deepEqual(ids(5), ["10", "22", "20", "21"])
  assert.deepEqual(ids(50, "big"), ["22"])
  const list = plain(L.dealList(d, 50, "", L.ownedIds([{ id: "22" }])))
  assert.deepEqual(list.map(g => [g.free, g.wishlist, g.owned]), [[true, true, false], [false, true, true], [false, true, false]])
  assert.deepEqual(plain(L.dealList(null, 50)), [])
})

test("the wishlist threshold is 5 to 100 in fives", () => {
  assert.deepEqual([L.dealMin(50), L.dealMin(0), L.dealMin(101), L.dealMin(47), L.dealMin("x"), L.dealMin(NaN)], [50, 5, 100, 45, 50, 50])
  assert.equal(L.steamUrl("store", "10"), "steam://store/10")
})
