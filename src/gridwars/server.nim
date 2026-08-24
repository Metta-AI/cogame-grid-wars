## Grid Wars game server: implements the Coworld game contract.
##
## Endpoints:
##   GET /healthz                    - liveness
##   GET /client/global              - spectator page
##   GET /client/player              - player page (view-only; policies are prompts)
##   GET /client/replay              - replay page (replay mode)
##   GET /client/renderer.js         - shared arena renderer
##   GET /client/chrome.css          - shared chrome
##   GET /client/assets/<name>       - sprites and fonts
##   WS  /player?slot=N&token=T      - player protocol (prompt delivery)
##   WS  /global                     - spectator snapshots
##   WS  /replay                     - replay payload (replay mode)
##
## Every route is registered BEFORE any catch-all asset route, because
## hosted certification probes /healthz, GET /client/player?slot=0&token=T,
## a bad-token player websocket and GET /client/global before the player
## pods start.
##
## Player protocol (gridwars.player.v1), all JSON text frames:
##   game -> player: {"type":"welcome","protocol":"gridwars.player.v1",...}
##                   {"type":"state",...} redacted to this seat
##                   {"type":"final","scores":[...],...}
##   player -> game: {"type":"prompt","prompt":"...","scripted":"painter"}

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  curly,
  mummy,
  mummy/routers,
  llm,
  sim

const
  MaxPromptLen = 4000
  ReplayVersion = 1
  ShutdownGraceSeconds = 20
  RoundReserveSeconds* = 150.0
    ## Checked BEFORE every submission batch. In the pathological case
    ## where player connect ate its whole cap, round 4 or 5 is given up
    ## rather than the entire episode.
  RoundSpacingSeconds* = 8.0
    ## The hosted Bedrock sidecar caps 30 requests/minute per episode. A
    ## batch is four requests, so eight seconds between rounds keeps a
    ## one-batch round under the cap; a round that needed a retry doubles
    ## the floor.
  PlayBudgetFraction* = 0.6
    ## Share of the platform's episode timeout spent playing. The rest
    ## covers container start, player connects, and writing the artifacts.

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    started: bool
    finished: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  replayPayloadGlobal: string

initLock(stateLock)

proc clientDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "client", appDir / ".." / "client", "client"]:
    if dirExists(candidate):
      return candidate
  "client"

