.pragma library

// The Steam page's logic, with no QML types so Node can test it: cleaning
// the helper's reading, sorting the list, and the steam:// links.

var SORTS = ["recent", "name", "size"]
var MAX_GAMES = 5000
var MAX_DRIVES = 16
var ACTIONS = { run: "steam://rungameid/", install: "steam://install/", uninstall: "steam://uninstall/",
               options: "steam://gameproperties/", store: "steam://store/",
               workshop: "steam://url/SteamWorkshopPage/" }

function validId(id) {
  return typeof id === "string" && /^[0-9]{1,10}$/.test(id)
}

function text(v, max) {
  return typeof v === "string" ? v.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").trim().slice(0, max) : ""
}

function count(v) {
  return typeof v === "number" && isFinite(v) && v > 0 ? Math.round(v) : 0
}

// A cover is a file in Steam's own cover cache, nothing else.
function cover(v) {
  return typeof v === "string" && v.length <= 1024 && /^\/[^\u0000-\u001f]*\/appcache\/librarycache\/[0-9]{1,10}\/[^\u0000-\u001f]+\.(jpg|png)$/.test(v)
    && v.indexOf("/../") === -1 && v.indexOf("/./") === -1 ? v : ""
}

// A game's install folder: an absolute path ending in steamapps/common/<name>.
function folder(v) {
  return typeof v === "string" && v.length <= 4096 && /^\/[^\u0000-\u001f\u007f]*\/steamapps\/common\/[^\/\u0000-\u001f\u007f]+$/.test(v)
    && (v + "/").indexOf("/../") === -1 && (v + "/").indexOf("/./") === -1 ? v : ""
}

// Steam Deck status names, by Steam's category number.
var DECK = ["unknown", "unsupported", "playable", "verified"]

function deck(v) {
  return typeof v === "number" && v >= 1 && v <= 3 ? DECK[Math.floor(v)] : "unknown"
}

// SteamOS status names, by Steam's steamos_compatibility number. It's the
// rating closest to how a game runs on a desktop Linux like Arch.
var STEAMOS = ["unknown", "unsupported", "compatible", "verified"]

function steamos(v) {
  return typeof v === "number" && v >= 1 && v <= 3 ? STEAMOS[Math.floor(v)] : "unknown"
}

// file:// URL for a cover path, each segment escaped.
function coverUrl(path) {
  var p = cover(path)
  return p ? "file://" + p.split("/").map(encodeURIComponent).join("/") : ""
}

// Whole calendar days between a Unix time and now (ms): 0 today, 1 yesterday.
// -1 for never.
function daysAgo(seconds, nowMs) {
  if (!(seconds > 0)) return -1
  var then = new Date(seconds * 1000), now = new Date(nowMs)
  var a = new Date(then.getFullYear(), then.getMonth(), then.getDate())
  var b = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  return Math.max(0, Math.round((b - a) / 86400000))
}

// The helper's JSON, parsed. Returns { uwsm, drives, games }, or null when it
// isn't a library reading.
function clean(data) {
  if (!data || typeof data !== "object" || data.ok !== true
      || !Array.isArray(data.games) || !Array.isArray(data.drives)) return null
  var drives = []
  for (var d = 0; d < data.drives.length && drives.length < MAX_DRIVES; d++) {
    var drive = data.drives[d]
    if (!drive || typeof drive !== "object") continue
    var total = count(drive.total)
    drives.push({
      label: text(drive.label, 40) || "Steam",
      total: total,
      free: Math.min(count(drive.free), total),
      used: count(drive.used),
      games: count(drive.games)
    })
  }
  var games = [], seen = {}
  for (var i = 0; i < data.games.length && games.length < MAX_GAMES; i++) {
    var g = data.games[i]
    if (!g || typeof g !== "object" || !validId(g.id) || seen[g.id]) continue
    var name = text(g.name, 120)
    if (!name) continue
    var installed = g.installed === true
    var where = installed && typeof g.drive === "number" && g.drive >= 0 && g.drive < drives.length ? Math.floor(g.drive) : -1
    seen[g.id] = true
    games.push({
      id: g.id,
      name: name,
      installed: installed,
      size: installed ? count(g.size) : 0,
      drive: where,
      lastPlayed: count(g.lastPlayed),
      playtime: count(g.playtime),
      cover: cover(g.cover),
      deck: deck(g.deck),
      steamos: steamos(g.steamos),
      hasWorkshop: g.hasWorkshop === true,
      folder: installed ? folder(g.folder) : "",
      launchOptions: text(g.launchOptions, 500),
      build: installed && typeof g.build === "string" && /^[0-9]{1,12}$/.test(g.build) ? g.build : "",
      updated: installed ? count(g.updated) : 0,
      update: installed && UPDATES.indexOf(g.update) >= 0 ? g.update : "",
      progress: installed ? Math.min(100, count(g.progress)) : 0,
      workshop: installed ? count(g.workshop) : 0,
      mods: installed ? count(g.mods) : 0,
      platform: PLATFORMS.indexOf(g.platform) >= 0 ? g.platform : "",
      proton: installed ? text(g.proton, 80) : "",
      forcedTool: text(g.forcedTool, 60),
      favorite: g.favorite === true,
      dlc: dlcList(g.dlc)
    })
  }
  var st = data.steam && typeof data.steam === "object" ? data.steam : {}
  return { uwsm: data.uwsm === true, drives: drives, games: games,
           steam: { running: st.running === true, persona: text(st.persona, 64) } }
}

