## End-to-end and strict UTF-8. A whole episode is played, the artifacts
## are written to a temp dir, the replay is re-read with a STRICT parser,
## and every round is re-derived from the recorded events and checked
## against its recorded digest — which is exactly what the wasm viewer does
## in the browser.

import std/[json, os, strutils, unicode, unittest]
import gridwars/[llm, sim]

proc fixture(seed: int, rounds = 3, ticks = 120): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.ticks = ticks
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "policy-" & $(index + 1)))
    result.tokens.add("t" & $index)

proc playScripted(config: GameConfig): Sim =
  result = initSim(config)
  let kinds = [skPainter, skBomber, skSentry, skPainter]
  while not result.done:
    for seat in result.pendingSeats():
      let submission = scriptedSubmission(kinds[seat])
      result.submit(seat, submission.script, submission.notes,
        submission.banner, submission.origin)

## Multi-byte text long enough to be cut at every cap.
const Multibyte = "héllo wörld — 日本語のメモ ✦ "

proc noisy(times: int): string =
  for _ in 0 ..< times:
    result.add(Multibyte)

proc playNoisy(config: GameConfig): Sim =
  result = initSim(config)
  while not result.done:
    for seat in result.pendingSeats():
      var script = warriorLines(skSentry)
      script.insert("# " & noisy(20), 0)
      result.submit(seat, script, noisy(60), noisy(20), "llm")

suite "artifacts":
  test "a whole episode writes a replay that a STRICT parser accepts":
    let dir = getTempDir() / "gridwars-replay-test"
    createDir(dir)
    defer: removeDir(dir)
    let sim = playNoisy(fixture(9, rounds = 2, ticks = 90))
    check sim.done
    check sim.reason == "complete"
    let path = dir / "replay.json"
    writeFile(path, $sim.replayJson())
    let raw = readFile(path)
    ## A byte cut through a multi-byte character produces replay bytes that
    ## render in a browser and fail a strict JSON parser. Check the bytes,
    ## then the parse.
    check raw.validateUtf8() == -1
    let parsed = parseJson(raw)
    check parsed["protocol"].getStr() == "gridwars.replay.v1"
    check parsed["names"].len == Seats
    check parsed["policyNames"].len == Seats
    check parsed["events"].len > 0
    check parsed["results"]["reason"].getStr() == "complete"
    ## Every recorded string is on a rune boundary and inside its cap.
    for event in parsed["events"]:
      if event["kind"].getStr() != "submit":
        continue
      check event["banner"].getStr().runeLen <= MaxBannerLen
      check event["text"].getStr().runeLen <= MaxNotesLen
      check event["script"].len <= MaxScriptLines
      var total = 0
      for line in event["script"]:
        check line.getStr().runeLen <= MaxLineChars
        check line.getStr().validateUtf8() == -1
        total += line.getStr().runeLen + 1
      check total <= MaxScriptChars

  test "captured error text reaches the replay on rune boundaries":
    ## The other road into the replay: not a seat's own prose but text the
    ## game CAPTURED — a lexer message quoting a character from the source,
    ## and a rejection excerpt from a model reply. Both land in
    ## `submit.compileError` and are written out verbatim by `replayJson`.
    var sim = initSim(fixture(11, rounds = 1, ticks = 40))
    for seat in sim.pendingSeats():
      if seat == 0:
        ## An em dash outside a comment: the lexer quotes the character.
        sim.submit(seat, @["var a = 1", "var b = 2 \u2014 3"], "", "", "llm")
      else:
        ## A fallback carrying a long multi-byte rejection, cut at the cap.
        let fallback = fallbackSubmission(
          "no JSON object in response: " & noisy(40))
        sim.submit(seat, fallback.script, fallback.notes, fallback.banner,
          fallback.origin, fallback.rejected)
    let raw = $sim.replayJson()
    check raw.validateUtf8() == -1
    var captured = 0
    var quotedDash = false
    for event in parseJson(raw)["events"]:
      if event["kind"].getStr() != "submit":
        continue
      let message = event["compileError"].getStr()
      check message.len > 0
      check message.runeLen <= 300
      check message.validateUtf8() == -1
      if event["seat"].getInt() == 0:
        quotedDash = "\u2014" in message
      inc captured
    check captured == Seats
    check quotedDash

  test "results.reason is complete or deadline and nothing else":
    let complete = playScripted(fixture(3, rounds = 2, ticks = 80))
    check complete.resultsJson()["reason"].getStr() == "complete"
    var early = initSim(fixture(3, rounds = 5, ticks = 80))
    for seat in early.pendingSeats():
      let submission = scriptedSubmission(skSentry)
      early.submit(seat, submission.script, "", "", "scripted")
    early.endEarly()
    check early.resultsJson()["reason"].getStr() == "deadline"
    ## And the whole legal set is those two: the sim settles by exactly one
    ## of two code paths.
    check early.reason in ["complete", "deadline"]
    check complete.reason in ["complete", "deadline"]

