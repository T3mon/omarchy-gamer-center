.pragma library

// Pure helpers for the Gamer Center overlay: settings, HUD placement, and turning one
// stats sample into the lines the HUD draws. No QML types in here, so the
// Node tests can load this file as it is.

var POSITIONS = ["top-left", "top-center", "top-right", "bottom-left", "bottom-center", "bottom-right"]
var LAYOUTS = ["stack", "row"]
var INTERVALS = [0.5, 1, 2]
var SCALE_MIN = 0.8
var SCALE_MAX = 1.6
var HOT_TEMP = 85
var LABEL_MAX = 16
var SCREEN_MAX = 64
var GPU_SLOT = /^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$/

var GROUPS = [
  { id: "cpu", metrics: ["cpuLoad", "cpuTemp", "cpuClock"] },
  { id: "gpu", metrics: ["gpuLoad", "gpuTemp", "gpuClock", "gpuPower"] },
  { id: "memory", metrics: ["ram", "vram"] },
  { id: "other", metrics: ["battery", "time"] }
]

var METRICS = GROUPS.reduce(function(all, group) { return all.concat(group.metrics) }, [])

var DEFAULTS = {
  enabled: false,
  position: "top-left",
  metrics: ["cpuLoad", "cpuTemp", "gpuLoad", "gpuTemp", "ram", "vram"],
  layout: "stack",
  scale: 1,
  opacity: 0,
  fullscreenOnly: true,
  interval: 2,
  gpu: "auto",
  screen: ""
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function finite(value) {
  return typeof value === "number" && isFinite(value)
}

function stepped(value, min, max, step, fallback) {
  if (typeof value !== "number" && typeof value !== "string") return fallback
  if (value === "") return fallback
  var n = Number(value)
  if (!isFinite(n)) return fallback
  n = Math.min(max, Math.max(min, n))
  return Number((Math.round(n / step) * step).toFixed(2))
}

// Whatever was on disk (or nothing) to a complete, valid settings object.
function sanitize(raw) {
  var src = isObject(raw) ? raw : {}
  var metrics = DEFAULTS.metrics.slice()
  if (Array.isArray(src.metrics)) {
    metrics = METRICS.filter(function(id) { return src.metrics.indexOf(id) !== -1 })
  }
  var gpu = typeof src.gpu === "string" ? src.gpu.toLowerCase() : ""
  var screen = typeof src.screen === "string" ? src.screen : ""
  return {
    enabled: src.enabled === true,
    position: POSITIONS.indexOf(src.position) !== -1 ? src.position : DEFAULTS.position,
    metrics: metrics,
    layout: LAYOUTS.indexOf(src.layout) !== -1 ? src.layout : DEFAULTS.layout,
    scale: stepped(src.scale, SCALE_MIN, SCALE_MAX, 0.05, DEFAULTS.scale),
    opacity: stepped(src.opacity, 0, 1, 0.05, DEFAULTS.opacity),
    fullscreenOnly: typeof src.fullscreenOnly === "boolean" ? src.fullscreenOnly : DEFAULTS.fullscreenOnly,
    interval: INTERVALS.indexOf(Number(src.interval)) !== -1 ? Number(src.interval) : DEFAULTS.interval,
    gpu: GPU_SLOT.test(gpu) ? gpu : "auto",
    screen: screen.length <= SCREEN_MAX && /^[\x21-\x7e]*$/.test(screen) ? screen : ""
  }
}

// A copy of `config` with one field changed, still valid.
function withValue(config, key, value) {
  var next = {}
  var src = isObject(config) ? config : {}
  for (var k in src) next[k] = src[k]
  next[key] = value
  return sanitize(next)
}

function toggleMetric(config, id) {
  var current = sanitize(config).metrics
  var on = current.indexOf(id) !== -1
  return withValue(config, "metrics", on
    ? current.filter(function(m) { return m !== id })
    : current.concat([id]))
}

function anchors(position) {
  var parts = (POSITIONS.indexOf(position) !== -1 ? position : DEFAULTS.position).split("-")
  return {
    top: parts[0] === "top",
    bottom: parts[0] === "bottom",
    left: parts[1] === "left",
    right: parts[1] === "right"
  }
}

// MangoHud draws inside the game, under the HUD; keep it on the other side so
// the two never overlap. A centered HUD sends it left.
function mangoPosition(position) {
  var a = anchors(position)
  return (a.top ? "top" : "bottom") + "-" + (a.left ? "right" : "left")
}

function mangoFontSize(scale) {
  return Math.max(12, Math.min(48, Math.round(22 * stepped(scale, SCALE_MIN, SCALE_MAX, 0.05, 1))))
}

function printable(value, max) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f-\u009f]/g, "")
    .trim()
    .slice(0, max)
}

function primaryGpu(stats) {
  var gpus = isObject(stats) && Array.isArray(stats.gpus) ? stats.gpus.filter(isObject) : []
  for (var i = 0; i < gpus.length; i++) {
    if (gpus[i].id === stats.primary) return gpus[i]
  }
  return gpus.length ? gpus[0] : null
}

function gpuLabel(gpu, fallback) {
  return printable(gpu && gpu.label, LABEL_MAX) || fallback || "GPU"
}