proc dataDir(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc policyNamesJson(gs: GameState): JsonNode =
  ## Seats play under anonymous cog aliases; the policy names ride
  ## alongside for the SPECTATOR views only, which render them in place of
  ## the aliases. No prompt ever contains a policy name.
  result = newJArray()
  for player in gs.config.players:
    result.add(%player.name)

proc snapshotJson(gs: GameState): JsonNode =
  var events = newJArray()
  for event in gs.sim.events:
    events.add(event.eventToJson())
  var connected = newJArray()
  for slot in 0 ..< gs.config.tokens.len:
    connected.add(%gs.playerSockets.hasKey(slot))
  result = gs.sim.liveStateJson()
  result["type"] = %"state"
  result["game"] = %"grid-wars"
  result["policyNames"] = gs.policyNamesJson()
  result["events"] = events
  result["started"] = %gs.started
  result["done"] = %gs.sim.done
  result["connected"] = connected

proc broadcastLocked(gs: GameState) =
  ## Callers hold stateLock. Spectators get the whole board; players get
  ## the redacted per-seat state — never another seat's source.
  let payload = $gs.snapshotJson()
  for socket in gs.globalSockets:
    socket.send(payload)
  for slot, socket in gs.playerSockets:
    socket.send($gs.sim.playerStateJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc replayPayload(gs: GameState, results: JsonNode): string =
  var payload = gs.sim.replayJson()
  payload["results"] = results
  $payload

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  var results: JsonNode
  var replayData: string
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    results = state.sim.resultsJson()
    replayData = state.replayPayload(results)

    ## Send final frames to players BEFORE writing artifacts: the hosted
    ## worker tears player pods down as soon as results.json exists.
    ## Results carry POLICY names for the platform; the player frame gets
    ## the table aliases instead.
    var aliasNames = newJArray()
    for name in state.sim.names:
      aliasNames.add(%name)
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "tiles": results["tiles"],
      "roundsWon": results["roundsWon"],
      "names": aliasNames,
      "rounds": results["rounds"],
      "reason": results["reason"]
    }
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  echo "grid-wars: writing results and replay"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData,
    "application/octet-stream", "COGAME_SAVE_REPLAY_METHOD")
  ## The certifier pings /global with a 2 s deadline AFTER the player pods
  ## start, and a fast scripted episode would otherwise already be gone.
  echo "grid-wars: artifacts written; serving for ", ShutdownGraceSeconds,
    "s more"
  sleep(ShutdownGraceSeconds * 1000)
  echo "grid-wars: episode complete, shutting down"
  quit(0)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let config = state.config
    let gameStart = epochTime()
    let connectDeadline = gameStart + config.playerConnectTimeoutSeconds

    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.tokens.len
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      echo "grid-wars: starting with ", state.playerSockets.len, "/",
        config.tokens.len, " players connected"
      state.broadcastLocked()

    let client = newLlmClient(config)

    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      echo "grid-wars: episode timeout ", timeoutSeconds.int, "s (",
        (if hostedTimeout.len > 0: "from env" else: "assumed"),
        "); playing until ", (timeoutSeconds * PlayBudgetFraction).int, "s"

    var lastBatchEnd = 0.0
    while true:
      var simCopy: Sim
      var seats: seq[int]
      var prompts: seq[string]
      var scripted: seq[ScriptKind]
      var forceFallback = false
      withLock stateLock:
        if state.sim.done:
          break
        if playDeadline > 0.0 and
            epochTime() + RoundReserveSeconds > playDeadline:
          if state.sim.roundsPlayed > 0:
            echo "grid-wars: episode deadline reached after ",
              state.sim.roundsPlayed, "/", config.rounds,
              " rounds; ending early"
            state.sim.endEarly()
            state.broadcastLocked()
            break
          ## Nothing has been played at all: run ONE round on the fallback
          ## warriors (no LLM, ~30 ms) so the replay is never empty, then
          ## settle with reason = "deadline".
          echo "grid-wars: deadline before the first round; playing one " &
            "fallback round"
          forceFallback = true
        seats = state.sim.pendingSeats()
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        echo "grid-wars: round ", state.sim.round, " of ", config.rounds,
          " at ", (epochTime() - gameStart).int, "s"

      var decisions: seq[Submission]
      if forceFallback:
        for _ in seats:
          decisions.add(fallbackSubmission("episode deadline"))
      else:
        ## The slow part (Claude, ONE parallel batch for the whole round)
        ## runs outside the lock on a snapshot; only this thread mutates
        ## the sim, so the snapshot cannot go stale.
        decisions = client.decideAll(simCopy, seats, prompts, scripted)
        lastBatchEnd = epochTime()

      withLock stateLock:
        for index, seat in seats:
          let decision = decisions[index]
          echo "grid-wars: round ", state.sim.round, " ",
            state.sim.names[seat], " submits ", decision.script.len,
            " lines (", decision.origin, ") at ",
            (epochTime() - gameStart).int, "s"
          try:
            state.sim.submit(seat, decision.script, decision.notes,
              decision.banner, decision.origin, decision.rejected)
          except GridWarsError as error:
            echo "grid-wars: submission rejected (", error.msg,
              "); using the fallback warrior"
            let fallback = fallbackSubmission(error.msg)
            state.sim.submit(seat, fallback.script, "", "", "fallback",
              error.msg)
        state.broadcastLocked()

      if forceFallback:
        withLock stateLock:
          state.sim.endEarly()
          state.broadcastLocked()
        break

      ## Pace between rounds so spectators can read the new programs, and
      ## floor the wall spacing so a fast round cannot outrun the sidecar's
      ## 30-requests-per-minute cap.
      if not state.sim.done:
        let floorSeconds =
          if client.batchesUsed > 1: RoundSpacingSeconds * 2
          else: RoundSpacingSeconds
        var waited = 0
        if config.roundDelayMs > 0:
          sleep(config.roundDelayMs)
          waited = config.roundDelayMs
        if client.batchesUsed > 0 and lastBatchEnd > 0.0:
          let remaining = floorSeconds - (epochTime() - lastBatchEnd)
          if remaining > 0.0:
            echo "grid-wars: rate-limit floor, waiting ",
              remaining.int, "s (", client.batchesUsed, " batches)"
            sleep(int(remaining * 1000.0))
        discard waited

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc serveFile(request: Request, path, contentType: string) =
  if fileExists(path):
    var headers: HttpHeaders
    headers["Content-Type"] = contentType
    request.respond(200, headers, readFile(path))
  else:
    request.respond(404)