// "" means up to date. "mods" is workshop items waiting.
var UPDATES = ["", "required", "downloading", "paused", "mods"]
var PLATFORMS = ["", "linux", "proton", "windows"]
var DLC_STATES = ["installed", "owned", "missing"]

function dlcList(raw) {
  var out = [], seen = {}
  for (var i = 0; Array.isArray(raw) && i < raw.length && out.length < 300; i++) {
    var d = raw[i]
    if (!d || typeof d !== "object" || !validId(d.id) || seen[d.id] || DLC_STATES.indexOf(d.state) < 0) continue
    var name = text(d.name, 120)
    if (!name) continue
    seen[d.id] = true
    out.push({ id: d.id, name: name, state: d.state })
  }
  // Installed first, then owned, then the rest, each by name.
  return out.sort(function(a, b) { return DLC_STATES.indexOf(a.state) - DLC_STATES.indexOf(b.state) || byName(a, b) })
}

// "2 of 8 owned · 1 installed"-style counts.
function dlcCounts(list) {
  var out = { total: 0, owned: 0, installed: 0 }
  for (var i = 0; list && i < list.length; i++) {
    out.total++
    if (list[i].state !== "missing") out.owned++
    if (list[i].state === "installed") out.installed++
  }
  return out
}

// `gamercenter-steam --sizes`: { appid: [prefix bytes, shader cache bytes] }.
function cleanSizes(data) {
  if (!data || typeof data !== "object" || data.ok !== true || !data.sizes || typeof data.sizes !== "object") return null
  var out = {}, n = 0
  for (var id in data.sizes) {
    var v = data.sizes[id]
    if (!data.sizes.hasOwnProperty(id) || !validId(id) || !Array.isArray(v) || ++n > MAX_GAMES) continue
    out[id] = [count(v[0]), count(v[1])]
  }
  return out
}

// Everything the game takes: its files, workshop mods, Proton prefix and shader cache.
function fullSize(game, sizes) {
  if (!game || !game.installed) return 0
  var extra = sizes && sizes.hasOwnProperty(game.id) ? sizes[game.id] : [0, 0]
  return game.size + (game.workshop || 0) + extra[0] + extra[1]
}

// ---- Filters ---------------------------------------------------------------

// Groups: played (one of PLAYED), runs (any of RUNS; none means any),
// favorites and updates (on or off). A game has to pass every group, and
// one of the runs it ticks.
var PLAYED = ["all", "played", "never"]
// SteamOS ratings in Steam's data are compatible, unsupported or unknown;
// "verified" is a Deck rating and never shows up for SteamOS.
var RUNS = ["linux", "compatible", "unsupported", "unknown"]

function cleanFilter(f) {
  f = f && typeof f === "object" ? f : {}
  var runs = Array.isArray(f.runs) ? RUNS.filter(function(r) { return f.runs.indexOf(r) >= 0 }) : []
  return {
    played: PLAYED.indexOf(f.played) >= 0 ? f.played : "all",
    runs: runs,
    favorites: f.favorites === true,
    updates: f.updates === true
  }
}

