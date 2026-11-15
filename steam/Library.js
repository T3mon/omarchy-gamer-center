.pragma library

// The Steam page's logic, with no QML types so Node can test it: cleaning
// the helper's reading, sorting the list, and the steam:// links.

var SORTS = ["recent", "name", "size"]
var MAX_GAMES = 5000
var MAX_DRIVES = 16
var ACTIONS = { run: "steam://rungameid/", install: "steam://install/", uninstall: "steam://uninstall/" }

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
      cover: cover(g.cover)
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

// The installed (or not installed) games, in the chosen order.
function list(games, installed, sort) {
  var s = sortFor(sort, installed)
  var out = (games || []).filter(function(g) { return g.installed === installed })
  out.sort(function(a, b) {
    if (s === "recent" && a.lastPlayed !== b.lastPlayed) return b.lastPlayed - a.lastPlayed
    if (s === "size" && a.size !== b.size) return b.size - a.size
    return byName(a, b)
  })
  return out
}

function countInstalled(games, installed) {
  return (games || []).filter(function(g) { return g.installed === installed }).length
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