suite "re-derivation":
  test "replayMatch re-derives every round and its digest, over 20 seeds":
    for seed in 1 .. 20:
      let sim = playScripted(fixture(seed, rounds = 2, ticks = 90))
      var events: seq[GameEvent]
      for node in sim.replayJson()["events"]:
        events.add(eventFromJson(node))
      ## Raises on a digest mismatch; the wasm module turns that raise into
      ## data-replay-error rather than drawing a different game.
      let frames = replayMatch(sim.config, events)
      check frames.len > 0
      let records = recordsFromEvents(events)
      check records.len == sim.roundsPlayed
      for index, record in records:
        check record.digest == sim.history[index].digest
        check record.seed == sim.history[index].seed

  test "a league-sized seed survives the log and stays load-bearing":
    ## An unpinned seed is a random 31-bit number, so the derived round seed
    ## (`seed * 1000003 + round * 97`) runs to 2^51. It is written into the
    ## `round` event and read back by the server AND by the wasm viewer,
    ## where Nim's `int` is 32 bits — so every seed on the path is int64 and
    ## the number that comes back is the number that went out.
    let config = fixture(2147483647, rounds = 1, ticks = 60)
    var sim = initSim(config)
    check sim.roundSeed(1) > int64(high(int32))
    ## A warrior whose every move comes out of its rand() stream, so the
    ## seed decides the board.
    let dice = @[
      "while true:",
      "  var r = rand(4)",
      "  if r == 0:",
      "    place()",
      "  elif r == 1:",
      "    move(1, 0)",
      "  elif r == 2:",
      "    move(0, 1)",
      "  else:",
      "    bomb()"
    ]
    for seat in sim.pendingSeats():
      sim.submit(seat, dice, "", "", "llm")
    check sim.done
    var events: seq[GameEvent]
    for node in sim.replayJson()["events"]:
      events.add(eventFromJson(node))
    for event in events:
      if event.kind == evRound:
        check event.seed == sim.history[event.round - 1].seed
        check event.seed > int64(high(int32))
    ## Re-derivation from the logged seed reproduces the recorded digest.
    discard replayMatch(sim.config, events)
    ## And the seed is load-bearing: cut to 32 bits — what a platform `int`
    ## would have done in the browser — it is a different battle.
    var truncated = sim.history[0]
    truncated.seed = int64(cast[int32](sim.history[0].seed))
    check truncated.seed != sim.history[0].seed
    playRound(truncated, sim.config)
    check truncated.digest != sim.history[0].digest

  test "a tampered digest is caught":
    let sim = playScripted(fixture(4, rounds = 1, ticks = 60))
    var events: seq[GameEvent]
    for node in sim.replayJson()["events"]:
      events.add(eventFromJson(node))
    for index in 0 ..< events.len:
      if events[index].kind == evBattle:
        events[index].digest = "deadbeefdeadbeef"
    expect GridWarsError:
      discard replayMatch(sim.config, events)

  test "frames count Seats + ticksPlayed + 1 per played round":
    for seed in [2, 5, 8]:
      let sim = playScripted(fixture(seed, rounds = 3, ticks = 110))
      var want = 0
      for record in sim.history:
        want += Seats + record.ticksPlayed + 1
      let frames = sim.frameStates()
      check frames.len == want
      ## The live tail is the final frame, and it is the one that carries
      ## the end of the game.
      check frames[^1]["gameDone"].getBool()
      check frames[^1]["reason"].getStr() == sim.reason
      var events: seq[GameEvent]
      for node in sim.replayJson()["events"]:
        events.add(eventFromJson(node))
      let replayed = replayMatch(sim.config, events)
      check replayed.len == frames.len
      ## FRAME BY FRAME, not just the tail: the viewer draws every one of
      ## these, so every one of them has to be the state the server
      ## recorded. A digest per round proves the board; this proves the
      ## whole per-tick timeline the browser actually renders.
      var mismatch = -1
      for index in 0 ..< min(replayed.len, frames.len):
        if $replayed[index] != $frames[index]:
          mismatch = index
          break
      check mismatch == -1

  test "the live snapshot is the tail frame, built from the last round only":
    ## The live snapshot used to re-run EVERY battle played so far and
    ## build ~400 JSON frames per round to return ONE frame — work
    ## proportional to rounds^2, paid on every round boundary and on every
    ## /global connect. It now builds the last round's frames only. The
    ## frame must be the same frame: the earlier rounds still contribute
    ## their series row and their share of the running score, which is what
    ## the scorebug and the series table read.
    var sim = initSim(fixture(9, rounds = 3, ticks = 90))
    let kinds = [skPainter, skBomber, skSentry, skPainter]
    var played = 0
    while not sim.done:
      for seat in sim.pendingSeats():
        let submission = scriptedSubmission(kinds[seat])
        sim.submit(seat, submission.script, submission.notes,
          submission.banner, submission.origin)
      inc played
      let full = sim.frameStates()
      let live = sim.liveStateJson()
      check live["series"].len == played
      for key in ["series", "grid", "bombs", "corpses", "blast", "tick",
          "focus", "ticks"]:
        check $live[key] == $full[^1][key]
      for seat in 0 ..< Seats:
        ## Everything the battle decided; `pending` is the live overlay and
        ## is the only field the snapshot rewrites.
        for key in ["name", "score", "raw", "tiles", "peakTiles", "energy",
            "alive", "x", "y", "kills", "selfKills", "deathCause"]:
          check $live["seats"][seat][key] == $full[^1]["seats"][seat][key]

  test "frames carry a keyframe grid, deltas, bombs, corpses and scripts":
    let sim = playScripted(fixture(6, rounds = 1, ticks = 120))
    let frames = sim.frameStates()
    var fullGrids = 0
    var deltas = 0
    for frame in frames:
      if frame.hasKey("grid"):
        inc fullGrids
        check frame["grid"].getStr().len == Cells
      if frame.hasKey("gridDelta"):
        inc deltas
      check frame["seats"].len == Seats
      check frame.hasKey("bombs")
      check frame.hasKey("corpses")
      check frame.hasKey("blast")
      check frame["phase"].getStr() in
        ["submit", "battle", "roundEnd", "done"]
    check fullGrids > 0
    check deltas > 0
    ## Scripts ride on the submission frames only; the renderer walks back
    ## to the nearest one.
    var withScripts = 0
    for frame in frames:
      if frame.hasKey("scripts"):
        inc withScripts
        check frame["scripts"].len == Seats
    check withScripts == Seats * sim.roundsPlayed

  test "the delta stream and a keyframe seek reconstruct the same board":
    ## Two reconstruction paths — sequential playback and the renderer's
    ## seek (walk back to the nearest keyframe, replay the deltas forward)
    ## — must agree at every frame, and the reconstructed board must agree
    ## with the seats' own tile counts.
    let sim = playScripted(fixture(7, rounds = 2, ticks = 130))
    let frames = sim.frameStates()

    proc applyTo(grid: var string, frame: JsonNode) =
      if frame.hasKey("grid"):
        grid = frame["grid"].getStr()
      else:
        for change in frame["gridDelta"]:
          grid[change[0].getInt()] = change[1].getStr()[0]

    proc seekTo(index: int): string =
      var start = index
      while start > 0 and not frames[start].hasKey("grid"):
        dec start
      result = frames[start]["grid"].getStr()
      for k in start + 1 .. index:
        result.applyTo(frames[k])

    var sequential = ""
    var deltaFrames = 0
    for index, frame in frames:
      if frame.hasKey("gridDelta"):
        inc deltaFrames
        ## No no-op entries: a delta records only real changes.
        for change in frame["gridDelta"]:
          check sequential[change[0].getInt()] != change[1].getStr()[0]
      sequential.applyTo(frame)
      check sequential.len == Cells
      check seekTo(index) == sequential
      ## And the board really is the sim's board: every seat's tile count
      ## equals the count of its own character in the grid.
      for seat in 0 ..< Seats:
        var counted = 0
        for c in sequential:
          if c == char(ord('1') + seat):
            inc counted
        check counted == frame["seats"][seat]["tiles"].getInt()
    check deltaFrames > 0

suite "event JSON":
  test "every event kind round-trips":
    let sim = playNoisy(fixture(12, rounds = 2, ticks = 70))
    var kinds: seq[EventKind]
    for event in sim.events:
      kinds.add(event.kind)
      let restored = eventFromJson(event.eventToJson())
      check restored == event
    for kind in [evStart, evRound, evSubmit, evBattle, evEnd]:
      check kind in kinds

  test "the battle event carries the stats, the curve and the digest":
    let sim = playScripted(fixture(13, rounds = 1, ticks = 100))
    var seen = false
    for event in sim.events:
      if event.kind != evBattle:
        continue
      seen = true
      check event.stats.len == Seats
      check event.curve.len == Seats
      check event.digest.len == 16
      check event.reason in ["horizon", "lastStanding", "wipeout"]
      for series in event.curve:
        check series.len >= 2
    check seen

  test "the round event logs the seed and the spawn permutation":
    let sim = playScripted(fixture(14, rounds = 2, ticks = 60))
    var rounds = 0
    for event in sim.events:
      if event.kind != evRound:
        continue
      inc rounds
      check event.seed == sim.roundSeed(event.round)
      check event.spawn.len == Seats
      check event.ticks == sim.config.ticks
    check rounds == sim.roundsPlayed