// How many groups narrow the list.
function activeFilters(f) {
  f = cleanFilter(f)
  return f.runs.length + (f.played !== "all" ? 1 : 0) + (f.favorites ? 1 : 0) + (f.updates ? 1 : 0)
}

// A runs choice on or off.
function toggleRun(runs, value) {
  var on = (runs || []).indexOf(value) >= 0
  return RUNS.filter(function(r) { return r === value ? !on : (runs || []).indexOf(r) >= 0 })
}

function runsOn(game, value) {
  return value === "linux" ? game.platform === "linux" : game.steamos === value
}

function passes(game, filter, skip) {
  if (!filter) return true
  var played = game.lastPlayed > 0 || game.playtime > 0
  if (skip !== "played" && filter.played === "played" && !played) return false
  if (skip !== "played" && filter.played === "never" && played) return false
  if (skip !== "runs" && filter.runs && filter.runs.length
      && !filter.runs.some(function(r) { return runsOn(game, r) })) return false
  if (skip !== "favorites" && filter.favorites && !game.favorite) return false
  if (skip !== "updates" && filter.updates && !(game.installed && game.update)) return false
  return true
}

// What each choice would show, with the other groups as they are:
// { played: {all, played, never}, runs: {linux, ...}, favorites, updates }.
function facets(games, installed, query, filter) {
  var f = cleanFilter(filter)
  var out = { played: { all: 0, played: 0, never: 0 }, runs: {}, favorites: 0, updates: 0 }
  RUNS.forEach(function(r) { out.runs[r] = 0 })
  ;(games || []).forEach(function(g) {
    if (g.installed !== installed || !matches(g, query)) return
    if (passes(g, f, "played")) {
      out.played.all++
      out.played[g.lastPlayed > 0 || g.playtime > 0 ? "played" : "never"]++
    }
    if (passes(g, f, "runs")) RUNS.forEach(function(r) { if (runsOn(g, r)) out.runs[r]++ })
    if (passes(g, f, "favorites") && g.favorite) out.favorites++
    if (passes(g, f, "updates") && g.installed && g.update) out.updates++
  })
  return out
}

// Size means nothing for games that aren't on disk, and other games have no
// last played; those sort by name instead.
function sortFor(sort, installed, other) {
  var s = SORTS.indexOf(sort) >= 0 ? sort : "recent"
  if (other) return s === "recent" ? "name" : s
  return s === "size" && !installed ? "name" : s
}

function byName(a, b) {
  var x = a.name.toLowerCase(), y = b.name.toLowerCase()
  return x < y ? -1 : x > y ? 1 : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
}

// Lower case, accents dropped, so "pokemon" finds "Pokémon".
function fold(v) {
  var s = String(v || "").toLowerCase()
  return typeof s.normalize === "function" ? s.normalize("NFD").replace(/[\u0300-\u036f]/g, "") : s
}

// The search's words; a game has to contain every one of them.
function words(query) {
  return fold(query).split(/\s+/).filter(function(w) { return w.length > 0 }).slice(0, 8)
}

function matches(game, query) {
  var name = fold(game.name), want = words(query)
  for (var i = 0; i < want.length; i++) if (name.indexOf(want[i]) === -1) return false
  return true
}

// The installed (or not installed) games matching the search and the
// filters, in the chosen order. Size is everything the game takes.
function list(games, installed, sort, query, filter, sizes) {
  var s = sortFor(sort, installed)
  var f = filter ? cleanFilter(filter) : null
  var out = (games || []).filter(function(g) { return g.installed === installed && matches(g, query) && passes(g, f) })
  out.sort(function(a, b) {
    if (s === "recent" && a.lastPlayed !== b.lastPlayed) return b.lastPlayed - a.lastPlayed
    if (s === "size") { var x = fullSize(a, sizes), y = fullSize(b, sizes); if (x !== y) return y - x }
    return byName(a, b)
  })
  return out
}

function countInstalled(games, installed, query, filter) {
  var f = filter ? cleanFilter(filter) : null
  return (games || []).filter(function(g) { return g.installed === installed && matches(g, query) && passes(g, f) }).length
}

