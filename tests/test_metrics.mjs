// node --test tests/test_metrics.mjs
import { test } from "node:test"
import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../overlay/Metrics.js", import.meta.url), "utf8")
  .replace(/^\.pragma library\s*$/m, "")
const M = {}
vm.createContext(M)
vm.runInContext(source, M)

// Objects from the vm context have their own prototypes, which strict
// deepEqual would count as a difference; compare plain copies instead.
const plain = value => JSON.parse(JSON.stringify(value))
const texts = rows => plain(rows).map(r => [r.label, r.cells.map(c => c.text).join(" ")])

const sample = () => ({
  cpu: { load: 42.1, temp: 55, mhz: 1371 },
  ram: { used: 6963, total: 15770 },
  gpus: [
    { id: "0000:01:00.0", label: "MX350", load: 0, temp: 53, mhz: 139, vramUsed: 0, vramTotal: 2048, power: null, asleep: false },
    { id: "0000:00:02.0", label: "Intel", load: 5.8, temp: null, mhz: 0, vramUsed: null, vramTotal: null, power: null, asleep: false }
  ],
  primary: "0000:01:00.0",
  battery: { watts: 17.3, state: "discharging" }
})

test("garbage settings become the defaults", () => {
  for (const raw of [null, undefined, 42, "x", [], { enabled: "true", position: "middle", layout: 3 }]) {
    assert.deepEqual(plain(M.sanitize(raw)), plain(M.DEFAULTS))
  }
})

test("numbers are clamped and stepped", () => {
  const c = M.sanitize({ scale: 9, opacity: 0.33, interval: 3 })
  assert.equal(c.scale, M.SCALE_MAX)
  assert.equal(c.opacity, 0.35)
  assert.equal(c.interval, M.DEFAULTS.interval)
  assert.equal(M.sanitize({ scale: true }).scale, 1)
  assert.equal(M.sanitize({ interval: "0.5" }).interval, 0.5)
})

test("metrics keep their own order and drop unknown ids", () => {
  assert.deepEqual(plain(M.sanitize({ metrics: ["time", "bogus", "cpuLoad", "cpuLoad"] }).metrics), ["cpuLoad", "time"])
  assert.deepEqual(plain(M.sanitize({ metrics: [] }).metrics), [])
})

test("gpu and screen only take safe values", () => {
  assert.equal(M.sanitize({ gpu: "0000:01:00.0" }).gpu, "0000:01:00.0")
  assert.equal(M.sanitize({ gpu: "0000:0A:00.0" }).gpu, "0000:0a:00.0")
  assert.equal(M.sanitize({ gpu: "0000:01:00.0 --once" }).gpu, "auto")
  assert.equal(M.sanitize({ screen: "HDMI-A-1" }).screen, "HDMI-A-1")
  assert.equal(M.sanitize({ screen: "eDP-1; rm -rf ~" }).screen, "")
  assert.equal(M.sanitize({ screen: "x".repeat(65) }).screen, "")
})

test("toggling a metric adds and removes it", () => {
  const on = M.toggleMetric(M.DEFAULTS, "time")
  assert.ok(on.metrics.includes("time"))
  assert.ok(!M.toggleMetric(on, "time").metrics.includes("time"))
})

test("fullscreen-only defaults on but keeps an explicit choice", () => {
  assert.equal(M.sanitize({}).fullscreenOnly, true)
  assert.equal(M.sanitize({ fullscreenOnly: false }).fullscreenOnly, false)
  assert.equal(M.sanitize({ fullscreenOnly: "no" }).fullscreenOnly, true)
})

test("anchors and the MangoHud side", () => {
  assert.deepEqual(plain(M.anchors("bottom-right")), { top: false, bottom: true, left: false, right: true })
  assert.deepEqual(plain(M.anchors("top-center")), { top: true, bottom: false, left: false, right: false })
  const expected = {
    "top-left": "top-right", "top-center": "top-left", "top-right": "top-left",
    "bottom-left": "bottom-right", "bottom-center": "bottom-left", "bottom-right": "bottom-left"
  }
  for (const [hud, mango] of Object.entries(expected)) assert.equal(M.mangoPosition(hud), mango)
  assert.equal(M.mangoFontSize(1), 22)
  assert.equal(M.mangoFontSize(99), Math.round(22 * M.SCALE_MAX))
})

test("a full sample becomes HUD lines", () => {
  const rows = M.rows(sample(), M.METRICS, { timeText: "14:32", labels: { time: "T" } })
  assert.deepEqual(texts(rows), [
    ["CPU", "42% 55°C 1.4 GHz"],
    ["MX350", "0% 53°C 139 MHz"],
    ["RAM", "6.8/15.4 GB"],
    ["VRAM", "0.0/2.0 GB"],
    ["BAT", "17.3 W"],
    ["T", "14:32"]
  ])
  assert.equal(rows[0].cells[0].template, "100%")
})

test("values the hardware does not report are left out", () => {
  const s = sample()
  s.primary = "0000:00:02.0"
  const rows = M.rows(s, ["gpuLoad", "gpuTemp", "gpuPower", "vram"], {})
  assert.deepEqual(texts(rows), [["Intel", "6%"]])
})

test("a sleeping GPU says so instead of showing numbers", () => {
  const s = sample()
  s.gpus[0].asleep = true
  const rows = M.rows(s, ["gpuLoad", "vram"], { labels: { asleep: "zz" } })
  assert.deepEqual(texts(rows), [["MX350", "zz"]])
})

test("hot temperatures are flagged", () => {
  const s = sample()
  s.cpu.temp = 91
  const cell = M.rows(s, ["cpuTemp"], {})[0].cells[0]
  assert.equal(cell.text, "91°C")
  assert.equal(cell.hot, true)
})

test("battery states", () => {
  const draw = battery => {
    const s = sample()
    s.battery = battery
    return texts(M.rows(s, ["battery"], {}))
  }
  assert.deepEqual(draw({ watts: 120.4, state: "charging" }), [["BAT", "+120 W"]])
  assert.deepEqual(draw({ watts: null, state: "ac" }), [["BAT", "AC"]])
  assert.deepEqual(draw({ watts: null, state: "discharging" }), [])
  assert.deepEqual(draw(null), [])
})

test("GPU names are bounded and stripped of control characters", () => {
  const s = sample()
  s.gpus[0].label = "\u0007<b>Very Long Graphics Name</b>\n"
  const label = M.rows(s, ["gpuLoad"], {})[0].label
  assert.equal(label.length, 16)
  assert.ok(!/[\u0000-\u001f]/.test(label))
  s.gpus[0].label = ""
  assert.equal(M.rows(s, ["gpuLoad"], { labels: { gpu: "GPU" } })[0].label, "GPU")
})

test("GPU choices skip slots that are not PCI addresses", () => {
  const s = sample()
  s.gpus.push({ id: "../../etc", label: "nope" })
  assert.deepEqual(plain(M.gpuOptions(s)).map(o => o.value), ["0000:01:00.0", "0000:00:02.0"])
})

test("numbers go through the locale formatter", () => {
  const rows = M.rows(sample(), ["ram"], { formatNumber: (v, d) => v.toFixed(d).replace(".", ",") })
  assert.equal(rows[0].cells[0].text, "6,8/15,4 GB")
})

test("no sample, no lines", () => {
  assert.deepEqual(plain(M.rows(null, M.METRICS, {})), [])
  assert.deepEqual(plain(M.rows({ gpus: "nope", cpu: [] }, M.METRICS, {})), [])
})
