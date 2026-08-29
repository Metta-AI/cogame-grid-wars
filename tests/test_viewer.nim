## Chrome invariants. The viewer is the inherited cogame-bullwhip chrome
## plus an appended block, and these are the checks that keep it that way:
## the CSS above the marker is the starter's bytes, every element the
## starter ships is still on both pages, nothing in the appended JS can
## shadow a chrome name, every beat kind the renderer emits has a rule, and
## the zoom panel a fixed arena does not need is nowhere.

import std/[os, strutils, tables, unittest]

const RepoDir = currentSourcePath().parentDir().parentDir()

proc readRepo(path: string): string =
  readFile(RepoDir / path)

proc fnv1a64(data: string): string =
  var hash = 0xcbf29ce484222325'u64
  for c in data:
    hash = hash xor uint64(uint8(c))
    hash = hash * 0x100000001b3'u64
  toHex(hash, 16).toLowerAscii()

const
  ## cogame-bullwhip's client/chrome.css, as mounted at the fork: 11964
  ## bytes. Everything before the Grid Wars marker must still be those
  ## exact bytes — the file's convention is to accrete ONE appended block
  ## per game, never to edit a rule above.
  StarterChromeBytes = 11964
  StarterChromeDigest = "04fb4d04d7f54118"
  GridWarsMarker = "/* ---------- Grid Wars ---------- */"

  ## Every element the starter's replay page ships. None was removed.
  StarterIds = [
    "layout", "stage", "topband", "wordmark", "clock", "topright",
    "statuschip", "feedtoggle", "scorebug", "board-wrap", "table",
    "lightpool", "grain", "endscreen", "transport", "scrub", "play", "pos",
    "feed", "loading"
  ]
  ## The two elements the design note adds, and only those two.
  AddedIds = ["terrbar", "codepane"]

  BeatKinds = ["submit", "kill", "fault", "idle", "roundend", "end"]

suite "chrome.css":
  test "the bytes above the Grid Wars marker are the starter's, unchanged":
    let css = readRepo("client/chrome.css")
    let marker = css.find(GridWarsMarker)
    check marker > 0
    ## The marker is preceded by exactly one newline that the appended
    ## block contributes; the starter's file ends at StarterChromeBytes.
    let prefix = css[0 ..< marker - 1]
    check prefix.len == StarterChromeBytes
    check fnv1a64(prefix) == StarterChromeDigest

  test "the starter's own rules are all still there":
    let css = readRepo("client/chrome.css")
    for rule in ["#layout", "#stage", "#topband", "#scorebug", ".plate",
        ".plate-name", ".plate-score", ".plate-label", "#transport",
        ".scrub", ".scrub-track", ".scrub-fill", ".scrub-head",
        ".beat-marker", ".round-span", ".round-sep", "#feed", "#loading",
        "#endscreen", ".end-panel", "#board-wrap", "#lightpool", "#grain"]:
      check rule in css

  test "the scorebug stays legible at 360px":
    let css = readRepo("client/chrome.css")
    ## The name is the one thing a plate must never lose.
    let plateName = css[css.find(".plate-name {") .. ^1]
    let rule = plateName[0 ..< plateName.find("}")]
    check "min-width: 3.2em" in rule
    check "flex: 1 1 auto" in rule
    ## Labels go before the name does, and the bug goes two-up at 420px.
    check "@media (max-width: 560px)" in css
    check "@media (max-width: 420px)" in css
    check "@media (max-width: 720px)" in css
    let small = css[css.find("@media (max-width: 560px)") .. ^1]
    check ".plate-label" in small[0 ..< small.find("}")+2]

  test "every beat kind the renderer emits has a rule":
    let css = readRepo("client/chrome.css")
    for kind in BeatKinds:
      check (".beat-marker." & kind) in css
    ## And the buttons are styled AS buttons, since that is what they are.
    check "button.beat-marker" in css
    check "cursor: pointer" in css

  test "a seat-attributed beat is coloured by its seat":
    ## markGridWarsBeat puts `seatN` on every beat that names a seat, but
    ## `.seatN` is one class and `.beat-marker.submit` is two, so the kind
    ## rule won every time and the marker never took the seat's colour.
    ## The submit and round-end beats now match on both classes.
    let css = readRepo("client/chrome.css")
    for seat in 0 .. 3:
      check (".beat-marker.submit.seat" & $seat) in css
      check (".beat-marker.roundend.seat" & $seat) in css
    let js = readRepo("client/renderer.js")
    check "\" seat\" + (seat % COLORS.length)" in js

  test "the speed chips are styled in the appended block":
    ## The bytes above the marker are pinned, so the chip rules have to
    ## live below it — and they have to say which chip is selected.
    let css = readRepo("client/chrome.css")
    let appended = css[css.find(GridWarsMarker) .. ^1]
    check ".tspeed" in appended
    check ".tchip {" in appended
    check ".tchip.on" in appended
    check ".tchip:hover" in appended

  test "the transport band is a custom property on :root":
    let css = readRepo("client/chrome.css")
    check "--band: 84px" in css
    check "--hudscale: 1" in css
    check "#loading { bottom: var(--band); }" in css

