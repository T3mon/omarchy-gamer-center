import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "overlay"
import "overlay/Metrics.js" as Metrics
import "steam/Library.js" as Library

// Bar icon + the overlay panel. All state lives in the service; this file
// only shows it and calls in.
Panel {
  id: root
  moduleName: "t3mon.gamercenter"
  ipcTarget: "t3mon.gamercenter"

  readonly property string pluginId: "t3mon.gamercenter"

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------ service

  property var service: null
  property var heldService: null

  readonly property var config: service ? service.config : Metrics.sanitize(null)
  readonly property bool hudOn: !!service && service.hudOn
  readonly property var mango: service ? service.mango : ({ installed: false, managed: false, graph: false })
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dimFg: Qt.darker(fg, 1.4)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int labelWidth: Style.space(64)

  // Which page shows: "stats" (the overlay), "gamemode" or "steam". Kept
  // until the shell restarts.
  property string page: "steam"
  readonly property var pages: ["stats", "gamemode", "steam"]
  readonly property var gm: service ? service.gameMode : null
  readonly property bool gameOn: !!gm && gm.gameOn
  readonly property var gmItems: gm ? gm.items : []

  // Steam: which list shows, its order, and the game shown on the right
  // (the one picked, else the list's first).
  readonly property var steamModel: service ? service.steam : null
  readonly property string stPhase: steamModel ? steamModel.phase : "reading"
  readonly property var stDrives: steamModel ? steamModel.drives : []
  // "installed", "other" (not installed), "deals" or "local" (other games:
  // app-menu entries in the Game category).
  property string stTab: "installed"
  readonly property bool stInstalled: stTab === "installed"
  readonly property bool stDeals: stTab === "deals"
  readonly property bool stLocal: stTab === "local"
  readonly property int stDealMin: steamModel ? steamModel.dealMin : Library.DEAL_MIN_DEFAULT
  readonly property var stDealList: steamModel ? Library.dealList(steamModel.deals, stDealMin, stQuery, Library.ownedIds(steamModel.games)) : []
  property string stSort: "recent"
  property string stGameId: ""
  readonly property string stSortShown: Library.sortFor(stSort, stInstalled, stLocal)
  property string stQuery: ""
  property bool stSearching: false
  // Filters for the Installed and Not installed tabs, kept until the shell restarts.
  property string stFilterPlayed: "all"
  property var stFilterRuns: []
  property bool stFilterFav: false
  property bool stFilterUpdates: false
  readonly property bool stFiltered: !stDeals && !stLocal
  // The filters card over the list.
  property bool stFilterOpen: false
  readonly property var stSizes: steamModel ? steamModel.sizes : ({})
  function stFilterFor(installed) {
    return { played: stFilterPlayed, runs: stFilterRuns, favorites: stFilterFav, updates: installed && stFilterUpdates }
  }
  readonly property int stActiveFilters: stFiltered ? Library.activeFilters(stFilterFor(stInstalled)) : 0
  // What each choice in the card would show; only counted while it's open.
  readonly property var stFacets: stFilterOpen && steamModel ? Library.facets(steamModel.games, stInstalled, stQuery, stFilterFor(stInstalled)) : null
  // The filters in use, as removable chips under the search.
  readonly property var stChips: {
    if (!stFiltered) return []
    var out = []
    for (var i = 0; i < stFilterRuns.length; i++) out.push({ group: "runs", value: stFilterRuns[i] })
    if (stFilterPlayed !== "all") out.push({ group: "played", value: stFilterPlayed })
    if (stFilterFav) out.push({ group: "favorites", value: "" })
    if (stInstalled && stFilterUpdates) out.push({ group: "updates", value: "" })
    return out
  }
  readonly property var stGames: stDeals ? stDealList
    : stLocal ? (steamModel ? Library.otherList(steamModel.otherGames, stSortShown, stQuery) : [])
    : steamModel ? Library.list(steamModel.games, stInstalled, stSort, stQuery, stFilterFor(stInstalled), stSizes) : []
  readonly property int stIndex: {
    for (var i = 0; i < stGames.length; i++) if (stGames[i].id === stGameId) return i
    return stGames.length ? 0 : -1
  }
  readonly property var stGame: stIndex >= 0 ? stGames[stIndex] : null
  // The DLC list starts folded, and the Deck report closes, for each game shown.
  property bool stDlcOpen: false
  property bool stDeckOpen: false
  readonly property string stShownId: stGame ? stTab + ":" + stGame.id : ""
  onStShownIdChanged: { stDlcOpen = false; stDeckOpen = false }
  readonly property bool stHasDlc: stFiltered && !!stGame && !!stGame.dlc && stGame.dlc.length > 0
  // Text buttons first, then the icon-only ones (folder, launch options).
  readonly property var stActions: !stGame ? [] : stDeals ? ["store"]
    : stLocal ? ["run"].concat(stGame.folder ? ["folder"] : [])
    : (stGame.installed ? ["run", "uninstall"] : ["install"])
        .concat(stGame.folder ? ["folder"] : [], ["options"])
  // The theme's green and yellow, re-read each time the panel opens.
  property var stTheme: ({ green: "", yellow: "" })
  readonly property color stGreen: stTheme.green || fg
  readonly property color stYellow: stTheme.yellow || fg

  FileView {
    id: themeColorsFile
    path: Commons.Color.currentThemePath + "/colors.toml"
    watchChanges: false
    printErrors: false
    onLoaded: root.stTheme = Library.themeColors(text())
  }

  function actionColor(action) {
    return action === "run" ? stGreen : action === "install" || action === "store" ? Commons.Color.accent
      : action === "uninstall" ? Commons.Color.urgent : fg
  }

  // Game mode's switches: green when on, red when off.
  function switchTint(on) { return on ? stGreen : Commons.Color.urgent }

  function deckColor(status) {
    return status === "verified" ? stGreen : status === "playable" ? stYellow
      : status === "unsupported" ? Commons.Color.urgent : dimFg
  }
  readonly property var stSortOptions: ["recent", "name", "size"]
    .filter(function(v) { return stLocal ? v !== "recent" : stInstalled || v !== "size" })
    .map(function(v) { return { value: v, label: strings.t("steam.sort." + v) } })
  // "Today" and "yesterday" are counted from when the panel opened.
  property double stNow: Date.now()

  // serviceFor() is a plain lookup, not a binding: ask again whenever the
  // answer could have changed, and keep asking until the service is up.
  function resolveService() {
    if (service) return
    var api = bar && bar.shell ? bar.shell : null
    var found = api && typeof api.serviceFor === "function" ? api.serviceFor(pluginId) : null
    if (found) service = found
  }

  // While the panel is open the service streams stats even with the HUD off,
  // so the preview below is live.
  function syncPreview() {
    var want = opened && page === "stats" && service ? service : null
    if (want !== heldService) {
      if (heldService) heldService.releasePreview()
      heldService = want
      if (want) want.retainPreview()
    }
    var watch = opened && page === "gamemode" && gm ? gm : null
    if (watch !== watchedGameMode) {
      if (watchedGameMode) watchedGameMode.watchers = Math.max(0, watchedGameMode.watchers - 1)
      watchedGameMode = watch
      if (watch) { watch.watchers++; watch.refresh() }
    }
    var library = opened && page === "steam" && steamModel ? steamModel : null
    if (library !== watchedSteam) {
      if (watchedSteam) watchedSteam.watchers = Math.max(0, watchedSteam.watchers - 1)
      watchedSteam = library
      if (library) library.watchers++
    }
  }

  property var watchedGameMode: null
  property var watchedSteam: null

  function setPage(name) {
    if (pages.indexOf(name) === -1) return
    page = name
  }

  // ------------------------------------------------------------ steam

  function bytes(b) { return size(b / 1048576) }

  function playedText(minutes) {
    if (minutes < 60) return strings.t("steam.minutesPlayed").arg(Commons.I18n.formatNumber(minutes))
    return strings.t("steam.hoursPlayed").arg(Commons.I18n.formatNumber(minutes / 60, 1))
  }

  // "today", "yesterday", "3 days ago", else the month; "" for never.
  function whenText(seconds) {
    var days = Library.daysAgo(seconds, stNow)
    if (days < 0) return ""
    if (days === 0) return strings.t("steam.today")
    if (days === 1) return strings.t("steam.yesterday")
    if (days < 30) return strings.tn("steam.daysAgo", days).arg(Commons.I18n.formatNumber(days))
    return new Date(seconds * 1000).toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), "MMM yyyy")
  }

  // Under a game's name in the list: when it was last played, its size.
  function rowCaption(game) {
    var parts = []
    var when = whenText(game.lastPlayed)
    if (when) parts.push(when)
    if (game.installed) parts.push(bytes(Library.fullSize(game, stSizes)))
    return parts.join(" · ")
  }

  // Filters: names, colors, and changes. Every change shows the list's first game.
  function runLabel(v) { return strings.t("steam.filter.runs." + v) }

  function runColor(v) {
    return v === "linux" || v === "verified" ? stGreen : v === "compatible" ? stYellow
      : v === "unsupported" ? Commons.Color.urgent : dimFg
  }

  function chipLabel(chip) {
    if (chip.group === "runs") return runLabel(chip.value)
    if (chip.group === "played") return strings.t("steam.filter.played." + chip.value)
    if (chip.group === "favorites") return "\uf005  " + strings.t("steam.filter.favorites")
    return "\uf021  " + strings.t("steam.filter.updates")
  }

  function chipColor(chip) {
    if (chip.group === "runs") return runColor(chip.value)
    if (chip.group === "favorites" || chip.group === "updates") return stYellow
    return Commons.Color.accent
  }

  function toggleRun(v) { stFilterRuns = Library.toggleRun(stFilterRuns, v); stGameId = "" }
  function setPlayed(v) { if (Library.PLAYED.indexOf(v) >= 0) { stFilterPlayed = v; stGameId = "" } }
  function toggleFav() { stFilterFav = !stFilterFav; stGameId = "" }
  function toggleUpdates() { stFilterUpdates = !stFilterUpdates; stGameId = "" }

  function clearFilters() {
    stFilterRuns = []
    stFilterPlayed = "all"
    stFilterFav = false
    stFilterUpdates = false
    stGameId = ""
  }

  function removeChip(chip) {
    if (!chip) return
    if (chip.group === "runs") toggleRun(chip.value)
    else if (chip.group === "played") setPlayed("all")
    else if (chip.group === "favorites") toggleFav()
    else toggleUpdates()
  }

  // "Linux native  12": a choice and how many games it would show.
  function facetText(label, n) {
    return stFacets ? label + "  " + Commons.I18n.formatNumber(n) : label
  }

  // The card's rows, top to bottom, for the keyboard.
  readonly property var stCardRows: [
    { id: "st-fc-runs", count: Library.RUNS.length },
    { id: "st-fc-played", count: Library.PLAYED.length },
    { id: "st-fc-show", count: stInstalled ? 2 : 1 },
    { id: "st-fc-foot", count: 2 }
  ]

  function openFilters(open) {
    stFilterOpen = open && stFiltered
    stSearching = false
    cursorActive = true
    cursorByMouse = false
    cursorRow = stFilterOpen ? "st-fc-runs" : "st-search"
    cursorCol = stFilterOpen ? 0 : 1
  }

  function activateCard(id, col) {
    if (id === "st-fc-runs") toggleRun(Library.RUNS[col])
    else if (id === "st-fc-played") setPlayed(Library.PLAYED[col])
    else if (id === "st-fc-show") { if (col === 0) toggleFav(); else toggleUpdates() }
    else if (id === "st-fc-foot") { if (col === 0) clearFilters(); else openFilters(false) }
  }

  // The update badge on a row and the line in the details.
  function updateText(game) {
    if (!game || !game.update) return ""
    if (game.update === "downloading" || game.update === "paused")
      return strings.t("steam.update." + game.update).arg(Commons.I18n.formatNumber(game.progress))
    return strings.t("steam.update." + game.update)
  }

  // Game · mods · prefix · shader cache, the parts that aren't zero.
  function sizeParts(game) {
    var extra = stSizes && stSizes.hasOwnProperty(game.id) ? stSizes[game.id] : [0, 0]
    var parts = [strings.t("steam.size.game").arg(bytes(game.size))]
    if (game.workshop > 0) parts.push(strings.tn("steam.size.mods", game.mods).arg(bytes(game.workshop)).arg(Commons.I18n.formatNumber(game.mods)))
    if (extra[0] > 0) parts.push(strings.t("steam.size.prefix").arg(bytes(extra[0])))
    if (extra[1] > 0) parts.push(strings.t("steam.size.shaders").arg(bytes(extra[1])))
    return parts.length > 1 ? parts.join(" · ") : ""
  }

  function dlcHeader(game) {
    var c = Library.dlcCounts(game.dlc)
    var text = strings.t("steam.dlc.header").arg(Commons.I18n.formatNumber(c.owned)).arg(Commons.I18n.formatNumber(c.total))
    return game.installed && c.owned > 0 ? text + " · " + strings.t("steam.dlc.installedCount").arg(Commons.I18n.formatNumber(c.installed)) : text
  }

  function dlcColor(state) {
    return state === "installed" ? stGreen : state === "owned" ? fg : dimFg
  }

  // The details' badges and facts.
  function platformBadge(game) {
    if (game.forcedTool || game.platform === "proton") return "\uf17a  " + strings.t("steam.badge.proton")
    if (game.platform === "linux") return "\uf17c  " + strings.t("steam.platform.linux")
    if (game.platform === "windows") return "\uf17a  " + strings.t("steam.badge.windows")
    return ""
  }

  function platformColor(game) {
    return game.platform === "linux" && !game.forcedTool ? stGreen
      : game.platform === "windows" ? dimFg : Commons.Color.accent
  }

  // The Proton that runs it, only when it's known or forced.
  function runsWith(game) {
    if (game.forcedTool) return strings.t("steam.fact.forced").arg(game.forcedTool)
    if (game.platform === "proton" && game.proton) return game.proton
    return ""
  }

  function playedValue(game) {
    var when = whenText(game.lastPlayed)
    if (!when && game.playtime <= 0) return strings.t("steam.fact.never")
    var parts = []
    if (when) parts.push(when)
    if (game.playtime > 0) parts.push(playedText(game.playtime))
    return parts.join(" · ")
  }

  function openDeck() {
    if (!stGame || !stFiltered || !steamModel) return
    stDeckOpen = true
    steamModel.refreshDeck(stGame.id)
  }

  function dateText(seconds) {
    return seconds > 0 ? new Date(seconds * 1000).toLocaleDateString(Qt.locale(Commons.I18n.formatLocale), "d MMM yyyy") : ""
  }

  function deckTestedLine(r) {
    var when = dateText(r.testedAt)
    if (when && r.testedBuild) return strings.t("steam.deck.testedOn").arg(when).arg(r.testedBuild)
    if (when) return strings.t("steam.deck.tested").arg(when)
    if (r.testedBuild) return strings.t("steam.deck.testedBuild").arg(r.testedBuild)
    return ""
  }

  function deckSectionTitle(kind, r) {
    var rating = kind === "steamos" ? strings.t("steam.deck.os." + r.steamos) : strings.t("steam.deck." + r[kind])
    return strings.t("steam.deck.section." + kind).arg(rating)
  }

  function deckSectionColor(kind, r) {
    if (kind !== "steamos") return deckColor(r[kind])
    return r.steamos === 3 ? stGreen : r.steamos === 2 ? stYellow : r.steamos === 1 ? Commons.Color.urgent : dimFg
  }

  function deckKindColor(kind) {
    return kind === "pass" ? stGreen : kind === "warning" ? stYellow : kind === "fail" ? Commons.Color.urgent : dimFg
  }

  // A flag's value in words: Yes / No, the runtime, HDR, input.
  function deckFlagValue(key, value) {
    if (key === "recommended_runtime") {
      if (value === "native") return strings.t("steam.platform.linux")
      if (value === "proton-stable") return strings.t("deck.runtime.stable")
      if (value === "proton-experimental") return strings.t("deck.runtime.experimental")
      var m = /^proton-([0-9.]+)/.exec(value)
      return m ? strings.t("deck.runtime.version").arg(m[1]) : value
    }
    if (key === "hdr_support") return strings.t(value === "0" ? "deck.value.no" : "deck.value.yes")
    if (key === "supported_input") return strings.t("deck.input." + value, value)
    if (key === "proton_compat_config") return value.replace(/,+$/, "").split(",").join(", ")
    if (value === "0") return strings.t("deck.value.no")
    if (value === "1") return strings.t("deck.value.yes")
    return value
  }

  function sizeLine(game) {
    var d = game.drive >= 0 ? stDrives[game.drive] : null
    return strings.t("steam.sizeOn").arg(bytes(Library.fullSize(game, stSizes))).arg(d ? d.label : "Steam")
  }

  function setSteamTab(tab) {
    stDeckOpen = false
    stFilterOpen = false
    if (stTab === tab) return
    stTab = tab
    stGameId = ""
    if (tab === "deals" && steamModel) steamModel.refreshDeals()
    if (tab === "local" && steamModel) steamModel.refreshOthers()
  }

  // Under an other game's name: its size, and the entry's comment.
  function localCaption(game) {
    return [game.size > 0 ? bytes(game.size) : "", game.comment].filter(function(v) { return v }).join(" · ")
  }

  // An icon file, else the icon theme's file for the name.
  function iconUrl(icon) {
    return Library.iconFileUrl(icon) || (icon ? Quickshell.iconPath(icon, true) : "")
  }

  // Under a deal's name, and in its details: "-75% · 100₴", or "Free".
  function dealPrice(game) {
    if (game.discount >= 100) return strings.t("steam.deals.free")
    return ["-" + Commons.I18n.formatNumber(game.discount) + "%", game.final].filter(function(v) { return v }).join(" · ")
  }

  function dealCaption(game) {
    var parts = [dealPrice(game)]
    if (game.owned) parts.push(strings.t("steam.deals.owned"))
    else if (game.wishlist) parts.push(strings.t("steam.deals.wishlist"))
    return parts.join(" · ")
  }

  function selectGame(i) {
    var g = stGames[i]
    if (g) stGameId = g.id
  }

  // Launch, or Steam's own install, uninstall or properties dialog. The panel closes so
  // the game or the dialog isn't left behind it.
  function steamAction(action) {
    if (!steamModel || !stGame) return
    if (stLocal) { if (action === "folder" ? steamModel.openOtherFolder(stGame.id) : steamModel.launchOther(stGame.id)) close() }
    else if (action === "folder") { if (steamModel.openFolder(stGame.id)) close() }
    else if (steamModel.open(action, stGame.id)) close()
  }

  // The search box takes the keys while it has the focus.
  function startSearch() {
    stSearching = true
    cursorActive = true
    cursorByMouse = false
    cursorRow = "st-search"
    cursorCol = 0
  }

  // Leaves the box; dy 1 goes on to the games, -1 back to the tabs.
  function endSearch(dy) {
    stSearching = false
    if (dy > 0 && stGames.length) {
      cursorRow = "st-game-" + Math.max(0, stIndex)
      selectGame(Math.max(0, stIndex))
    } else if (dy < 0) cursorRow = "st-top"
    cursorCol = 0
  }

  onPageChanged: {
    syncPreview()
    stSearching = false
    if (page !== "stats" && opened) themeColorsFile.reload()
  }

  // Middle click and the Pause button: with nothing ticked, show what could be.
  function toggleGameMode() {
    if (!gm) return
    if (!gm.toggleGameMode() && !gm.gameOn && !gm.working) {
      setPage("gamemode")
      if (!opened) open()
    }
  }

  onBarChanged: resolveService()
  onServiceChanged: { syncPreview(); refreshGpuChoices() }
  Component.onCompleted: resolveService()
  Component.onDestruction: {
    if (heldService) heldService.releasePreview()
    if (watchedGameMode) watchedGameMode.watchers = Math.max(0, watchedGameMode.watchers - 1)
    if (watchedSteam) watchedSteam.watchers = Math.max(0, watchedSteam.watchers - 1)
  }

  Timer {
    interval: 1000
    repeat: true
    running: !root.service
    onTriggered: root.resolveService()
  }

  onOpenedChanged: {
    if (opened) resolveService()
    syncPreview()
    if (!opened) { stSearching = false; stQuery = ""; stDeckOpen = false; stFilterOpen = false; return }
    if (service) service.refreshMango()
    if (page !== "stats") themeColorsFile.reload()
    if (page === "steam" && stDeals && steamModel) steamModel.refreshDeals()
    if (page === "steam" && stLocal && steamModel) steamModel.refreshOthers()
    stNow = Date.now()
    cursorRow = page === "stats" ? "enabled" : page === "gamemode" ? "gm-power" : "st-top"
    cursorCol = 0
    cursorActive = false
    cursorByMouse = false
  }

  // Pick up an install finishing in the terminal.
  Timer {
    interval: 3000
    repeat: true
    running: root.opened && !!root.service && !root.mango.installed
    onTriggered: root.service.refreshMango()
  }

  // ------------------------------------------------------------ choices

  readonly property var positionGrid: [["top-left", "top-center", "top-right"],
                                       ["bottom-left", "bottom-center", "bottom-right"]]
  readonly property var layoutOptions: [
    { value: "stack", label: strings.t("layout.stack") },
    { value: "row", label: strings.t("layout.row") }
  ]
  readonly property var intervalOptions: Metrics.INTERVALS.map(function(v) {
    return { value: String(v), label: strings.t("interval.seconds").arg(Commons.I18n.formatNumber(v, v < 1 ? 1 : 0)) }
  })
  readonly property var screenChoices: [{ value: "", label: strings.t("screen.focused") }].concat(
    (service ? service.screenNames : []).map(function(name) { return { value: name, label: name } }))

  // Rebuilt only when the set of GPUs changes, not on every sample, so the
  // chips are not recreated under the pointer once a second.
  property var gpuChoices: [{ value: "auto", label: strings.t("gpu.auto") }]
  function refreshGpuChoices() {
    var next = [{ value: "auto", label: strings.t("gpu.auto") }].concat(Metrics.gpuOptions(service ? service.stats : null))
    if (JSON.stringify(next) !== JSON.stringify(gpuChoices)) gpuChoices = next
  }

  Connections {
    target: root.service
    function onStatsChanged() { root.refreshGpuChoices() }
  }

  readonly property real screenRatio: {
    var list = service && service.targetScreens.length ? service.targetScreens : Quickshell.screens
    var s = list.length ? list[0] : null
    return s && s.width > 0 && s.height > 0 ? Math.max(1.25, Math.min(2.4, s.width / s.height)) : 16 / 9
  }

  readonly property string statusText: {
    if (!service || !service.configReady) return strings.t("status.starting")
    if (service.statsFailed && service.streaming) return strings.t("status.failed")
    if (!config.enabled) return strings.t("status.off")
    var full = config.fullscreenOnly
    var names = service.targetScreens.filter(function(s) { return !full || service.fullscreenOn(s) })
      .map(function(s) { return String(s.name) })
    if (!names.length) return strings.t("status.waiting")
    return strings.t("status.on").arg(names.join(", "))
  }

  // Which sections are unfolded. Look and Behavior start folded; the choice
  // lasts until the shell restarts.
  property var folds: ({ position: true, stats: true, look: false, behavior: false, fps: true })
  readonly property bool positionOpen: folds.position
  readonly property bool statsOpen: folds.stats
  readonly property bool lookOpen: folds.look
  readonly property bool behaviorOpen: folds.behavior
  readonly property bool fpsOpen: folds.fps

  function toggleFold(id) {
    var name = id.replace(/^fold-/, "")
    if (!(name in folds)) return
    var next = {}
    for (var k in folds) next[k] = folds[k]
    next[name] = !next[name]
    folds = next
  }

  readonly property string positionSummary: strings.t("pos." + config.position)
  readonly property string statsSummary: strings.t("fold.statsCount").arg(Commons.I18n.formatNumber(config.metrics.length))
  readonly property string fpsSummary: !mango.installed ? strings.t("fold.fpsMissing")
    : (mango.managed ? strings.t("fold.fpsOn") : strings.t("fold.fpsOff"))

  readonly property string lookSummary: {
    var layout = root.layoutOptions.filter(function(o) { return o.value === config.layout })
    return (layout.length ? layout[0].label : "") + " · " + Commons.I18n.formatNumber(Math.round(config.scale * 100)) + "%"
  }

  readonly property string behaviorSummary: {
    var parts = [strings.t("interval.seconds").arg(Commons.I18n.formatNumber(config.interval, config.interval < 1 ? 1 : 0))]
    if (config.fullscreenOnly) parts.unshift(strings.t("fold.fullscreen"))
    return parts.join(" · ")
  }

  // ------------------------------------------------------------ game mode text

  function gb(mb) { return strings.t("gm.gb").arg(Commons.I18n.formatNumber(mb / 1024, 1)) }
  function size(mb) { return mb < 1024 ? strings.t("gm.mb").arg(Commons.I18n.formatNumber(mb, 0)) : gb(mb) }

  readonly property string gmFreeLine: gm && gm.mem ? strings.t("gm.ramFree").arg(gb(gm.mem.availableMB)).arg(gb(gm.mem.totalMB)) : ""
  readonly property string gmVramLine: gm && gm.gpu
    ? strings.t("gm.vramFree").arg(size(Math.max(0, gm.gpu.totalMB - gm.gpu.usedMB))).arg(size(gm.gpu.totalMB)) : ""

  // One line for RAM, one for VRAM (when there's a GPU to read).
  readonly property string gmStateLine: {
    if (!gm || !gm.status) return strings.t("gm.reading")
    if (gm.pending === "on") return strings.t("gm.freeing")
    if (gm.pending === "off") return strings.t("gm.restoring")
    var ram = gmFreeLine, vram = gmVramLine
    if (gm.gameOn) {
      if (gm.status.freedMB) ram += " · " + strings.t("gm.freed").arg(gb(gm.status.freedMB))
      if (vram && gm.status.freedVramMB) vram += " · " + strings.t("gm.freed").arg(size(gm.status.freedVramMB))
      var since = gm.status.since ? new Date(gm.status.since * 1000) : null
      return (since ? strings.t("gm.since").arg(since.toLocaleTimeString(Qt.locale(Commons.I18n.formatLocale), "HH:mm")) + "\n" : "")
        + ram + (vram ? "\n" + vram : "")
    }
    if (gm.tickedCount === 0) return ram + (vram ? "\n" + vram : "") + "\n" + strings.t("gm.tickHint")
    return ram + (gm.tickedMB > 0 ? " · " + strings.t("gm.frees").arg(gb(gm.tickedMB)) : "")
      + (vram ? "\n" + vram + (gm.tickedVram > 0 ? " · " + strings.t("gm.frees").arg(size(gm.tickedVram)) : "") : "")
  }

  // Apps (and the indexer) as one flat list, Docker projects in their own
  // folder, each biggest RAM first. Both keep indexes into gmItems so rows and
  // the cursor stay stable.
  readonly property var gmLoose: {
    var idx = []
    for (var i = 0; i < gmItems.length; i++) if (gmItems[i].kind !== "docker") idx.push(i)
    return idx.sort(function(a, b) { return gmItems[b].mb - gmItems[a].mb || a - b })
  }
  readonly property var gmGroups: {
    var idx = []
    for (var i = 0; i < gmItems.length; i++) if (gmItems[i].kind === "docker") idx.push(i)
    idx.sort(function(a, b) { return gmItems[b].mb - gmItems[a].mb || a - b })
    return idx.length ? [{ id: "docker", indexes: idx }] : []
  }
  readonly property var gmAll: ({ id: "all", indexes: gmItems.map(function(_, i) { return i }) })

  // Folded sections, by id. Unset means the default: open, except Docker
  // once it has more than four projects.
  property var gmFolds: ({})
  function gmGroupOpen(group) {
    var v = gmFolds[group.id]
    return v !== undefined ? v : !(group.id === "docker" && group.indexes.length > 4)
  }
  function toggleGmFold(id) {
    var group = gmGroups.find(function(g) { return g.id === id })
    if (!group) return
    var next = Object.assign({}, gmFolds)
    next[id] = !gmGroupOpen(group)
    gmFolds = next
  }

  function gmGroupItems(group) { return group.indexes.map(function(i) { return gmItems[i] }) }
  // On when every item in the section is ticked (or paused, while game mode is on).
  function gmGroupOn(group) {
    if (!gm) return false
    return gmGroupItems(group).every(function(i) { return gameOn ? gm.paused(i) : gm.ticked(i) })
  }
  function toggleGmGroup(id) {
    var group = id === "all" ? gmAll : gmGroups.find(function(g) { return g.id === id })
    if (group && gm) gm.setItems(gmGroupItems(group), !gmGroupOn(group))
  }
  function gmGroupSummary(group) {
    if (!gm) return ""
    var list = gmGroupItems(group)
    var on = list.filter(function(i) { return gameOn ? gm.paused(i) : gm.ticked(i) }).length
    var mb = list.reduce(function(sum, i) { return sum + i.mb }, 0)
    var line = strings.t(gameOn ? "gm.groupPaused" : "gm.groupTicked")
      .arg(Commons.I18n.formatNumber(on)).arg(Commons.I18n.formatNumber(list.length))
    return mb > 0 ? line + " · " + gb(mb) : line
  }

  function gmRowDescription(item) {
    var p = gm ? gm.itemPending[item.key] : undefined
    if (p === "pause") return strings.t(item.kind === "app" ? "gm.closing" : "gm.stopping")
    if (p === "resume") return strings.t(item.kind === "app" ? "gm.reopening" : "gm.starting")
    return item.detail
  }

  readonly property string barTooltip: {
    var lines = [hudOn ? strings.t("bar.tooltipOn") : strings.t("bar.tooltip")]
    if (gm && gm.status) {
      if (gm.working) lines.push(strings.t(gm.gameOn ? "gm.barWorking" : "gm.restoring"))
      else {
        lines.push(strings.t(gm.gameOn ? "gm.barOn" : "gm.barOff"))
        if (gmFreeLine) lines.push(gmFreeLine)
        if (gmVramLine) lines.push(gmVramLine)
      }
      lines.push(strings.t(gm.gameOn ? "gm.middleOff" : "gm.middleOn"))
    }
    return lines.join("\n")
  }

  function positionAt(rowId, col) {
    var row = positionGrid[rowId === "pos-top" ? 0 : 1]
    return row[Math.max(0, Math.min(row.length - 1, col))]
  }

  function setValue(key, value) { if (service) service.setValue(key, value) }

  property bool copied: false
  function copyLaunchOption() {
    if (!service) return
    service.copyLaunchOption()
    copied = true
    copiedTimer.restart()
  }

  Timer {
    id: copiedTimer
    interval: 1600
    onTriggered: root.copied = false
  }

  // ------------------------------------------------------------ cursor
  //
  // One list of rows, top to bottom; each row has `count` targets side by
  // side. j/k walks rows, h/l walks targets (or nudges a slider), Enter
  // activates. Hover moves the same cursor, so mouse and keys share one
  // highlight.

  property string cursorRow: "enabled"
  property int cursorCol: 0
  property bool cursorActive: false

  readonly property var navRows: {
    var list = [{ id: "page", count: pages.length }]
    if (page === "steam") {
      if (stPhase !== "ready") return list
      list.push({ id: "st-top", count: 4 + (stDeals ? 2 : stSortOptions.length) }, { id: "st-search", count: stFiltered ? 2 : 1 })
      if (stChips.length) list.push({ id: "st-chips", count: stChips.length + 1 })
      if (stFilterOpen) return list.concat(stCardRows)
      for (var s = 0; s < stGames.length; s++) list.push({ id: "st-game-" + s, count: 1 })
      if (stFiltered && stGame) list.push({ id: "st-deck", count: 1 })
      if (stActions.length) list.push({ id: "st-actions", count: stActions.length })
      if (stHasDlc) list.push({ id: "st-dlc", count: 1 })
      return list
    }
    if (page === "gamemode") {
      list.push({ id: "gm-power", count: 1 }, { id: "gm-auto", count: 1 })
      if (gmItems.length) list.push({ id: "gm-all", count: 1 })
      for (var l = 0; l < gmLoose.length; l++) list.push({ id: "gm-item-" + gmLoose[l], count: 1 })
      for (var g = 0; g < gmGroups.length; g++) {
        list.push({ id: "gm-group-" + gmGroups[g].id, count: 2 })
        if (gmGroupOpen(gmGroups[g]))
          for (var n = 0; n < gmGroups[g].indexes.length; n++) list.push({ id: "gm-item-" + gmGroups[g].indexes[n], count: 1 })
      }
      return list
    }
    list.push({ id: "enabled", count: 1 }, { id: "fold-position", count: 1 })
    if (positionOpen) list.push({ id: "pos-top", count: 3 }, { id: "pos-bottom", count: 3 })
    list.push({ id: "fold-stats", count: 1 })
    if (statsOpen) {
      for (var i = 0; i < Metrics.GROUPS.length; i++)
        list.push({ id: "metrics-" + Metrics.GROUPS[i].id, count: Metrics.GROUPS[i].metrics.length })
    }
    list.push({ id: "fold-look", count: 1 })
    if (lookOpen) {
      list.push({ id: "layout", count: Metrics.LAYOUTS.length })
      list.push({ id: "scale", count: 1, slider: true })
      list.push({ id: "opacity", count: 1, slider: true })
    }
    list.push({ id: "fold-behavior", count: 1 })
    if (behaviorOpen) {
      list.push({ id: "fullscreen", count: 1 })
      list.push({ id: "interval", count: Metrics.INTERVALS.length })
      if (gpuChoices.length > 2) list.push({ id: "gpu", count: gpuChoices.length })
      if (screenChoices.length > 2) list.push({ id: "screen", count: screenChoices.length })
    }
    list.push({ id: "fold-fps", count: 1 })
    if (fpsOpen) {
      if (!mango.installed) list.push({ id: "install", count: 1 })
      list.push({ id: "fps", count: 1 })
      if (mango.managed) list.push({ id: "graph", count: 1 })
      list.push({ id: "copy", count: 1 })
    }
    return list
  }

  function rowIndex(id) {
    for (var i = 0; i < navRows.length; i++) if (navRows[i].id === id) return i
    return -1
  }

  function cursorOn(id, col) {
    return cursorActive && cursorRow === id && cursorCol === (col || 0)
  }

  function cursorIndexFor(id) {
    return cursorActive && cursorRow === id ? cursorCol : -1
  }

  // Set when the mouse moved the cursor. Hover never scrolls the panel:
  // scrolling would slide a different row under the pointer.
  property bool cursorByMouse: false

  function point(id, col) {
    cursorByMouse = true
    cursorActive = true
    cursorRow = id
    cursorCol = col || 0
  }

  function moveCursor(dx, dy) {
    var rows = navRows
    var r = rowIndex(cursorRow)
    if (r < 0) { cursorRow = rows[0].id; cursorCol = 0; return }
    // Steam: right from a game goes to its buttons, left or up comes back.
    // Inside the details: Deck badge, buttons, DLC header, top to bottom.
    if (page === "steam") {
      var gameRow = stIndex >= 0 ? "st-game-" + stIndex : "st-top"
      var deckRow = rowIndex("st-deck") >= 0
      var detail = cursorRow === "st-deck" || cursorRow === "st-actions" || cursorRow === "st-dlc"
      if (detail && dx < 0 && cursorCol === 0) { cursorRow = gameRow; cursorCol = 0; return }
      if (cursorRow === "st-deck" && dy < 0) { cursorRow = gameRow; cursorCol = 0; return }
      if (cursorRow === "st-deck" && dy > 0) {
        if (stActions.length) { cursorRow = "st-actions"; cursorCol = 0 }
        return
      }
      if (cursorRow === "st-actions" && dy < 0) { cursorRow = deckRow ? "st-deck" : gameRow; cursorCol = 0; return }
      if (cursorRow === "st-actions" && dy > 0) {
        if (stHasDlc) { cursorRow = "st-dlc"; cursorCol = 0 }
        return
      }
      if (cursorRow === "st-dlc" && dy < 0) { cursorRow = stActions.length ? "st-actions" : deckRow ? "st-deck" : gameRow; cursorCol = 0; return }
      if (cursorRow === "st-dlc" && dy > 0) return
      if (cursorRow.indexOf("st-game-") === 0 && dx > 0 && (deckRow || stActions.length)) {
        cursorRow = deckRow ? "st-deck" : "st-actions"
        cursorCol = 0
        return
      }
      // Down off the last game stays in the list.
      if (cursorRow.indexOf("st-game-") === 0 && dy > 0 && Number(cursorRow.slice(8)) >= stGames.length - 1) return
    }
    if (dy !== 0) {
      var next = Math.max(0, Math.min(rows.length - 1, r + dy))
      cursorRow = rows[next].id
      cursorCol = Math.min(cursorCol, rows[next].count - 1)
      // The details follow the keyboard through the games.
      if (cursorRow.indexOf("st-game-") === 0) selectGame(Number(cursorRow.slice(8)))
      return
    }
    var row = rows[r]
    if (row.slider) {
      if (row.id === "scale") setValue("scale", config.scale + dx * 0.05)
      else setValue("opacity", config.opacity + dx * 0.05)
      return
    }
    cursorCol = Math.max(0, Math.min(row.count - 1, cursorCol + dx))
  }

  function activateCursor() {
    if (!service) return
    var id = cursorRow
    var col = cursorCol
    if (id === "page") setPage(pages[col] || "stats")
    else if (id === "st-top") {
      if (col < 4) setSteamTab(stTabs.options[col].value)
      else if (stDeals) { if (steamModel) steamModel.setDealMin(stDealMin + (col === 4 ? -5 : 5)) }
      else if (stSortOptions[col - 4]) stSort = stSortOptions[col - 4].value
    }
    else if (id.indexOf("st-game-") === 0) {
      selectGame(Number(id.slice(8)))
      if (stFiltered) { cursorRow = "st-deck"; cursorCol = 0 }
      else if (stActions.length) { cursorRow = "st-actions"; cursorCol = 0 }
    }
    else if (id === "st-search") { if (col === 1) openFilters(!stFilterOpen); else startSearch() }
    else if (id === "st-chips") { if (col < stChips.length) removeChip(stChips[col]); else clearFilters() }
    else if (id.indexOf("st-fc-") === 0) activateCard(id, col)
    else if (id === "st-deck") openDeck()
    else if (id === "st-dlc") stDlcOpen = !stDlcOpen
    else if (id === "st-actions") { if (stActions[col]) steamAction(stActions[col]) }
    else if (id === "gm-power") toggleGameMode()
    else if (id === "gm-auto") { if (gm) gm.setAuto(!gm.autoEnabled) }
    else if (id === "gm-all") toggleGmGroup("all")
    else if (id.indexOf("gm-group-") === 0) { if (col === 0) toggleGmFold(id.slice(9)); else toggleGmGroup(id.slice(9)) }
    else if (id.indexOf("gm-item-") === 0) { if (gm) gm.clickItem(gmItems[Number(id.slice(8))]) }
    else if (id === "enabled") service.setEnabled(!config.enabled)
    else if (id.indexOf("fold-") === 0) toggleFold(id)
    else if (id === "pos-top" || id === "pos-bottom") setValue("position", positionAt(id, col))
    else if (id.indexOf("metrics-") === 0) {
      for (var i = 0; i < Metrics.GROUPS.length; i++)
        if ("metrics-" + Metrics.GROUPS[i].id === id) service.toggleMetric(Metrics.GROUPS[i].metrics[col])
    }
    else if (id === "layout") setValue("layout", Metrics.LAYOUTS[col])
    else if (id === "fullscreen") setValue("fullscreenOnly", !config.fullscreenOnly)
    else if (id === "interval") setValue("interval", Metrics.INTERVALS[col])
    else if (id === "gpu" && gpuChoices[col]) setValue("gpu", gpuChoices[col].value)
    else if (id === "screen" && screenChoices[col]) setValue("screen", screenChoices[col].value)
    else if (id === "install") service.installMango()
    else if (id === "fps") service.setFps(!mango.managed)
    else if (id === "graph") service.setFpsGraph(!mango.graph)
    else if (id === "copy") copyLaunchOption()
  }

  // A row can vanish under the cursor (MangoHud got installed, a GPU went
  // away): land on the FPS switch, which is always there.
  function clampCursor() {
    var r = rowIndex(cursorRow)
    if (r < 0) {
      cursorRow = rowIndex("fps") >= 0 ? "fps" : navRows[navRows.length > 1 ? 1 : 0].id
      cursorCol = 0
      return
    }
    cursorCol = Math.max(0, Math.min(navRows[r].count - 1, cursorCol))
  }

  onNavRowsChanged: clampCursor()

  // Keep the keyboard target inside the viewport when the panel scrolls.
  function ensureCursorVisible(item) {
    var scrollArea = panel.loadedContent ? panel.loadedContent.scrollArea : null
    if (cursorByMouse || !item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    var margin = 6
    if (top < flick.contentY + margin) flick.contentY = Math.max(0, top - margin)
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = bottom + margin - flick.height
  }

  // ------------------------------------------------------------ bar icon

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    active: root.hudOn || root.gameOn
    activeColor: Commons.Color.accent
    tooltipText: root.barTooltip
    // Left opens the panel; right flips the HUD; middle flips game mode.
    onPressed: function(b) {
      if (b === Qt.RightButton) {
        if (root.service) root.service.setEnabled(!root.config.enabled)
      } else if (b === Qt.MiddleButton) {
        root.toggleGameMode()
      } else if (b === Qt.LeftButton) {
        root.toggle()
      }
    }
  }

  // ------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(root.page === "steam" ? Style.space(760) : Style.space(400))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(660))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias scrollArea: scrollArea
      implicitHeight: panelColumn.implicitHeight
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        root.cursorByMouse = false
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.stFilterOpen) root.openFilters(false)
        else if (root.stDeckOpen) root.stDeckOpen = false
        else root.close()
      }
      blocked: root.stSearching
      onTextKey: function(t, modifiers) { if (t === "/" && root.page === "steam" && root.stPhase === "ready") root.startSearch() }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(10)

          // ---------- Pages ----------
          ButtonGroup {
            id: pageTabs
            options: root.pages.map(function(p) { return { value: p, label: strings.t("page." + p) } })
            value: root.page
            focusable: false
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            cursorIndex: root.cursorIndexFor("page")
            onChanged: function(v) { root.setPage(v) }
            onHovered: function(index, h) { if (h) root.point("page", index) }
          }

          Column {
            id: statsPage
            visible: root.page === "stats"
            width: parent.width
            spacing: Style.space(10)

            // ---------- Hero: icon · title/status · switch ----------
            Item {
              width: parent.width
              implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroSwitch.implicitHeight)

              Text {
                id: heroIcon
                textFormat: Text.PlainText
                text: ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                id: heroLabels
                anchors.left: heroIcon.right
                anchors.leftMargin: Style.space(14)
                anchors.right: heroSwitch.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: strings.t("panel.title")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Caption {
                  text: root.statusText
                  color: root.service && root.service.statsFailed && root.service.streaming ? Commons.Color.urgent : root.dimFg
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }
              }

              ToggleSwitch {
                id: heroSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.config.enabled
                busy: !root.service || !root.service.configReady
                hasCursor: root.cursorOn("enabled")
                foreground: root.fg
                onToggled: if (root.service) root.service.setEnabled(!root.config.enabled)
                onHovered: function(h) { if (h) root.point("enabled", 0) }
              }
            }

            // ---------- Position ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-position"
                text: strings.t("section.position")
                hint: strings.t("position.hint")
                summary: root.positionSummary
                open: root.positionOpen
              }

              ScreenPicker {
                width: parent.width
                visible: root.positionOpen
              }
            }

            // ---------- Stats ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-stats"
                text: strings.t("section.stats")
                summary: root.statsSummary
                open: root.statsOpen
              }

              Repeater {
                model: Metrics.GROUPS

                MetricGroupRow {
                  required property var modelData
                  visible: root.statsOpen
                  width: panelColumn.width
                  group: modelData
                }
              }
            }

            // ---------- Look ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-look"
                text: strings.t("section.look")
                summary: root.lookSummary
                open: root.lookOpen
              }

              LabeledRow {
                width: parent.width
                visible: root.lookOpen
                label: strings.t("look.layout")

                ButtonGroup {
                  options: root.layoutOptions
                  value: root.config.layout
                  focusable: false
                  cursorIndex: root.cursorIndexFor("layout")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  spacing: Style.spacing.xs
                  onChanged: function(v) { root.setValue("layout", v) }
                  onHovered: function(i, h) { if (h) root.point("layout", i) }
                }
              }

              SliderRow {
                width: parent.width
                visible: root.lookOpen
                rowId: "scale"
                label: strings.t("look.size")
                value: root.config.scale
                minimum: Metrics.SCALE_MIN
                maximum: Metrics.SCALE_MAX
                onCommit: function(v) { root.setValue("scale", v) }
              }

              SliderRow {
                width: parent.width
                visible: root.lookOpen
                rowId: "opacity"
                label: strings.t("look.backdrop")
                value: root.config.opacity
                minimum: 0
                maximum: 1
                onCommit: function(v) { root.setValue("opacity", v) }
              }
            }

            // ---------- Behavior ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-behavior"
                text: strings.t("section.behavior")
                summary: root.behaviorSummary
                open: root.behaviorOpen
              }

              SmallToggle {
                id: fullscreenToggle
                width: parent.width
                visible: root.behaviorOpen
                label: strings.t("behavior.fullscreenOnly")
                description: strings.t("behavior.fullscreenOnlyHint")
                checked: root.config.fullscreenOnly
                hasCursor: root.cursorOn("fullscreen")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(fullscreenToggle)
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: root.setValue("fullscreenOnly", !root.config.fullscreenOnly)
                onHovered: function(h) { if (h) root.point("fullscreen", 0) }
              }

              LabeledRow {
                width: parent.width
                visible: root.behaviorOpen
                label: strings.t("behavior.interval")

                ButtonGroup {
                  options: root.intervalOptions
                  value: String(root.config.interval)
                  focusable: false
                  cursorIndex: root.cursorIndexFor("interval")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  spacing: Style.spacing.xs
                  onChanged: function(v) { root.setValue("interval", Number(v)) }
                  onHovered: function(i, h) { if (h) root.point("interval", i) }
                }
              }

              LabeledRow {
                width: parent.width
                visible: root.behaviorOpen && root.gpuChoices.length > 2
                label: strings.t("behavior.gpu")

                ButtonGroup {
                  options: root.gpuChoices
                  value: root.config.gpu
                  focusable: false
                  cursorIndex: root.cursorIndexFor("gpu")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  spacing: Style.spacing.xs
                  onChanged: function(v) { root.setValue("gpu", v) }
                  onHovered: function(i, h) { if (h) root.point("gpu", i) }
                }
              }

              LabeledRow {
                width: parent.width
                visible: root.behaviorOpen && root.screenChoices.length > 2
                label: strings.t("behavior.screen")

                ButtonGroup {
                  options: root.screenChoices
                  value: root.config.screen
                  focusable: false
                  cursorIndex: root.cursorIndexFor("screen")
                  foreground: root.fg
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  spacing: Style.spacing.xs
                  onChanged: function(v) { root.setValue("screen", v) }
                  onHovered: function(i, h) { if (h) root.point("screen", i) }
                }
              }
            }

            // ---------- FPS through MangoHud ----------
            PanelSeparator { foreground: root.fg }

            Column {
              width: parent.width
              spacing: Style.space(6)

              FoldTitle {
                rowId: "fold-fps"
                text: strings.t("section.fps")
                summary: root.fpsSummary
                open: root.fpsOpen
              }

              Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.fpsOpen

              Item {
                width: parent.width
                visible: !root.mango.installed
                implicitHeight: Math.max(missingText.implicitHeight, installButton.implicitHeight)

                Caption {
                  id: missingText
                  text: strings.t("fps.missing")
                  wrapMode: Text.WordWrap
                  anchors.left: parent.left
                  anchors.right: installButton.left
                  anchors.rightMargin: Style.space(10)
                  anchors.verticalCenter: parent.verticalCenter
                }

                PillButton {
                  id: installButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("fps.install")
                  iconText: ""
                  foreground: root.fg
                  hasCursor: root.cursorOn("install")
                  onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(installButton)
                  onClicked: if (root.service) root.service.installMango()
                  onHovered: function(h) { if (h) root.point("install", 0) }
                }
              }

              SmallToggle {
                id: fpsToggle
                width: parent.width
                label: strings.t("fps.show")
                description: strings.t("fps.showHint")
                checked: root.mango.managed
                hasCursor: root.cursorOn("fps")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(fpsToggle)
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.setFps(!root.mango.managed)
                onHovered: function(h) { if (h) root.point("fps", 0) }
              }

              SmallToggle {
                id: graphToggle
                width: parent.width
                visible: root.mango.managed
                label: strings.t("fps.graph")
                description: strings.t("fps.graphHint")
                checked: root.mango.graph
                hasCursor: root.cursorOn("graph")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(graphToggle)
                foreground: root.fg
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.setFpsGraph(!root.mango.graph)
                onHovered: function(h) { if (h) root.point("graph", 0) }
              }

              Caption {
                width: parent.width
                text: strings.t("fps.launchHint")
                wrapMode: Text.WordWrap
              }

              PillButton {
                id: copyButton
                text: root.copied ? strings.t("fps.copied") : strings.t("fps.copy")
                iconText: root.copied ? "" : ""
                foreground: root.fg
                hasCursor: root.cursorOn("copy")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(copyButton)
                onClicked: root.copyLaunchOption()
                onHovered: function(h) { if (h) root.point("copy", 0) }
              }

              Caption {
                width: parent.width
                visible: !!root.service && root.service.mangoFailed
                text: strings.t("fps.failed")
                color: Commons.Color.urgent
                font.bold: true
                wrapMode: Text.WordWrap
              }
              }
            }

          }

          // ---------- Game mode ----------
          Column {
            id: gamePage
            visible: root.page === "gamemode"
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: Math.max(gmGlyph.implicitHeight, gmText.implicitHeight, gmPower.implicitHeight)

              Text {
                id: gmGlyph
                textFormat: Text.PlainText
                text: ""
                color: root.gameOn ? root.stGreen : root.fg
                opacity: root.gameOn ? 1 : 0.5
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                id: gmText
                anchors.left: gmGlyph.right
                anchors.leftMargin: Style.space(14)
                anchors.right: gmPower.left
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  textFormat: Text.PlainText
                  text: strings.t(root.gameOn ? "gm.titleOn" : "gm.titleOff")
                  color: root.gameOn ? root.stGreen : root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                  width: parent.width
                }

                Caption {
                  text: root.gmStateLine
                  wrapMode: Text.WordWrap
                  width: parent.width
                }
              }

              PillButton {
                id: gmPower
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t(root.gm && root.gm.working ? "gm.wait" : root.gameOn ? "gm.restoreAll" : "gm.pauseTicked")
                enabled: !!root.gm && !root.gm.working && !!root.gm.status && (root.gameOn || root.gm.tickedCount > 0)
                selected: root.gameOn
                // Pausing in yellow, bringing everything back in green.
                foreground: root.gameOn ? root.stGreen : root.stYellow
                accent: foreground
                hasCursor: root.cursorOn("gm-power")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gmPower)
                onClicked: root.toggleGameMode()
                onHovered: function(h) { if (h) root.point("gm-power", 0) }
              }
            }

            SmallToggle {
              id: gmAuto
              tinted: true
              width: parent.width
              label: strings.t("gm.auto")
              description: root.gm && root.gm.autoEnabled && root.gm.game !== ""
                ? strings.t("gm.autoPlaying").arg(root.gm.game) : strings.t("gm.autoHint")
              checked: !!root.gm && root.gm.autoEnabled
              hasCursor: root.cursorOn("gm-auto")
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gmAuto)
              foreground: root.fg
              onClicked: if (root.gm) root.gm.setAuto(!root.gm.autoEnabled)
              onHovered: function(h) { if (h) root.point("gm-auto", 0) }
            }

            PanelSeparator { foreground: root.fg }

            // The caption, with the switch for every item at its right end,
            // lined up with the rows' switches.
            Item {
              id: gmAllRow
              visible: root.gmItems.length > 0
              width: parent.width
              implicitHeight: Math.max(gmHeader.implicitHeight, gmAllSwitch.implicitHeight)

              Caption {
                id: gmHeader
                anchors.left: parent.left
                anchors.right: gmAllLabel.left
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
                text: strings.t(root.gameOn ? "gm.headerOn" : "gm.headerOff")
                wrapMode: Text.WordWrap
              }

              Text {
                id: gmAllLabel
                anchors.right: gmAllSwitch.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: strings.t("gm.all")
                color: root.dimFg
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleGmGroup("all")
                }
              }

              TintSwitch {
                id: gmAllSwitch
                checked: root.gmGroupOn(root.gmAll)
                hasCursor: root.cursorOn("gm-all")
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gmAllRow)
                trackHeight: Style.space(16)
                anchors.right: parent.right
                anchors.rightMargin: Style.spacing.sm + Style.space(2) - (cursorRing ? cursorPad : 0)
                anchors.verticalCenter: parent.verticalCenter
                onToggled: root.toggleGmGroup("all")
                onHovered: function(h) { if (h) root.point("gm-all", 0) }
              }
            }

            // Indexed rather than bound to the arrays, so a reading doesn't
            // rebuild the rows under the pointer.
            Repeater {
              model: root.gmLoose.length

              delegate: GmRow {
                required property int index
                itemIndex: root.gmLoose[index]
              }
            }

            // Docker projects, in a folder.
            Repeater {
              model: root.gmGroups.length

              delegate: Column {
                id: gmSection
                required property int index
                readonly property var group: root.gmGroups[index] || ({ id: "", indexes: [] })
                readonly property bool open: root.gmGroupOpen(group)
                width: gamePage.width
                spacing: Style.space(6)

                GroupTitle {
                  rowId: "gm-group-" + gmSection.group.id
                  text: strings.t("gm.group." + (gmSection.group.id || "docker"))
                  summary: root.gmGroupSummary(gmSection.group)
                  open: gmSection.open
                  checked: root.gmGroupOn(gmSection.group)
                }

                Repeater {
                  model: gmSection.open ? gmSection.group.indexes.length : 0

                  delegate: GmRow {
                    required property int index
                    itemIndex: gmSection.group.indexes[index]
                  }
                }
              }
            }

            Caption {
              visible: !!root.gm && !!root.gm.status && root.gmItems.length === 0
              width: parent.width
              text: strings.t("gm.empty")
            }

            PanelSeparator { foreground: root.fg }

            Caption {
              width: parent.width
              text: strings.t("gm.footer")
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Steam ----------
          // Games on the left, the picked one on the right, drives below.
          Item {
            id: steamPage
            visible: root.page === "steam"
            width: parent.width
            implicitHeight: root.stPhase === "ready" ? Style.space(500) : stStatus.implicitHeight
            readonly property bool ready: root.stPhase === "ready"

            Caption {
              id: stStatus
              visible: !steamPage.ready
              width: parent.width
              text: strings.t("steam." + root.stPhase)
              color: root.stPhase === "failed" ? Commons.Color.urgent : root.dimFg
              wrapMode: Text.WordWrap
            }

            // Which games, and their order: one keyboard row.
            Item {
              id: stTop
              visible: steamPage.ready
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              implicitHeight: Math.max(stTabs.implicitHeight, stSorts.implicitHeight)

              ButtonGroup {
                id: stTabs
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                options: [
                  { value: "installed", label: strings.t("steam.installed").arg(Commons.I18n.formatNumber(root.steamModel ? Library.countInstalled(root.steamModel.games, true, root.stQuery, root.stFilterFor(true)) : 0)) },
                  { value: "other", label: strings.t("steam.notInstalled").arg(Commons.I18n.formatNumber(root.steamModel ? Library.countInstalled(root.steamModel.games, false, root.stQuery, root.stFilterFor(false)) : 0)) },
                  { value: "deals", label: root.steamModel && root.steamModel.deals
                      ? strings.t("steam.deals.count").arg(Commons.I18n.formatNumber(root.stDealList.length)) : strings.t("steam.deals") },
                  { value: "local", label: root.steamModel && root.steamModel.others
                      ? strings.t("steam.local.count").arg(Commons.I18n.formatNumber(Library.otherList(root.steamModel.otherGames, "name", root.stQuery).length))
                      : strings.t("steam.local") }
                ]
                value: root.stTab
                focusable: false
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                spacing: Style.spacing.xs
                cursorIndex: { var c = root.cursorIndexFor("st-top"); return c >= 0 && c < 4 ? c : -1 }
                onChanged: function(v) { root.setSteamTab(v) }
                onHovered: function(i, h) { if (h) root.point("st-top", i) }
              }

              // Deals: wishlist games show from this discount up.
              Row {
                id: stDealMinRow
                visible: root.stDeals
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xs

                PillButton {
                  text: "\u2212"
                  foreground: root.fg
                  enabled: root.stDealMin > 5
                  hasCursor: root.cursorOn("st-top", 4)
                  onClicked: if (root.steamModel) root.steamModel.setDealMin(root.stDealMin - 5)
                  onHovered: function(h) { if (h) root.point("st-top", 4) }
                }

                Caption {
                  anchors.verticalCenter: parent.verticalCenter
                  text: strings.t("steam.deals.min").arg(Commons.I18n.formatNumber(root.stDealMin))
                  color: root.fg
                }

                PillButton {
                  text: "+"
                  foreground: root.fg
                  enabled: root.stDealMin < 100
                  hasCursor: root.cursorOn("st-top", 5)
                  onClicked: if (root.steamModel) root.steamModel.setDealMin(root.stDealMin + 5)
                  onHovered: function(h) { if (h) root.point("st-top", 5) }
                }
              }

              ButtonGroup {
                id: stSorts
                visible: !root.stDeals
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                options: root.stSortOptions
                value: root.stSortShown
                focusable: false
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                spacing: Style.spacing.xs
                cursorIndex: { var c = root.cursorIndexFor("st-top"); return c >= 4 ? c - 4 : -1 }
                onChanged: function(v) { root.stSort = v }
                onHovered: function(i, h) { if (h) root.point("st-top", i + 4) }
              }
            }

            // Search: Enter on it or "/" starts typing; Esc clears, then leaves.
            CursorSurface {
              id: stSearch
              visible: steamPage.ready
              anchors.left: parent.left
              anchors.top: stTop.bottom
              anchors.topMargin: Style.space(10)
              width: stList.width - Style.space(8) - (stFilterButton.visible ? stFilterButton.width + Style.space(6) : 0)
              implicitHeight: Style.space(34)
              bordered: true
              foreground: root.fg
              current: root.stSearching
              hasCursor: root.cursorOn("st-search")

              Caption {
                id: stSearchIcon
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                text: "\uf002"
              }

              Caption {
                anchors.left: stSearchInput.left
                anchors.right: stSearchInput.right
                anchors.verticalCenter: parent.verticalCenter
                visible: stSearchInput.text === ""
                text: strings.t("steam.search")
                elide: Text.ElideRight
              }

              TextInput {
                id: stSearchInput
                anchors.left: stSearchIcon.right
                anchors.leftMargin: Style.space(8)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                clip: true
                maximumLength: 80
                color: root.fg
                selectionColor: Util.alpha(root.fg, 0.3)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                Component.onCompleted: text = root.stQuery
                onTextChanged: if (text !== root.stQuery) root.stQuery = text
                onActiveFocusChanged: if (!activeFocus && root.stSearching) root.stSearching = false
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Escape) {
                    if (text) text = ""
                    else root.endSearch(0)
                  } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Return
                             || event.key === Qt.Key_Enter || event.key === Qt.Key_Tab) {
                    root.endSearch(1)
                  } else if (event.key === Qt.Key_Up) {
                    root.endSearch(-1)
                  } else return
                  event.accepted = true
                }

                Connections {
                  target: root
                  function onStQueryChanged() { if (stSearchInput.text !== root.stQuery) stSearchInput.text = root.stQuery }
                  function onStSearchingChanged() {
                    if (root.stSearching) stSearchInput.forceActiveFocus()
                    else keyCatcher.forceActiveFocus()
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                enabled: !root.stSearching
                cursorShape: Qt.IBeamCursor
                onClicked: root.startSearch()
              }

              HoverHandler {
                onHoveredChanged: if (hovered) root.point("st-search", 0)
              }
            }

            // Filters: one button beside the search opens the card; what's in
            // use shows as chips under it, each removable.
            PillButton {
              id: stFilterButton
              visible: steamPage.ready && root.stFiltered
              anchors.left: stSearch.right
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: stSearch.verticalCenter
              height: stSearch.height
              iconText: "\uf0b0"
              text: root.stActiveFilters > 0 ? strings.t("steam.filter.buttonOn").arg(Commons.I18n.formatNumber(root.stActiveFilters))
                : strings.t("steam.filter.button")
              tooltipText: strings.t("steam.filter.tip")
              selected: root.stFilterOpen
              foreground: root.stActiveFilters > 0 ? Commons.Color.accent : root.fg
              accent: Commons.Color.accent
              hasCursor: root.cursorOn("st-search", 1)
              onClicked: root.openFilters(!root.stFilterOpen)
              onHovered: function(h) { if (h) root.point("st-search", 1) }
            }

            Flow {
              id: stChipRow
              visible: steamPage.ready && root.stChips.length > 0
              anchors.left: parent.left
              anchors.top: stSearch.bottom
              anchors.topMargin: Style.space(8)
              width: stList.width - Style.space(8)
              spacing: Style.space(6)

              Repeater {
                model: root.stChips.length

                Badge {
                  required property int index
                  readonly property var chip: root.stChips[index] || ({ group: "", value: "" })
                  text: root.chipLabel(chip)
                  tint: root.chipColor(chip)
                  clickable: true
                  trailing: "\uf00d"
                  tooltip: strings.t("steam.filter.remove")
                  hasCursor: root.cursorOn("st-chips", index)
                  onClicked: root.removeChip(chip)
                  onHovered: function(h) { if (h) root.point("st-chips", index) }
                }
              }

              Badge {
                text: strings.t("steam.filter.clear")
                tint: root.dimFg
                clickable: true
                hasCursor: root.cursorOn("st-chips", root.stChips.length)
                onClicked: root.clearFilters()
                onHovered: function(h) { if (h) root.point("st-chips", root.stChips.length) }
              }
            }

            // Indexed, so a new reading updates the rows in place.
            ListView {
              id: stList
              visible: steamPage.ready
              anchors.left: parent.left
              anchors.top: stChipRow.visible ? stChipRow.bottom : stSearch.bottom
              anchors.topMargin: Style.space(8)
              anchors.bottom: stDriveBox.top
              anchors.bottomMargin: Style.space(10)
              width: Math.round(parent.width * 0.42)
              clip: true
              spacing: Style.space(4)
              boundsBehavior: Flickable.StopAtBounds
              model: root.stGames.length
              ScrollBar.vertical: ScrollBar { policy: stList.contentHeight > stList.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

              delegate: GameRow {
                required property int index
                listIndex: index
                width: stList.width - Style.space(8)
              }

              // A new order or list keeps the picked game in view.
              readonly property string order: root.stSortShown + ":" + root.stTab + ":" + root.stQuery + ":" + JSON.stringify(root.stFilterFor(root.stInstalled))
              onOrderChanged: Qt.callLater(function() { if (root.stIndex >= 0) stList.positionViewAtIndex(root.stIndex, ListView.Contain) })
              Component.onCompleted: if (root.stIndex > 0) positionViewAtIndex(root.stIndex, ListView.Center)
            }

            Caption {
              visible: steamPage.ready && root.stGames.length === 0
              anchors.left: stList.left
              anchors.right: stList.right
              anchors.top: stList.top
              text: root.stLocal ? (!root.steamModel || root.steamModel.othersPhase !== "ready"
                    ? strings.t("steam.local." + (root.steamModel ? root.steamModel.othersPhase : "reading"))
                    : strings.t(root.stQuery.trim() ? "steam.noMatch" : "steam.local.none"))
                : !root.stDeals ? strings.t(root.stQuery.trim() ? "steam.noMatch"
                    : root.stActiveFilters > 0 ? "steam.filter.none"
                    : root.stInstalled ? "steam.noneInstalled" : "steam.allInstalled")
                : !root.steamModel || root.steamModel.dealsPhase !== "ready" ? strings.t("steam.deals." + (root.steamModel ? root.steamModel.dealsPhase : "reading"))
                : root.stQuery.trim() ? strings.t("steam.noMatch")
                : strings.t(root.steamModel.deals.wishlistOk ? "steam.deals.none" : "steam.deals.noneNoWishlist")
              color: root.steamModel && (root.stDeals && root.steamModel.dealsPhase === "failed"
                || root.stLocal && root.steamModel.othersPhase === "failed") ? Commons.Color.urgent : root.dimFg
              wrapMode: Text.WordWrap
            }

            Item {
              id: stDetails
              visible: steamPage.ready && !!root.stGame
              anchors.left: stList.right
              anchors.leftMargin: Style.space(16)
              anchors.right: parent.right
              anchors.top: stSearch.top
              anchors.bottom: stList.bottom
              readonly property var game: root.stGame || ({ id: "", name: "", installed: false, size: 0, drive: -1, lastPlayed: 0, playtime: 0, cover: "", deck: "unknown", folder: "", launchOptions: "" })

              Cover {
                id: stCover
                visible: !root.stDeals
                anchors.left: parent.left
                anchors.top: parent.top
                width: root.stDeals ? 0 : root.stLocal ? Style.space(96) : Style.space(150)
                height: root.stDeals ? 0 : root.stLocal ? width : Math.round(width * 1.5)
                iconMode: root.stLocal
                icon: root.stLocal ? stDetails.game.icon || "" : ""
                path: root.stLocal ? "" : stDetails.game.cover || ""
              }

              // Name, status badges, then label / value facts.
              Column {
                id: stInfo
                anchors.left: stCover.right
                anchors.leftMargin: root.stDeals ? 0 : Style.space(16)
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Style.space(10)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: stDetails.game.name
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  wrapMode: Text.WordWrap
                  maximumLineCount: 3
                  elide: Text.ElideRight
                }

                // Steam games: platform, SteamOS rating (opens the full report), favorite, update.
                Flow {
                  width: parent.width
                  visible: root.stFiltered
                  spacing: Style.space(6)

                  Badge {
                    visible: text !== ""
                    text: root.stFiltered ? root.platformBadge(stDetails.game) : ""
                    tint: root.platformColor(stDetails.game)
                  }

                  Badge {
                    text: strings.t("steam.badge.steamos." + (stDetails.game.steamos || "unknown"))
                    tint: root.runColor(stDetails.game.steamos || "unknown")
                    clickable: true
                    trailing: ""
                    tooltip: strings.t("steam.deck.open")
                    hasCursor: root.cursorOn("st-deck")
                    onClicked: root.openDeck()
                    onHovered: function(h) { if (h) root.point("st-deck", 0) }
                  }

                  Badge {
                    visible: !!stDetails.game.favorite
                    text: "  " + strings.t("steam.badge.favorite")
                    tint: root.stYellow
                  }

                  Badge {
                    visible: text !== ""
                    text: root.stFiltered && stDetails.game.update ? "  " + root.updateText(stDetails.game) : ""
                    tint: root.stYellow
                  }
                }

                Column {
                  width: parent.width
                  visible: root.stFiltered
                  spacing: Style.space(8)

                  Fact {
                    width: parent.width
                    label: strings.t("steam.fact.played")
                    value: root.stFiltered ? root.playedValue(stDetails.game) : ""
                  }

                  Fact {
                    width: parent.width
                    visible: !!stDetails.game.installed
                    label: strings.t("steam.fact.size")
                    value: stDetails.game.installed ? root.sizeLine(stDetails.game) : ""
                    sub: stDetails.game.installed ? root.sizeParts(stDetails.game) : ""
                  }

                  Fact {
                    width: parent.width
                    visible: value !== ""
                    label: strings.t("steam.fact.runs")
                    value: root.stFiltered ? root.runsWith(stDetails.game) : ""
                  }

                  Fact {
                    width: parent.width
                    visible: !!stDetails.game.installed && value !== ""
                    label: strings.t("steam.fact.build")
                    value: stDetails.game.build || ""
                    sub: stDetails.game.installed && stDetails.game.updated > 0 ? strings.t("steam.updated").arg(root.whenText(stDetails.game.updated)) : ""
                  }
                }

                // Deals: the price, and whether it's yours or wished for.
                Text {
                  width: parent.width
                  visible: root.stDeals
                  textFormat: Text.PlainText
                  text: root.stDeals ? root.dealPrice(stDetails.game)
                    + (stDetails.game.initial ? "  " + strings.t("steam.deals.was").arg(stDetails.game.initial) : "") : ""
                  color: root.stGreen
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }

                Caption {
                  width: parent.width
                  visible: root.stDeals && (!!stDetails.game.owned || !!stDetails.game.wishlist)
                  text: root.stDeals ? strings.t(stDetails.game.owned ? "steam.deals.ownedLine" : "steam.deals.wishlistLine") : ""
                  wrapMode: Text.WordWrap
                }

                // Other games: the entry's comment and where it lives.
                Caption {
                  width: parent.width
                  visible: root.stLocal && !!stDetails.game.comment
                  text: stDetails.game.comment || ""
                  color: root.fg
                  wrapMode: Text.WordWrap
                }

                Caption {
                  width: parent.width
                  visible: root.stLocal
                  text: stDetails.game.size > 0 ? strings.t("steam.local.sizeIn").arg(root.bytes(stDetails.game.size)).arg(stDetails.game.folder || "")
                    : strings.t("steam.local.fromMenu")
                  wrapMode: Text.WrapAnywhere
                }
              }

              Column {
                id: stActionsCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: root.stDeals || stInfo.height > stCover.height ? stInfo.bottom : stCover.bottom
                anchors.topMargin: Style.space(14)
                spacing: Style.space(8)

                Row {
                  spacing: Style.spacing.sm

                  // By count, so a new reading doesn't rebuild the buttons.
                  Repeater {
                    model: root.stActions.length

                    PillButton {
                      required property int index
                      readonly property string action: root.stActions[index] || ""
                      readonly property bool iconOnly: action === "folder" || action === "options"
                      readonly property color tint: root.actionColor(action)
                      text: iconOnly ? "" : strings.t("steam.action." + action)
                      tooltipText: !iconOnly ? ""
                        : action === "options" && stDetails.game.launchOptions
                          ? strings.t("steam.launchOptions").arg(stDetails.game.launchOptions)
                          : strings.t("steam.action." + action)
                      iconText: ({ run: "", install: "", uninstall: "", folder: "", options: "", store: "" })[action] || ""
                      foreground: tint
                      accent: tint
                      hasCursor: root.cursorOn("st-actions", index)
                      onClicked: root.steamAction(action)
                      onHovered: function(h) { if (h) root.point("st-actions", index) }
                    }
                  }
                }

                Caption {
                  width: parent.width
                  visible: text !== ""
                  text: root.stLocal ? "" : root.stDeals ? (stDetails.game.discount >= 100 && !stDetails.game.owned ? strings.t("steam.deals.claimHint") : "")
                    : strings.t(stDetails.game.installed ? "steam.uninstallHint" : "steam.installHint")
                  wrapMode: Text.WordWrap
                }
              }

              // DLC: a folded header; open, the list fills the rest.
              Item {
                visible: root.stFiltered && !!stDetails.game.dlc && stDetails.game.dlc.length > 0
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: stActionsCol.bottom
                anchors.topMargin: Style.space(12)
                anchors.bottom: parent.bottom

                CursorSurface {
                  id: stDlcHeader
                  width: parent.width
                  implicitHeight: Style.space(30)
                  bordered: true
                  foreground: root.fg
                  hasCursor: root.cursorOn("st-dlc")

                  Caption {
                    id: stDlcChevron
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.stDlcOpen ? "" : ""
                  }

                  Caption {
                    anchors.left: stDlcChevron.right
                    anchors.leftMargin: Style.space(8)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.stFiltered && stDetails.game.dlc ? root.dlcHeader(stDetails.game) : ""
                    color: root.fg
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.stDlcOpen = !root.stDlcOpen
                  }

                  HoverHandler {
                    onHoveredChanged: if (hovered) root.point("st-dlc", 0)
                  }
                }

                ListView {
                  id: stDlcList
                  visible: root.stDlcOpen
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: stDlcHeader.bottom
                  anchors.topMargin: Style.space(8)
                  anchors.bottom: parent.bottom
                  clip: true
                  spacing: Style.space(4)
                  boundsBehavior: Flickable.StopAtBounds
                  model: root.stDlcOpen && root.stFiltered && stDetails.game.dlc ? stDetails.game.dlc.length : 0
                  ScrollBar.vertical: ScrollBar { policy: stDlcList.contentHeight > stDlcList.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

                  delegate: Item {
                    required property int index
                    readonly property var dlc: stDetails.game.dlc[index] || ({ name: "", state: "missing" })
                    width: stDlcList.width - Style.space(8)
                    height: dlcName.implicitHeight

                    Caption {
                      id: dlcName
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(10)
                      anchors.right: dlcState.left
                      anchors.rightMargin: Style.space(8)
                      text: parent.dlc.name
                      color: parent.dlc.state === "missing" ? root.dimFg : root.fg
                      elide: Text.ElideRight
                    }

                    Caption {
                      id: dlcState
                      anchors.right: parent.right
                      text: strings.t("steam.dlc." + parent.dlc.state)
                      color: root.dlcColor(parent.dlc.state)
                    }
                  }
                }
              }
            }

            // A click outside the filters card closes it.
            MouseArea {
              visible: root.stFilterOpen
              z: 19
              anchors.fill: parent
              onClicked: root.openFilters(false)
            }

            // The filters card: what it runs on, played or not, favorites and
            // updates. Every choice applies at once and shows its count.
            Rectangle {
              id: stFilterCard
              visible: steamPage.ready && root.stFilterOpen
              z: 20
              anchors.left: parent.left
              anchors.top: stSearch.bottom
              anchors.topMargin: Style.space(6)
              width: Math.max(stList.width, Style.space(340))
              height: stCardBody.implicitHeight + Style.space(28)
              color: Commons.Color.popups.background
              border.color: Util.alpha(root.fg, 0.3)
              border.width: Math.max(1, Style.space(1))
              radius: Style.cornerRadius

              MouseArea { anchors.fill: parent }

              Column {
                id: stCardBody
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: Style.space(14)
                spacing: Style.space(14)

                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  CardLabel { text: strings.t("steam.filter.runsTitle"); hint: strings.t("steam.filter.runsHint") }

                  Flow {
                    width: parent.width
                    spacing: Style.space(6)

                    Repeater {
                      model: Library.RUNS.length

                      PillButton {
                        required property int index
                        readonly property string run: Library.RUNS[index]
                        readonly property bool on: root.stFilterRuns.indexOf(run) >= 0
                        text: root.facetText(root.runLabel(run), root.stFacets ? root.stFacets.runs[run] : 0)
                        iconText: on ? "\uf14a" : "\uf096"
                        selected: on
                        foreground: root.runColor(run)
                        accent: root.runColor(run)
                        hasCursor: root.cursorOn("st-fc-runs", index)
                        onClicked: root.toggleRun(run)
                        onHovered: function(h) { if (h) root.point("st-fc-runs", index) }
                      }
                    }
                  }
                }

                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  CardLabel { text: strings.t("steam.filter.playedTitle") }

                  Row {
                    spacing: Style.space(6)

                    Repeater {
                      model: Library.PLAYED.length

                      PillButton {
                        required property int index
                        readonly property string value: Library.PLAYED[index]
                        text: root.facetText(strings.t("steam.filter.played." + value), root.stFacets ? root.stFacets.played[value] : 0)
                        selected: root.stFilterPlayed === value
                        foreground: root.stFilterPlayed === value ? Commons.Color.accent : root.fg
                        accent: Commons.Color.accent
                        hasCursor: root.cursorOn("st-fc-played", index)
                        onClicked: root.setPlayed(value)
                        onHovered: function(h) { if (h) root.point("st-fc-played", index) }
                      }
                    }
                  }
                }

                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  CardLabel { text: strings.t("steam.filter.showTitle") }

                  Row {
                    spacing: Style.space(6)

                    PillButton {
                      text: root.facetText(strings.t("steam.filter.favorites"), root.stFacets ? root.stFacets.favorites : 0)
                      iconText: root.stFilterFav ? "\uf005" : "\uf006"
                      selected: root.stFilterFav
                      foreground: root.stFilterFav ? root.stYellow : root.fg
                      accent: root.stYellow
                      hasCursor: root.cursorOn("st-fc-show", 0)
                      onClicked: root.toggleFav()
                      onHovered: function(h) { if (h) root.point("st-fc-show", 0) }
                    }

                    PillButton {
                      visible: root.stInstalled
                      text: root.facetText(strings.t("steam.filter.updates"), root.stFacets ? root.stFacets.updates : 0)
                      iconText: "\uf021"
                      selected: root.stFilterUpdates
                      foreground: root.stFilterUpdates ? root.stYellow : root.fg
                      accent: root.stYellow
                      hasCursor: root.cursorOn("st-fc-show", 1)
                      onClicked: root.toggleUpdates()
                      onHovered: function(h) { if (h) root.point("st-fc-show", 1) }
                    }
                  }
                }

                Rectangle { width: parent.width; height: Math.max(1, Style.space(1)); color: Util.alpha(root.fg, 0.12) }

                // How many games show, then Clear and Done.
                Item {
                  width: parent.width
                  height: stCardDone.implicitHeight

                  Caption {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: strings.tn("steam.filter.shown", root.stGames.length).arg(Commons.I18n.formatNumber(root.stGames.length))
                  }

                  Row {
                    anchors.right: parent.right
                    spacing: Style.space(6)

                    Button {
                      text: strings.t("steam.filter.clear")
                      enabled: root.stActiveFilters > 0
                      foreground: root.stActiveFilters > 0 ? root.fg : root.dimFg
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      hasCursor: root.cursorOn("st-fc-foot", 0)
                      onClicked: root.clearFilters()
                      onHovered: function(h) { if (h) root.point("st-fc-foot", 0) }
                    }

                    PillButton {
                      id: stCardDone
                      text: strings.t("steam.filter.done")
                      foreground: Commons.Color.accent
                      accent: Commons.Color.accent
                      hasCursor: root.cursorOn("st-fc-foot", 1)
                      onClicked: root.openFilters(false)
                      onHovered: function(h) { if (h) root.point("st-fc-foot", 1) }
                    }
                  }
                }
              }
            }

            // The full Steam Deck report, over the details.
            Rectangle {
              id: stDeckCard
              visible: steamPage.ready && root.stDeckOpen
              z: 10
              anchors.fill: stDetails
              anchors.leftMargin: -Style.space(8)
              color: Commons.Color.popups.background
              border.color: Util.alpha(root.fg, 0.25)
              border.width: Math.max(1, Style.space(1))
              radius: Style.cornerRadius
              readonly property var report: root.steamModel ? root.steamModel.deckReport : null
              readonly property bool ready: !!report && !!root.stGame && report.id === root.stGame.id

              // Clicks stay on the card.
              MouseArea { anchors.fill: parent }

              Text {
                id: stDeckTitle
                anchors.left: parent.left
                anchors.leftMargin: Style.space(14)
                anchors.right: stDeckClose.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: stDeckClose.verticalCenter
                textFormat: Text.PlainText
                text: strings.t("steam.deck.title").arg(root.stGame ? root.stGame.name : "")
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }

              Button {
                id: stDeckClose
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.top: parent.top
                anchors.topMargin: Style.space(8)
                iconText: ""
                tooltipText: strings.t("steam.deck.close")
                foreground: root.fg
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.stDeckOpen = false
              }

              Caption {
                visible: !stDeckCard.ready || stDeckCard.report.none
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: stDeckClose.bottom
                anchors.margins: Style.space(14)
                text: !stDeckCard.ready ? strings.t(root.steamModel && root.steamModel.deckPhase === "failed" ? "steam.deck.failed" : "steam.deck.reading")
                  : strings.t("steam.deck.none")
                wrapMode: Text.WordWrap
              }

              Flickable {
                id: stDeckFlick
                visible: stDeckCard.ready && !stDeckCard.report.none
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: stDeckClose.bottom
                anchors.topMargin: Style.space(8)
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(10)
                anchors.leftMargin: Style.space(14)
                anchors.rightMargin: Style.space(10)
                clip: true
                contentHeight: stDeckBody.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: stDeckFlick.contentHeight > stDeckFlick.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

                Column {
                  id: stDeckBody
                  width: stDeckFlick.width - Style.space(10)
                  spacing: Style.space(14)
                  readonly property var report: stDeckCard.ready && !stDeckCard.report.none ? stDeckCard.report : null

                  Caption {
                    width: parent.width
                    visible: text !== ""
                    text: stDeckBody.report ? root.deckTestedLine(stDeckBody.report) : ""
                    wrapMode: Text.WordWrap
                  }

                  Repeater {
                    model: stDeckBody.report ? ["steamos", "deck", "machine"] : []

                    Column {
                      required property var modelData
                      readonly property var results: stDeckBody.report.results[modelData] || []
                      width: stDeckBody.width
                      spacing: Style.space(5)

                      Caption {
                        width: parent.width
                        text: root.deckSectionTitle(modelData, stDeckBody.report)
                        color: root.deckSectionColor(modelData, stDeckBody.report)
                        font.bold: true
                      }

                      Repeater {
                        model: parent.results.length

                        Item {
                          required property int index
                          readonly property var test: parent.results[index] || ({ result: "", kind: "note" })
                          width: stDeckBody.width
                          height: Math.max(testIcon.implicitHeight, testText.implicitHeight)

                          Caption {
                            id: testIcon
                            width: Style.space(18)
                            text: ({ pass: "", warning: "", fail: "", note: "" })[parent.test.kind] || ""
                            color: root.deckKindColor(parent.test.kind)
                          }

                          Caption {
                            id: testText
                            anchors.left: testIcon.right
                            anchors.right: parent.right
                            text: strings.t("deck.result." + parent.test.result, Library.humanize(parent.test.result))
                            color: root.fg
                            wrapMode: Text.WordWrap
                          }
                        }
                      }
                    }
                  }

                  Column {
                    width: parent.width
                    visible: !!stDeckBody.report && stDeckBody.report.config.length > 0
                    spacing: Style.space(5)

                    Caption {
                      text: strings.t("steam.deck.config")
                      color: root.fg
                      font.bold: true
                    }

                    Repeater {
                      model: stDeckBody.report ? stDeckBody.report.config.length : 0

                      Fact {
                        required property int index
                        readonly property var flag: stDeckBody.report.config[index] || ({ key: "", value: "" })
                        width: stDeckBody.width
                        labelWidth: Math.round(stDeckBody.width * 0.62)
                        label: strings.t("deck.flag." + flag.key, Library.humanize(flag.key))
                        value: root.deckFlagValue(flag.key, flag.value)
                      }
                    }
                  }
                }
              }
            }

            // Every disk with a Steam library, side by side.
            Column {
              id: stDriveBox
              visible: steamPage.ready
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.space(8)

              PanelSeparator { foreground: root.fg }

              // Whether Steam is running, and the account on it.
              Row {
                id: stStatusRow
                visible: !!root.steamModel && !!root.steamModel.status
                spacing: Style.space(6)
                readonly property bool running: !!root.steamModel && !!root.steamModel.status && root.steamModel.status.running

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(8)
                  height: width
                  radius: width / 2
                  color: stStatusRow.running ? root.stGreen : root.stYellow
                }

                Caption {
                  text: !stStatusRow.visible ? ""
                    : stStatusRow.running && root.steamModel.status.persona ? strings.t("steam.status.runningAs").arg(root.steamModel.status.persona)
                    : strings.t(stStatusRow.running ? "steam.status.running" : "steam.status.stopped")
                }
              }

              Row {
                id: stDriveRow
                width: parent.width
                spacing: Style.space(16)

                Repeater {
                  model: root.stDrives.length

                  delegate: DriveCell {
                    required property int index
                    drive: root.stDrives[index] || null
                    width: (stDriveRow.width - stDriveRow.spacing * (root.stDrives.length - 1)) / Math.max(1, root.stDrives.length)
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  // ------------------------------------------------------------ pieces

  // A section header that folds its section: click or Enter flips it. Folded,
  // it shows a one-line summary of the current values.
  component FoldTitle: CursorSurface {
    id: fold
    property string rowId: ""
    property string text: ""
    property string summary: ""
    property string hint: ""
    property bool open: false
    width: parent ? parent.width : 0
    implicitHeight: Math.max(foldHeader.implicitHeight, foldChevron.implicitHeight) + Style.spacing.xs * 2
    hasCursor: root.cursorOn(rowId)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(fold)
    foreground: root.fg

    PanelSectionHeader {
      id: foldHeader
      text: fold.text
      foreground: root.fg
      fontFamily: root.fontFamily
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Caption {
      visible: text !== ""
      text: fold.open ? fold.hint : fold.summary
      elide: Text.ElideRight
      horizontalAlignment: Text.AlignRight
      anchors.left: foldHeader.right
      anchors.leftMargin: Style.space(10)
      anchors.right: foldChevron.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Caption {
      id: foldChevron
      text: fold.open ? "\uf077" : "\uf078"
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleFold(fold.rowId)
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.point(fold.rowId, 0)
    }
  }

  // One Game mode item: its switch ticks it, or pauses it while game mode is on.
  component GmRow: SmallToggle {
    id: gmRow
    property int itemIndex: -1
    readonly property var item: root.gmItems[itemIndex] || ({ key: "", kind: "app", label: "", detail: "", selected: false, paused: false })
    readonly property string rowId: "gm-item-" + itemIndex
    tinted: true
    width: parent ? parent.width : 0
    label: item.label
    description: root.gmRowDescription(item)
    checked: root.gm ? (root.gameOn ? root.gm.paused(item) : root.gm.ticked(item)) : false
    hasCursor: root.cursorOn(rowId)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(gmRow)
    foreground: root.fg
    onClicked: if (root.gm) root.gm.clickItem(item)
    onHovered: function(h) { if (h) root.point(rowId, 0) }
  }

  // A Game mode folder's title, drawn like the other rows: the box folds it
  // (target 0), the switch ticks or pauses everything inside (target 1).
  component GroupTitle: CursorSurface {
    id: groupTitle
    property string rowId: ""
    property string text: ""
    property string summary: ""
    property bool open: true
    property bool checked: false
    width: parent ? parent.width : 0
    bordered: true
    hasCursor: root.cursorOn(rowId, 0)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(groupTitle)
    foreground: root.fg
    implicitHeight: Math.max(groupSwitch.implicitHeight, groupText.implicitHeight) + Style.spacing.sm * 2

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleGmFold(groupTitle.rowId.slice(9))
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.point(groupTitle.rowId, 0)
    }

    Caption {
      id: groupChevron
      text: groupTitle.open ? "\uf078" : "\uf054"
      width: Style.space(14)
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm + Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
    }

    Column {
      id: groupText
      anchors.left: groupChevron.right
      anchors.leftMargin: Style.space(4)
      anchors.right: groupSwitch.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: groupTitle.text
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Caption {
        visible: groupTitle.summary !== ""
        text: groupTitle.summary
        wrapMode: Text.WordWrap
        width: parent.width
      }
    }

    TintSwitch {
      id: groupSwitch
      checked: groupTitle.checked
      hasCursor: root.cursorOn(groupTitle.rowId, 1)
      trackHeight: Style.space(16)
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.sm + Style.space(2) - (cursorRing ? cursorPad : 0)
      anchors.verticalCenter: parent.verticalCenter
      onToggled: root.toggleGmGroup(groupTitle.rowId.slice(9))
      onHovered: function(h) { if (h) root.point(groupTitle.rowId, 1) }
    }
  }


  // A Steam library's disk: its name and free space, and a bar of how full it is.
  component DriveCell: Column {
    id: driveCell
    property var drive: null
    spacing: Style.space(4)

    Caption {
      width: parent.width
      text: driveCell.drive ? strings.t("steam.drive").arg(driveCell.drive.label)
        .arg(root.bytes(driveCell.drive.free)).arg(root.bytes(driveCell.drive.total)) : ""
      elide: Text.ElideRight
    }

    Rectangle {
      width: parent.width
      height: Style.space(4)
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, 0.14)

      Rectangle {
        width: parent.width * Library.usedShare(driveCell.drive)
        height: parent.height
        radius: parent.radius
        color: Util.alpha(root.fg, 0.7)
      }
    }
  }

  // A game's cover from Steam's own cache, or a gamepad when Steam has none.
  // Small text in the panel's font, dim unless it says otherwise.
  component Caption: Text {
    textFormat: Text.PlainText
    color: root.dimFg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // A bordered button in the panel's font at caption size.
  component PillButton: Button {
    bordered: true
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
  }

  // A small tinted pill in the details: platform, Deck, favorite, update.
  // A clickable one gets a trailing chevron and the panel cursor.
  component Badge: Rectangle {
    id: badge
    property string text: ""
    property color tint: root.fg
    property bool clickable: false
    property string trailing: ""
    property string tooltip: ""
    property bool hasCursor: false
    signal clicked()
    signal hovered(bool h)
    readonly property bool hot: hasCursor || badgeHover.hovered
    implicitWidth: badgeRow.implicitWidth + Style.space(20)
    implicitHeight: badgeRow.implicitHeight + Style.space(8)
    radius: height / 2
    color: Util.alpha(tint, hot && clickable ? 0.28 : 0.14)
    border.color: Util.alpha(tint, hot && clickable ? 0.9 : 0.45)
    border.width: Math.max(1, Style.space(1))

    Row {
      id: badgeRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Caption {
        text: badge.text
        color: badge.tint
        font.bold: true
      }

      Text {
        visible: badge.trailing !== ""
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: badge.trailing
        color: badge.tint
        font.family: root.fontFamily
        font.pixelSize: Math.round(Style.font.caption * 0.8)
      }
    }

    HoverHandler {
      id: badgeHover
      enabled: badge.clickable
      cursorShape: Qt.PointingHandCursor
      onHoveredChanged: badge.hovered(hovered)
    }

    TapHandler {
      enabled: badge.clickable
      onTapped: badge.clicked()
    }

    PanelToolTip {
      visible: badge.tooltip !== "" && badgeHover.hovered
      text: badge.tooltip
    }
  }

  // A section title in the filters card, with an optional dim hint after it.
  component CardLabel: Text {
    property string hint: ""
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    text: ""
    color: root.fg
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: true
    wrapMode: Text.WordWrap

    Text {
      visible: parent.hint !== ""
      anchors.left: parent.left
      anchors.leftMargin: parent.contentWidth + Style.space(8)
      anchors.right: parent.right
      anchors.baseline: parent.baseline
      textFormat: Text.PlainText
      text: parent.hint
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Math.round(Style.font.caption * 0.9)
      elide: Text.ElideRight
    }
  }

  // One label / value fact, with an optional smaller line under the value.
  component Fact: Item {
    id: fact
    property string label: ""
    property string value: ""
    property string sub: ""
    property int labelWidth: Style.space(78)
    implicitHeight: Math.max(factLabel.implicitHeight, factValue.implicitHeight + (factSub.visible ? factSub.implicitHeight + Style.space(2) : 0))

    Caption {
      id: factLabel
      width: fact.labelWidth - Style.space(8)
      text: fact.label
      wrapMode: Text.WordWrap
    }

    Caption {
      id: factValue
      anchors.left: parent.left
      anchors.leftMargin: fact.labelWidth
      anchors.right: parent.right
      text: fact.value
      color: root.fg
      wrapMode: Text.WordWrap
    }

    Text {
      id: factSub
      visible: fact.sub !== ""
      anchors.left: factValue.left
      anchors.right: parent.right
      anchors.top: factValue.bottom
      anchors.topMargin: Style.space(2)
      textFormat: Text.PlainText
      text: fact.sub
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Math.round(Style.font.caption * 0.9)
      wrapMode: Text.WordWrap
    }
  }

  component Cover: Rectangle {
    id: coverBox
    property string path: ""
    property bool small: false
    // An app-menu icon instead of a Steam cover: fitted, with some room around it.
    property bool iconMode: false
    property string icon: ""
    color: Util.alpha(root.fg, 0.08)
    radius: Style.cornerRadius
    clip: true

    Text {
      anchors.centerIn: parent
      visible: coverImage.status !== Image.Ready
      textFormat: Text.PlainText
      text: ""
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: coverBox.small ? Style.font.caption : Style.font.display
    }

    Image {
      id: coverImage
      anchors.fill: parent
      anchors.margins: coverBox.iconMode ? Math.round(coverBox.width * 0.14) : 0
      visible: status === Image.Ready
      source: coverBox.iconMode ? root.iconUrl(coverBox.icon) : Library.coverUrl(coverBox.path)
      asynchronous: true
      fillMode: coverBox.iconMode ? Image.PreserveAspectFit : Image.PreserveAspectCrop
      sourceSize: coverBox.iconMode ? Qt.size(128, 128) : coverBox.small ? Qt.size(64, 96) : Qt.size(320, 480)
      smooth: true
    }
  }

  // One game in the Steam list: cover, name, last played and size. The
  // picked one is filled; click picks it.
  component GameRow: CursorSurface {
    id: gameRow
    property int listIndex: -1
    readonly property var game: root.stGames[listIndex] || ({ id: "", name: "", installed: false, size: 0, lastPlayed: 0, cover: "" })
    readonly property string rowId: "st-game-" + listIndex
    current: !!root.stGame && root.stGame.id === game.id
    hasCursor: root.cursorOn(rowId)
    onHasCursorChanged: if (hasCursor && !root.cursorByMouse && ListView.view) ListView.view.positionViewAtIndex(listIndex, ListView.Contain)
    foreground: root.fg
    implicitHeight: Style.space(54)

    Cover {
      id: rowCover
      visible: !root.stDeals
      small: true
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      height: parent.height - Style.space(10)
      width: root.stDeals ? 0 : root.stLocal ? height : Math.round(height / 1.5)
      iconMode: root.stLocal
      icon: root.stLocal ? gameRow.game.icon || "" : ""
      path: root.stLocal ? "" : gameRow.game.cover || ""
    }

    Column {
      anchors.left: rowCover.right
      anchors.leftMargin: root.stDeals ? Style.space(4) : Style.space(10)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Item {
        width: parent.width
        height: rowName.implicitHeight

        Text {
          id: rowName
          anchors.left: parent.left
          anchors.right: rowBadge.visible ? rowBadge.left : parent.right
          anchors.rightMargin: rowBadge.visible ? Style.space(6) : 0
          textFormat: Text.PlainText
          text: gameRow.game.name
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          elide: Text.ElideRight
        }

        // A favorite's star and a waiting update.
        Caption {
          id: rowBadge
          anchors.right: parent.right
          anchors.verticalCenter: rowName.verticalCenter
          visible: root.stFiltered && text !== ""
          text: !root.stFiltered ? "" : (gameRow.game.update ? "\uf021" + (gameRow.game.update === "downloading" ? " " + Commons.I18n.formatNumber(gameRow.game.progress) + "%" : "") : "")
            + (gameRow.game.favorite ? (gameRow.game.update ? "  " : "") + "\uf005" : "")
          color: gameRow.game.update ? root.stYellow : root.dimFg
        }
      }

      Caption {
        width: parent.width
        visible: text !== ""
        text: root.stDeals ? root.dealCaption(gameRow.game) : root.stLocal ? root.localCaption(gameRow.game) : root.rowCaption(gameRow.game)
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.selectGame(gameRow.listIndex)
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.point(gameRow.rowId, 0)
    }
  }

  // The kit's switch, green when on and red when off. Themes can pin the
  // "on" color in shell.toml, so the track and knob are painted over it.
  component TintSwitch: ToggleSwitch {
    id: tintSwitch
    property bool tinted: true
    readonly property color tint: root.switchTint(checked)
    foreground: tinted ? tint : root.fg

    Rectangle {
      visible: tintSwitch.tinted && tintSwitch.checked
      x: tintSwitch._pad + (tintSwitch.width - tintSwitch._pad * 2 - tintSwitch.trackWidth) / 2
      anchors.verticalCenter: parent.verticalCenter
      width: tintSwitch.trackWidth
      height: tintSwitch.trackHeight
      radius: tintSwitch.rounded ? height / 2 : 0
      color: Util.alpha(tintSwitch.tint, 0.25)

      Rectangle {
        width: tintSwitch.knobSize
        height: tintSwitch.knobSize
        radius: tintSwitch.rounded ? height / 2 : 0
        x: parent.width - width - tintSwitch.knobInset
        anchors.verticalCenter: parent.verticalCenter
        color: tintSwitch.tint
      }
    }
  }

  // A tighter version of the kit's Toggle row: smaller title, smaller switch.
  component SmallToggle: CursorSurface {
    id: small
    property string label: ""
    property string description: ""
    property bool checked: false
    // Green when on, red when off (Game mode's rows).
    property bool tinted: false
    property string fontFamily: root.fontFamily
    signal clicked()
    signal hovered(bool isHovered)

    bordered: true
    implicitHeight: Math.max(smallSwitch.implicitHeight, smallText.implicitHeight) + Style.spacing.sm * 2

    Column {
      id: smallText
      anchors.left: parent.left
      anchors.leftMargin: Style.spacing.sm + Style.space(2)
      anchors.right: smallSwitch.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: small.label
        color: small.foreground
        font.family: small.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
        width: parent.width
      }

      Text {
        textFormat: Text.PlainText
        visible: small.description !== ""
        text: small.description
        color: root.dimFg
        font.family: small.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        width: parent.width
      }
    }

    TintSwitch {
      id: smallSwitch
      checked: small.checked
      interactive: false
      cursorRing: false
      trackHeight: Style.space(16)
      tinted: small.tinted
      foreground: tinted ? tint : small.foreground
      anchors.right: parent.right
      anchors.rightMargin: Style.spacing.sm + Style.space(2)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: small.clicked()
    }

    HoverHandler {
      onHoveredChanged: small.hovered(hovered)
    }
  }

  // A caption on the left, controls after it.
  component LabeledRow: Item {
    id: labeled
    property string label: ""
    default property alias content: holder.data
    implicitHeight: Math.max(labeledText.implicitHeight, holder.childrenRect.height)

    Caption {
      id: labeledText
      text: labeled.label
      font.bold: true
      width: root.labelWidth - Style.space(6)
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Item {
      id: holder
      anchors.left: labeledText.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      height: childrenRect.height
    }
  }

  component SliderRow: CursorSurface {
    id: sliderRow
    property string rowId: ""
    property string label: ""
    property real value: 0
    property real minimum: 0
    property real maximum: 1
    signal commit(real value)

    implicitHeight: Math.max(sliderLabel.implicitHeight, slider.implicitHeight) + Style.spacing.controlGap
    hasCursor: root.cursorOn(rowId)
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sliderRow)
    foreground: root.fg
    outline: true

    Caption {
      id: sliderLabel
      text: sliderRow.label
      font.bold: true
      width: root.labelWidth - Style.space(6)
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    PanelSlider {
      id: slider
      bar: root.bar
      anchors.left: sliderLabel.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: sliderValue.left
      anchors.rightMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      minimum: sliderRow.minimum
      maximum: sliderRow.maximum
      step: 0.05
      value: sliderRow.value
      onMoved: function(v) { sliderRow.commit(v) }
      onReleased: function(v) { sliderRow.commit(v) }
    }

    Text {
      id: sliderValue
      textFormat: Text.PlainText
      text: Commons.I18n.formatNumber(Math.round((slider.dragging ? slider.liveValue : sliderRow.value) * 100)) + "%"
      color: root.dimFg
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      width: Math.max(implicitWidth, Math.ceil(widest.advanceWidth))
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter

      TextMetrics {
        id: widest
        font: sliderValue.font
        text: Commons.I18n.formatNumber(160) + "%"
      }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.point(sliderRow.rowId, 0)
    }
  }

  component MetricGroupRow: Item {
    id: groupRow
    property var group: null
    readonly property string rowId: group ? "metrics-" + group.id : ""
    implicitHeight: Math.max(groupLabel.implicitHeight, chips.implicitHeight)

    Caption {
      id: groupLabel
      text: groupRow.group ? strings.t("group." + groupRow.group.id) : ""
      font.bold: true
      width: root.labelWidth - Style.space(6)
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    Row {
      id: chips
      anchors.left: groupLabel.right
      anchors.leftMargin: Style.spacing.sm
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      Repeater {
        model: groupRow.group ? groupRow.group.metrics : []

        PillButton {
          id: chip
          required property string modelData
          required property int index
          text: strings.t("metric." + modelData)
          selected: root.config.metrics.indexOf(modelData) !== -1
          foreground: root.fg
          horizontalPadding: Style.spacing.sm
          hasCursor: root.cursorOn(groupRow.rowId, index)
          onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(chip)
          onClicked: if (root.service) root.service.toggleMetric(modelData)
          onHovered: function(h) { if (h) root.point(groupRow.rowId, chip.index) }
        }
      }
    }
  }

  // A small screen: click a spot to move the HUD there. The live HUD sits
  // in its current spot; the spot under the cursor shows a ghost outline.
  component ScreenPicker: Item {
    id: picker
    implicitHeight: Math.round(width / root.screenRatio)
    readonly property int inset: Style.space(8)
    readonly property bool hasPreview: preview.hasRows
    readonly property real cardWidth: hasPreview ? preview.width : Style.space(92)
    readonly property real cardHeight: hasPreview ? preview.height : Style.space(54)
    // From the mouse, the ghost shows only while the pointer is on the picker.
    readonly property string hotPosition: root.cursorActive && (!root.cursorByMouse || pickerHover.hovered)
      && (root.cursorRow === "pos-top" || root.cursorRow === "pos-bottom")
      ? root.positionAt(root.cursorRow, root.cursorCol) : ""

    onHotPositionChanged: if (hotPosition !== "") root.ensureCursorVisible(picker)

    HoverHandler { id: pickerHover }

    function slotX(position, w) {
      var a = Metrics.anchors(position)
      if (a.left) return inset
      if (a.right) return width - w - inset
      return Math.round((width - w) / 2)
    }

    function slotY(position, h) {
      return Metrics.anchors(position).top ? inset : height - h - inset
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, 0.05)
      border.width: 1
      border.color: Util.alpha(root.fg, 0.22)
    }

    // Placeholder for the HUD until the first sample arrives.
    Rectangle {
      visible: !picker.hasPreview
      width: picker.cardWidth
      height: picker.cardHeight
      x: picker.slotX(root.config.position, width)
      y: picker.slotY(root.config.position, height)
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, 0.12)
    }

    HudCard {
      id: preview
      visible: hasRows
      width: implicitWidth
      height: implicitHeight
      rows: root.service ? root.service.hudRows : []
      layout: root.config.layout
      scaleFactor: root.config.scale * 0.62
      backdrop: root.config.opacity
      x: picker.slotX(root.config.position, width)
      y: picker.slotY(root.config.position, height)
      Behavior on x { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
      Behavior on y { NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic } }
    }

    Rectangle {
      visible: picker.hotPosition !== "" && picker.hotPosition !== root.config.position
      width: picker.cardWidth
      height: picker.cardHeight
      x: picker.slotX(picker.hotPosition, width)
      y: picker.slotY(picker.hotPosition, height)
      radius: Style.cornerRadius
      color: Util.alpha(root.fg, 0.06)
      border.width: 1
      border.color: Util.alpha(root.fg, 0.6)
    }

    Grid {
      anchors.fill: parent
      columns: 3

      Repeater {
        model: 6

        MouseArea {
          required property int index
          readonly property string rowId: index < 3 ? "pos-top" : "pos-bottom"
          width: picker.width / 3
          height: picker.height / 2
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onContainsMouseChanged: if (containsMouse) root.point(rowId, index % 3)
          onClicked: root.setValue("position", root.positionAt(rowId, index % 3))
        }
      }
    }
  }
}