// green and yellow from a theme's colors.toml, "" when it has none.
function themeColors(raw) {
  var out = { green: "", yellow: "" }
  var lines = String(raw || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var m = lines[i].match(/^\s*(green|yellow|color2|color3)\s*=\s*["']?(#[0-9A-Fa-f]{6})["']?\s*(#.*)?$/)
    if (!m) continue
    var key = m[1] === "color2" ? "green" : m[1] === "color3" ? "yellow" : m[1]
    if (!out[key] || m[1] === key) out[key] = m[2]
  }
  return out
}

// "" for an unknown action or a bad id.
function steamUrl(action, id) {
  return ACTIONS.hasOwnProperty(action) && validId(id) ? ACTIONS[action] + id : ""
}

// Through uwsm-app when it's there, so Steam and its games get their own
// scope, as Omarchy's launchers do. The url is one argv entry, never code.
function openCommand(url, uwsm) {
  return uwsm ? ["uwsm-app", "--", "xdg-open", url] : ["xdg-open", url]
}

// Used share of a drive, 0..1.
function usedShare(drive) {
  return drive && drive.total > 0 ? Math.max(0, Math.min(1, (drive.total - drive.free) / drive.total)) : 0
}

// ---- Deals -----------------------------------------------------------------

// The wishlist threshold: 5..100 % in steps of 5, 50 by default.
var DEAL_MIN_DEFAULT = 50

function dealMin(v) {
  return typeof v === "number" && isFinite(v) ? Math.max(5, Math.min(100, Math.round(v / 5) * 5)) : DEAL_MIN_DEFAULT
}

function dealGames(raw, max) {
  var out = [], seen = {}
  for (var i = 0; Array.isArray(raw) && i < raw.length && out.length < max; i++) {
    var g = raw[i]
    if (!g || typeof g !== "object" || !validId(g.id) || seen[g.id]) continue
    var name = text(g.name, 120)
    var discount = typeof g.discount === "number" && g.discount >= 1 && g.discount <= 100 ? Math.round(g.discount) : 0
    if (!name || !discount) continue
    seen[g.id] = true
    out.push({ id: g.id, name: name, discount: discount, final: text(g.final, 32), initial: text(g.initial, 32) })
  }
  return out
}

// bin/gamercenter-deals' JSON. Returns { free, wishlist, wishlistOk }, or null.
function cleanDeals(data) {
  if (!data || typeof data !== "object" || data.ok !== true
      || !Array.isArray(data.free) || !Array.isArray(data.wishlist)) return null
  return { free: dealGames(data.free, 200), wishlist: dealGames(data.wishlist, 2000), wishlistOk: data.wishlistOk === true }
}

// The Deals list: 100% off games first, then wishlist games at least min %
// off, biggest discount first. owned is { id: true } for the library.
function dealList(deals, min, query, owned) {
  if (!deals) return []
  var out = [], at = {}, m = dealMin(min)
  function add(g, free, wished) {
    if (!matches(g, query)) return
    if (at.hasOwnProperty(g.id)) { if (wished) out[at[g.id]].wishlist = true; return }
    at[g.id] = out.length
    out.push({ id: g.id, name: g.name, discount: g.discount, final: g.final, initial: g.initial,
               free: free, wishlist: wished, owned: !!owned && owned.hasOwnProperty(g.id) })
  }
  deals.free.forEach(function(g) { add(g, true, false) })
  deals.wishlist.filter(function(g) { return g.discount >= m })
    .sort(function(a, b) { return b.discount - a.discount || byName(a, b) })
    .forEach(function(g) { add(g, g.discount === 100, true) })
  return out
}

function ownedIds(games) {
  var out = {}
  for (var i = 0; games && i < games.length; i++) out[games[i].id] = true
  return out
}

// ---- Other games: app-menu entries in the Game category --------------------

function validEntryId(id) {
  return typeof id === "string" && id.length <= 210 && /^[A-Za-z0-9_][A-Za-z0-9 ._+-]*\.desktop$/.test(id)
}

// An absolute path with no control characters and no . or .. segments.
function plainPath(v, max) {
  return typeof v === "string" && v.length <= max && /^\/[^\u0000-\u001f\u007f]*$/.test(v)
    && (v + "/").indexOf("/../") === -1 && (v + "/").indexOf("/./") === -1 ? v : ""
}

// An icon theme name, or an image file.
function entryIcon(v) {
  if (typeof v !== "string") return ""
  if (v.charAt(0) === "/") return /\.(png|svg|jpg|jpeg|xpm)$/i.test(v) ? plainPath(v, 1024) : ""
  return v.length <= 200 && /^[A-Za-z0-9_][A-Za-z0-9._+-]*$/.test(v) ? v : ""
}

// file:// URL for an icon file, each segment escaped; "" for a theme name.
function iconFileUrl(icon) {
  var p = entryIcon(icon)
  return p.charAt(0) === "/" ? "file://" + p.split("/").map(encodeURIComponent).join("/") : ""
}

// bin/gamercenter-games' JSON. Returns { uwsm, games }, or null.
function cleanOthers(data) {
  if (!data || typeof data !== "object" || data.ok !== true || !Array.isArray(data.games)) return null
  var games = [], seen = {}
  for (var i = 0; i < data.games.length && games.length < 500; i++) {
    var g = data.games[i]
    if (!g || typeof g !== "object" || !validEntryId(g.id) || seen[g.id]) continue
    var name = text(g.name, 120)
    if (!name) continue
    seen[g.id] = true
    var where = plainPath(g.folder, 4096)
    games.push({ id: g.id, name: name, comment: text(g.comment, 200), icon: entryIcon(g.icon),
                 folder: where, size: where ? count(g.size) : 0 })
  }
  return { uwsm: data.uwsm === true, games: games }
}

// The other games matching the search, by name or by size.
function otherList(games, sort, query) {
  var out = (games || []).filter(function(g) { return matches(g, query) })
  out.sort(function(a, b) { return sort === "size" && a.size !== b.size ? b.size - a.size : byName(a, b) })
  return out
}

// Starts a desktop entry by its id, the way the app menu does; the entry's
// Exec line is never handed to a shell here.
function entryCommand(id, uwsm) {
  if (!validEntryId(id)) return []
  return uwsm ? ["uwsm-app", "--", id] : ["gtk-launch", id]
}

// ---- The Steam Deck report (gamercenter-steam --deck N) ---------------------

// display: 1 note, 2 fail, 3 warning, 4 pass.
var DECK_DISPLAY = ["", "note", "fail", "warning", "pass"]

function deckResults(raw) {
  var out = []
  for (var i = 0; Array.isArray(raw) && i < raw.length && out.length < 40; i++) {
    var t = raw[i]
    if (!t || typeof t !== "object" || typeof t.result !== "string" || !/^[A-Za-z0-9_]{1,80}$/.test(t.result)) continue
    var d = typeof t.display === "number" && t.display >= 1 && t.display <= 4 ? Math.floor(t.display) : 0
    if (d) out.push({ result: t.result, kind: DECK_DISPLAY[d] })
  }
  return out
}

function rating(v) {
  return typeof v === "number" && v >= 0 && v <= 3 ? Math.floor(v) : 0
}

// Returns { id, deck, machine, steamos, testedAt, testedBuild, results, config },
// { id, none: true } when Valve hasn't tested the game, or null.
function cleanDeck(data) {
  if (!data || typeof data !== "object" || data.ok !== true || !validId(data.id)) return null
  var d = data.deck
  if (!d || typeof d !== "object") return { id: data.id, none: true }
  var r = d.results && typeof d.results === "object" ? d.results : {}
  var config = [], raw = d.config && typeof d.config === "object" ? d.config : {}
  for (var k in raw) {
    if (raw.hasOwnProperty(k) && /^[a-z0-9_]{1,60}$/.test(k) && config.length < 40) config.push({ key: k, value: text(String(raw[k]), 60) })
  }
  return {
    id: data.id, none: false,
    deck: DECK[rating(d.deck)], machine: DECK[rating(d.machine)], steamos: rating(d.steamos),
    testedAt: count(d.testedAt),
    testedBuild: typeof d.testedBuild === "string" && /^[0-9]{1,12}$/.test(d.testedBuild) ? d.testedBuild : "",
    results: { deck: deckResults(r.deck), machine: deckResults(r.machine), steamos: deckResults(r.steamos) },
    config: config
  }
}

// "InterfaceTextIsNotLegible" -> "Interface text is not legible", for any
// result that has no sentence of its own in the translations.
function humanize(name) {
  var words = String(name || "").replace(/_/g, " ").replace(/([a-z0-9])([A-Z])/g, "$1 $2").replace(/([A-Z]+)([A-Z][a-z])/g, "$1 $2").trim()
  return words ? words.charAt(0) + words.slice(1).toLowerCase() : ""
}