suite "the pages":
  test "the static replay page keeps every starter element and adds exactly two":
    ## One replay page only: the pod's `/client/replay` page is gone, so
    ## the bundle's index.html is the whole replay surface.
    for page in ["replay-viewer/index.html"]:
      let html = readRepo(page)
      for id in StarterIds:
        check ("id=\"" & id & "\"") in html
      for id in AddedIds:
        check ("id=\"" & id & "\"") in html
      check "GRID<span>WARS</span>" in html
      check "Grid Wars — Replay" in html
      ## relayout() sets --band and --hudscale on the document element and
      ## calls fit(), so the canvas and the properties cannot disagree.
      check "function relayout()" in html
      check "document.documentElement" in html
      check "--band" in html
      check "--hudscale" in html
      check "offsetHeight" in html

  test "there is no /client/replay pod path anywhere":
    ## Recorded episodes are played by the STATIC bundle from S3. A pod
    ## replay page, its route or its websocket would be a second viewer
    ## the platform must never be pointed at.
    check not fileExists(RepoDir / "client" / "replay.html")
    for path in ["src/gridwars.nim", "src/gridwars/server.nim",
        "client/global.html", "client/player.html", "client/renderer.js",
        "coworld_manifest_template.json"]:
      check "/client/replay" notin readRepo(path)
    let server = readRepo("src/gridwars/server.nim")
    check "\"/replay\"" notin server
    check "replay.html" notin server

  test "the live pages carry the same two additions":
    for page in ["client/global.html", "client/player.html"]:
      let html = readRepo(page)
      for id in ["layout", "stage", "topband", "wordmark", "clock",
          "scorebug", "board-wrap", "table", "endscreen", "feed"]:
        check ("id=\"" & id & "\"") in html
      for id in AddedIds:
        check ("id=\"" & id & "\"") in html
      check "GridWarsRenderer" in html
      check "BullwhipRenderer" notin html

  test "the static bundle page loads the module and the shell":
    let html = readRepo("replay-viewer/index.html")
    check "./gridwars_replay.js" in html
    check "./static_replay.js" in html
    check "./renderer.js" in html
    check "./chrome.css" in html
    ## The bundle's asset base lives in the shell, next to the attach call.
    check "\"./assets\"" in readRepo("replay-viewer/static_replay.js")

  test "no page, script or stylesheet mentions a zoom panel":
    ## The arena is fixed — 30x30, always rescaled whole into the canvas —
    ## so the starter's zoom bar and minimap would be dead weight.
    for path in ["client/chrome.css", "client/renderer.js",
        "client/global.html", "client/player.html",
        "replay-viewer/index.html", "replay-viewer/static_replay.js"]:
      check "viewpanel" notin readRepo(path)
      check "minimap" notin readRepo(path)