proc htmlHandler(name: string): RequestHandler =
  proc handler(request: Request) {.gcsafe.} =
    {.gcsafe.}:
      serveFile(request, clientDir() / name, "text/html; charset=utf-8")
  handler

proc assetHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let name = request.pathParams["name"]
    if "/" in name or "\\" in name or name.startsWith("."):
      request.respond(404)
      return
    let contentType =
      if name.endsWith(".png"): "image/png"
      elif name.endsWith(".ttf"): "font/ttf"
      else: "application/octet-stream"
    serveFile(request, dataDir() / name, contentType)

proc rendererHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "renderer.js",
      "application/javascript; charset=utf-8")

proc chromeCssHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    serveFile(request, clientDir() / "chrome.css", "text/css; charset=utf-8")

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let slotText = request.queryParams["slot"]
    let token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      echo "grid-wars: player slot ", slot, " connected (",
        state.playerSockets.len, "/", state.config.tokens.len, ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": "gridwars.player.v1",
        "slot": slot,
        "name": state.sim.names[slot],
        "id": slot + 1,
        "rounds": state.config.rounds,
        "ticks": state.config.ticks
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      websocket.send($state.snapshotJson())

proc replayUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    if replayPayloadGlobal.len > 0:
      websocket.send(replayPayloadGlobal)

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering
      ## them itself; the platform's certifier pings /global to check the
      ## game is alive, so an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() == "prompt":
          var prompt = payload{"prompt"}.getStr()
          if prompt.runeLen > MaxPromptLen:
            prompt = prompt.runeSubStr(0, MaxPromptLen)
          let node = payload{"scripted"}
          let scripted =
            if node.isNil: skNone
            elif node.kind == JBool: (if node.getBool(): skPainter else: skNone)
            else: parseScriptKind(node.getStr())
          withLock stateLock:
            state.prompts[slot] = prompt
            state.scripted[slot] = scripted
          echo "grid-wars: slot ", slot, " delivered a prompt (",
            prompt.len, " chars",
            (if scripted != skNone: ", scripted " & $scripted else: ""), ")"
      except CatchableError as error:
        echo "grid-wars: ignoring bad player frame: ", error.msg
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)

proc buildRouter(replayMode: bool): Router =
  result.get("/healthz", healthzHandler)
  result.get("/client/global", htmlHandler("global.html"))
  result.get("/client/player", htmlHandler("player.html"))
  result.get("/client/replay", htmlHandler("replay.html"))
  result.get("/client/renderer.js", rendererHandler)
  result.get("/client/chrome.css", chromeCssHandler)
  result.get("/client/assets/@name", assetHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/replay", replayUpgradeHandler)
  if not replayMode:
    result.get("/player", playerUpgradeHandler)

proc configFromReplay*(payload: JsonNode): GameConfig =
  result = defaultGameConfig()
  result.rounds = payload["config"]{"rounds"}.getInt(5)
  result.ticks = payload["config"]{"ticks"}.getInt(400)
  result.bombCost = payload["config"]{"bombCost"}.getInt(12)
  result.seed = payload["config"]{"seed"}.getInt(0)
  ## The replay carries the episode's fitted caps; never re-fit them.
  result.sampled = true
  for name in payload["names"]:
    result.players.add(PlayerConfig(name: name.getStr()))

proc runReplayServer*(runtimeConfig: RuntimeConfig) =
  let payload = parseJson(runtimeConfig.replay)
  let config = configFromReplay(payload)
  var events: seq[GameEvent]
  for node in payload["events"]:
    events.add(eventFromJson(node))
  var frames = newJArray()
  for frame in replayMatch(config, events):
    frames.add(frame)
  replayPayloadGlobal = $ %*{
    "type": "replay",
    "protocol": payload{"protocol"}.getStr("gridwars.replay.v1"),
    "names": payload["names"],
    "policyNames": payload{"policyNames"},
    "config": payload["config"],
    "events": payload["events"],
    "results": payload{"results"},
    "frames": frames
  }

  let router = buildRouter(replayMode = true)
  gameServer = newServer(router, websocketHandler)
  echo "grid-wars: replay mode on ", runtimeConfig.host, ":",
    runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len != config.players.len:
    raise newException(GridWarsError, "tokens and players must align")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.players.len)
  state.scripted = newSeq[ScriptKind](config.players.len)

  let router = buildRouter(replayMode = false)
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  echo "grid-wars: serving on ", runtimeConfig.host, ":", runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