// Choices for the panel: every GPU the helper saw, by slot.
function gpuOptions(stats) {
  var gpus = isObject(stats) && Array.isArray(stats.gpus) ? stats.gpus.filter(isObject) : []
  var out = []
  for (var i = 0; i < gpus.length; i++) {
    var id = String(gpus[i].id || "").toLowerCase()
    if (!GPU_SLOT.test(id)) continue
    out.push({ value: id, label: gpuLabel(gpus[i], id) })
  }
  return out
}

// --- formatting --------------------------------------------------------

function num(opts, value, decimals) {
  if (opts && typeof opts.formatNumber === "function") return String(opts.formatNumber(value, decimals))
  return Number(value).toFixed(decimals)
}

function percentText(value, opts) { return num(opts, Math.round(value), 0) + "%" }
function tempText(value, opts) { return num(opts, Math.round(value), 0) + "°C" }

function clockText(mhz, opts) {
  return mhz >= 1000 ? num(opts, mhz / 1000, 1) + " GHz" : num(opts, Math.round(mhz), 0) + " MHz"
}

function memoryText(usedMiB, totalMiB, opts) {
  return num(opts, usedMiB / 1024, 1) + "/" + num(opts, totalMiB / 1024, 1) + " GB"
}

function wattsText(watts, opts) {
  return num(opts, watts, watts >= 100 ? 0 : 1) + " W"
}

function cell(key, text, template, hot) {
  return { key: key, text: text, template: template || text, hot: hot === true }
}

function loadCell(key, value, opts) {
  return cell(key, percentText(value, opts), percentText(100, opts), false)
}

function tempCell(key, value, opts) {
  return cell(key, tempText(value, opts), tempText(100, opts), value >= HOT_TEMP)
}

function clockCell(key, mhz, opts) {
  return cell(key, clockText(mhz, opts), num(opts, 999, 0) + " MHz", false)
}

function memoryCell(key, used, total, opts) {
  return cell(key, memoryText(used, total, opts), memoryText(total, total, opts), false)
}

// One stats sample + the chosen metrics -> [{ id, label, cells: [{ key, text,
// template, hot }] }]. A value the hardware does not report (null) is left
// out rather than drawn as a dash forever; a line with nothing left goes too.
//
// opts: formatNumber(value, decimals), timeText, labels { cpu, gpu, ram,
//       vram, battery, time, asleep, ac }
function rows(stats, metrics, opts) {
  var o = opts || {}
  var labels = isObject(o.labels) ? o.labels : {}
  var want = {}
  ;(Array.isArray(metrics) ? metrics : []).forEach(function(id) { want[id] = true })
  var s = isObject(stats) ? stats : {}
  var out = []
  var cells

  var cpu = isObject(s.cpu) ? s.cpu : {}
  cells = []
  if (want.cpuLoad && finite(cpu.load)) cells.push(loadCell("cpuLoad", cpu.load, o))
  if (want.cpuTemp && finite(cpu.temp)) cells.push(tempCell("cpuTemp", cpu.temp, o))
  if (want.cpuClock && finite(cpu.mhz) && cpu.mhz > 0) cells.push(clockCell("cpuClock", cpu.mhz, o))
  if (cells.length) out.push({ id: "cpu", label: labels.cpu || "CPU", cells: cells })

  var gpu = primaryGpu(s)
  if (gpu) {
    cells = []
    var wantsGpu = want.gpuLoad || want.gpuTemp || want.gpuClock || want.gpuPower
    if (gpu.asleep === true) {
      if (wantsGpu) cells.push(cell("gpuState", labels.asleep || "asleep"))
    } else {
      if (want.gpuLoad && finite(gpu.load)) cells.push(loadCell("gpuLoad", gpu.load, o))
      if (want.gpuTemp && finite(gpu.temp)) cells.push(tempCell("gpuTemp", gpu.temp, o))
      if (want.gpuClock && finite(gpu.mhz)) cells.push(clockCell("gpuClock", gpu.mhz, o))
      if (want.gpuPower && finite(gpu.power)) cells.push(cell("gpuPower", wattsText(gpu.power, o), num(o, 999, 0) + " W"))
    }
    if (cells.length) out.push({ id: "gpu", label: gpuLabel(gpu, labels.gpu), cells: cells })
  }

  var ram = isObject(s.ram) ? s.ram : {}
  if (want.ram && finite(ram.used) && finite(ram.total) && ram.total > 0) {
    out.push({ id: "ram", label: labels.ram || "RAM", cells: [memoryCell("ram", ram.used, ram.total, o)] })
  }

  if (want.vram && gpu && gpu.asleep !== true && finite(gpu.vramUsed) && finite(gpu.vramTotal) && gpu.vramTotal > 0) {
    out.push({ id: "vram", label: labels.vram || "VRAM", cells: [memoryCell("vram", gpu.vramUsed, gpu.vramTotal, o)] })
  }

  var battery = isObject(s.battery) ? s.battery : null
  if (want.battery && battery) {
    var text = ""
    if (battery.state === "discharging" && finite(battery.watts)) text = wattsText(battery.watts, o)
    else if (battery.state === "charging" && finite(battery.watts)) text = "+" + wattsText(battery.watts, o)
    else if (battery.state === "charging" || battery.state === "ac") text = labels.ac || "AC"
    if (text) out.push({ id: "battery", label: labels.battery || "BAT", cells: [cell("battery", text, "+" + num(o, 99.9, 1) + " W")] })
  }

  if (want.time && o.timeText) {
    out.push({ id: "time", label: labels.time || "", cells: [cell("time", printable(o.timeText, 16))] })
  }

  return out
}