suite "renderer.js":
  test "the appended block shadows no name the chrome defines":
    let js = readRepo("client/renderer.js")
    let banner = js.find("// GRID WARS additions to the inherited")
    check banner > 0
    let chrome = js[0 ..< banner]
    let added = js[banner .. ^1]

    proc topLevelNames(source: string): seq[string] =
      for line in source.splitLines():
        if line.startsWith("  function "):
          let rest = line["  function ".len .. ^1]
          result.add(rest[0 ..< rest.find('(')])
        elif line.startsWith("  var "):
          let rest = line["  var ".len .. ^1]
          let stop = rest.find(" =")
          if stop > 0:
            result.add(rest[0 ..< stop])

    let chromeNames = topLevelNames(chrome)
    let addedNames = topLevelNames(added)
    check chromeNames.len > 20
    check addedNames.len >= 3
    var seen = initTable[string, int]()
    for name in chromeNames:
      seen[name] = 1
    for name in addedNames:
      ## A hoisted `function markBeat` in the game block would be shadowed
      ## by a chrome `var markBeat = ...` above it, and the scrubber would
      ## silently render unlabelled divs (tandem, 2026-08-23).
      check name notin seen
    ## And the builders are named as the design note pins them.
    check "markGridWarsBeat" in addedNames
    check "buildGridWarsCode" in addedNames
    check "markBeat" notin addedNames
    check "buildScrub" notin addedNames

  test "the scrubber beats are labelled, clickable buttons":
    let js = readRepo("client/renderer.js")
    check "document.createElement(\"button\")" in js
    check "button.type = \"button\"" in js
    check "setAttribute(\"aria-label\"" in js
    check "button.onclick" in js
    ## Every kind the beat builder can emit has a CSS rule (checked above);
    ## here, that it emits only those kinds.
    let section = js[js.find("function computeGridWarsBeats") .. ^1]
    let body = section[0 ..< section.find("\n  function ")]
    var index = 0
    while true:
      let at = body.find("kind: \"", index)
      if at < 0:
        break
      let rest = body[at + "kind: \"".len .. ^1]
      let kind = rest[0 ..< rest.find('"')]
      check kind in BeatKinds
      index = at + 8

  test "Space pauses playback and the transport carries speed chips":
    ## The static bundle is the whole replay surface and binds no keys of
    ## its own, so the shared attachReplay owns Space: one handler, and
    ## every page that calls it gets pause-on-Space for free.
    let js = readRepo("client/renderer.js")
    check "function togglePlay()" in js
    check "options.playButton.onclick = togglePlay" in js
    check "evt.code !== \"Space\"" in js
    check "evt.preventDefault()" in js
    ## Not while the viewer is typing, and not scrolling the page either.
    for tag in ["INPUT", "TEXTAREA", "SELECT"]:
      check ("t.tagName === \"" & tag & "\"") in js
    check "t.isContentEditable" in js
    ## 0.5x/1x/2x chips that divide the per-frame dwell, so half speed is
    ## genuinely half rather than a skipped frame.
    check "[0.5, 1, 2].forEach" in js
    check "\"tspeed\"" in js
    check "\"tchip\"" in js
    check "stepMs / speed" in js
    ## Live views have no playback, so they must not grow a transport.
    let live = readRepo("client/global.html") & readRepo("client/player.html")
    check "attachReplay" notin live

  test "the renderer signals load and the shell waits for it":
    let js = readRepo("client/renderer.js")
    check "setAttribute(\"data-replay-loaded\", \"true\")" in js
    let shell = readRepo("replay-viewer/static_replay.js")
    check "data-replay-error" in shell
    ## chorus 3c11c953: `ready` is posted only after the renderer's first
    ## drawn frame, never on raw rAF timing.
    check "getAttribute(\"data-replay-loaded\")" in shell
    check "renderer never drew a frame" in shell
    check "_gw_load_replay" in shell
    check "GridWarsReplayModule" in shell
    check "_bw_" notin shell

  test "the wasm build flags and the shell share one lineage":
    let config = readRepo("replay-viewer/config.nims")
    check "EXPORT_NAME=GridWarsReplayModule" in config
    check "MODULARIZE=1" in config
    check "ALLOW_MEMORY_GROWTH" in config
    check "ABORTING_MALLOC=1" in config
    check "ENVIRONMENT=web" in config
    check "EXPORTED_RUNTIME_METHODS=HEAPU8" in config
    check "gridwars_replay.js" in config
    for symbol in ["_gw_load_replay", "_gw_payload_ptr", "_gw_payload_len",
        "_gw_error_ptr", "_gw_error_len"]:
      check symbol in config
    check "_bw_" notin config
