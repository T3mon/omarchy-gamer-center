.pragma library

// The Steam page's logic, with no QML types so Node can test it: cleaning
// the helper's reading, sorting the list, and the steam:// links.

var SORTS = ["recent", "name", "size"]
var MAX_GAMES = 5000
var MAX_DRIVES = 16
var ACTIONS = { run: "steam://rungameid/", install: "steam://install/", uninstall: "steam://uninstall/",
               options: "steam://gameproperties/", store: "steam://store/" }

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
      folder: installed ? folder(g.folder) : "",
      launchOptions: text(g.launchOptions, 500)
    })
  }
  return { uwsm: data.uwsm === true, drives: drives, games: games }
}

// Size means nothing for games that aren't on disk; they sort by name instead.
function sortFor(sort, installed) {
  var s = SORTS.indexOf(sort) >= 0 ? sort : "recent"
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

// The installed (or not installed) games matching the search, in the chosen order.
function list(games, installed, sort, query) {
  var s = sortFor(sort, installed)
  var out = (games || []).filter(function(g) { return g.installed === installed && matches(g, query) })
  out.sort(function(a, b) {
    if (s === "recent" && a.lastPlayed !== b.lastPlayed) return b.lastPlayed - a.lastPlayed
    if (s === "size" && a.size !== b.size) return b.size - a.size
    return byName(a, b)
  })
  return out
}

function countInstalled(games, installed, query) {
  return (games || []).filter(function(g) { return g.installed === installed && matches(g, query) }).length
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
