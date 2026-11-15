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
  for (const [action, id] of [["run", "1; rm -rf ~"], ["run", ""], ["run", 5], ["run", "12345678901"],
                              ["open", "1"], ["toString", "1"], ["hasOwnProperty", "1"]]) {
    assert.equal(L.steamUrl(action, id), "")
  }
})

test("links open through uwsm-app when it is there", () => {
  assert.deepEqual(plain(L.openCommand("steam://install/1", true)), ["uwsm-app", "--", "xdg-open", "steam://install/1"])
  assert.deepEqual(plain(L.openCommand("steam://install/1", false)), ["xdg-open", "steam://install/1"])
})

test("used share stays between 0 and 1", () => {
  assert.equal(L.usedShare({ free: 400, total: 500 }), 0.2)
  assert.equal(L.usedShare({ free: 0, total: 0 }), 0)
  assert.equal(L.usedShare(null), 0)
  assert.equal(L.usedShare({ free: 900, total: 500 }), 0)
})
