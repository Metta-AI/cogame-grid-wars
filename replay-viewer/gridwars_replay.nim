## Grid Wars static replay viewer, wasm side.
##
## JS hands the raw replay bytes to gw_load_replay; this module parses them
## with the SAME sim code the game server runs, RE-DERIVES every tick of
## every round from the recorded round seed, spawn permutation and warrior
## scripts, and asserts the recomputed per-round digest equals the recorded
## one. A mismatch is reported as an error rather than silently drawing a
## different game.
##
## The result is the enriched payload (the same shape the game's /replay
## websocket sends) for the shared renderer.js to draw.

import
  std/json,
  gridwars/sim

var
  payload: string
  lastError: string

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc gwLoadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "gw_load_replay", cdecl.} =
  try:
    lastError = ""
    let replay = parseJson(bytesFromPointer(data, int(length)))
    var config = defaultGameConfig()
    config.rounds = replay["config"]{"rounds"}.getInt(5)
    config.ticks = replay["config"]{"ticks"}.getInt(400)
    config.bombCost = replay["config"]{"bombCost"}.getInt(12)
    config.seed = replay["config"]{"seed"}.getBiggestInt(0)
    config.sampled = true
    for name in replay["names"]:
      config.players.add(PlayerConfig(name: name.getStr()))
    var events: seq[GameEvent]
    for node in replay["events"]:
      events.add(eventFromJson(node))
    var frames = newJArray()
    for frame in replayMatch(config, events):
      frames.add(frame)
    payload = $ %*{
      "type": "replay",
      "protocol": replay{"protocol"}.getStr("gridwars.replay.v1"),
      "names": replay["names"],
      "policyNames": replay{"policyNames"},
      "config": replay["config"],
      "events": replay["events"],
      "results": replay{"results"},
      "frames": frames
    }
    return 1
  except CatchableError as error:
    lastError = error.msg
    return 0

proc gwPayloadPointer(): ptr uint8 {.exportc: "gw_payload_ptr", cdecl.} =
  if payload.len == 0:
    nil
  else:
    cast[ptr uint8](payload[0].addr)

proc gwPayloadLength(): cint {.exportc: "gw_payload_len", cdecl.} =
  cint(payload.len)

proc gwErrorPointer(): ptr uint8 {.exportc: "gw_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc gwErrorLength(): cint {.exportc: "gw_error_len", cdecl.} =
  cint(lastError.len)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  ## Nim's generated main would run module-global destructors on return,
  ## freeing `payload` and friends while JS keeps calling into the module.
  ## Exiting with a live runtime skips the destructor epilogue so globals
  ## stay valid for the life of the page.
  emscriptenExitWithLiveRuntime()
