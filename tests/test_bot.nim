## Bounded orders and legality on the three scripted baselines, and the
## tolerant reply parsing that keeps an LLM seat out of the fallback.
##
## The baselines are BOTH the no-credentials fallback (the offline
## certification path) and fieldable policies, so this is the completion
## path for the whole game.

import std/[json, monotimes, strutils, times, unicode, unittest]
import gridwars/[llm, sim]

proc fixture(seed: int, rounds = 1, ticks = 400): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.ticks = ticks
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

proc play(config: GameConfig, kinds: array[Seats, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in result.pendingSeats():
      let submission = scriptedSubmission(kinds[seat])
      result.submit(seat, submission.script, submission.notes,
        submission.banner, submission.origin)

suite "the shipped warriors":
  test "all three compile":
    for kind in [skPainter, skBomber, skSentry]:
      let source = warriorLines(kind)
      check source.len > 0
      check source.len <= MaxScriptLines
      let program = compile(source)
      check program.ops.len > 0

  test "the round-1 seed script IS the sentry warrior":
    ## design.md:487 makes them one object: "the always-legal fallback, and
    ## the round-1 seed script". They live in two places — `SeedScript`
    ## (sim.nim, the literal every LLM seat is shown in round 1) and
    ## `data/warriors/sentry.gwl` (staticRead, the fallback) — and nothing
    ## tied the copies together, so an edit to one would silently show a
    ## seat a script the fallback does not play.
    check SeedScript == warriorLines(skSentry)

  test "four seats of each play whole episodes cleanly and fast":
    for kind in [skPainter, skBomber, skSentry]:
      var seats: array[Seats, ScriptKind]
      for seat in 0 ..< Seats:
        seats[seat] = kind
      for seed in [1, 7, 42, 1234]:
        let started = getMonoTime()
        let sim = play(fixture(seed), seats)
        let elapsed = (getMonoTime() - started).inMilliseconds
        check sim.done
        check sim.reason == "complete"
        check elapsed < 2000
        for record in sim.history:
          check record.ticksPlayed == 400
          for seat in 0 ..< Seats:
            let stat = record.stat[seat]
            ## Zero faults, zero stalls, zero illegal actions, and every
            ## action legal as submitted.
            check stat.faultLine == 0
            check stat.stalls == 0
            check stat.illegal == 0
            check stat.deathCause == ""
            ## A refused bomb while the warrior could afford one would be a
            ## baseline wasting a tick on an action it should not have
            ## taken; the shipped warriors never do.
            check stat.refused == 0

  test "painter beats the sentry fallback on mean score over ten seeds":
    ## The note's criterion for the strong baseline (design.md:513-515):
    ## "a baseline that cannot beat the fallback is not a partner worth
    ## beating". painter's three free parameters — the turn-run length, the
    ## rival trigger distance and the bomb cadence — were swept with the
    ## grid harness in tools/tune_painter.nim (turn run 6..40, trigger 1 or
    ## 2 cells, cadence 3/6/12 ticks), scored on these ten seeds AND on a
    ## held-out 11..40, and the configuration that won both was kept:
    ## run 22, a two-cell trigger, and at most one bomb per fuse.
    var painterTotal = 0.0
    var sentryTotal = 0.0
    for seed in 1 .. 10:
      let sim = play(fixture(seed),
        [skPainter, skSentry, skPainter, skSentry])
      painterTotal += sim.score(0) + sim.score(2)
      sentryTotal += sim.score(1) + sim.score(3)
    check painterTotal / 20.0 > sentryTotal / 20.0
    ## Measured +39.7 vs -39.7; asserted well clear of a zero-sum tie.
    check painterTotal / 20.0 > 20.0
    ## Neither the seating nor those ten seeds carry the result: the two
    ## seats swap and the seeds are held out.
    var heldOut = 0.0
    for seed in 11 .. 20:
      let sim = play(fixture(seed),
        [skSentry, skPainter, skSentry, skPainter])
      heldOut += sim.score(1) + sim.score(3)
    check heldOut / 20.0 > 20.0

  test "the two shipped fillers are decisively ordered over ten seeds":
    ## painter and bomber are the two FILLERS a champion is seated against
    ## (tools/ci/policies.json). Measured over ten seeds, bomber still beats
    ## the tuned painter: its roaming bomb wall reaches painter's box and
    ## kills it, and a kill is worth 50 plus the 100 survival bonus the dead
    ## warrior loses. The gap is much smaller than it was against the
    ## note's untuned painter (-30.8), which is the point of the tuning.
    var painterTotal = 0.0
    var bomberTotal = 0.0
    for seed in 1 .. 10:
      let sim = play(fixture(seed),
        [skPainter, skBomber, skPainter, skBomber])
      painterTotal += sim.score(0) + sim.score(2)
      bomberTotal += sim.score(1) + sim.score(3)
    check bomberTotal / 20.0 > painterTotal / 20.0
    ## And the gap is real, not noise on a zero-sum tie.
    check bomberTotal / 20.0 - painterTotal / 20.0 > 10.0


  test "decideAll with no credentials is scripted and never touches the network":
    let sim = initSim(fixture(3))
    let client = newLlmClient(sim.config)
    ## No ANTHROPIC_API_KEY and no Bedrock endpoint in CI: the client must
    ## disable itself at construction, which is what makes offline
    ## certification complete in about a second.
    check client.disabled
    let started = getMonoTime()
    let decisions = client.decideAll(sim, @[0, 1, 2, 3],
      @["a prompt", "another", "", ""],
      @[skNone, skPainter, skBomber, skSentry])
    let elapsed = (getMonoTime() - started).inMilliseconds
    check elapsed < 500
    check client.batchesUsed == 0
    check decisions.len == 4
    check decisions[0].script == warriorLines(skSentry)
    check decisions[1].script == warriorLines(skPainter)
    check decisions[2].script == warriorLines(skBomber)
    check decisions[3].script == warriorLines(skSentry)
    for decision in decisions:
      check decision.origin == "scripted"

suite "reply parsing":
  test "the canonical array-of-lines form":
    let reply = """{"script": ["var dx = 1", "while true:", "  place()",
      "  move(dx, 0)"], "notes": "spiral", "banner": "painting east"}"""
    let submission = parseSubmission(extractJsonObject(reply))
    check submission.script.len == 4
    check submission.script[2] == "  place()"
    check submission.notes == "spiral"
    check submission.banner == "painting east"

  test "a single string with newlines is accepted":
    let reply = "{\"script\": \"var dx = 1\\nwhile true:\\n  place()\\n" &
      "  move(dx, 0)\"}"
    let submission = parseSubmission(extractJsonObject(reply))
    check submission.script.len == 4
    check submission.notes == ""
    check submission.banner == ""

  test "a markdown fence around the whole reply is stripped":
    let reply = "```json\n{\"script\": [\"while true:\", \"  place()\"]}\n```"
    let submission = parseSubmission(extractJsonObject(reply))
    check submission.script == @["while true:", "  place()"]

  test "a fence inside the script value is stripped":
    let reply = """{"script": ["```nim", "while true:", "  place()", "```"]}"""
    let submission = parseSubmission(extractJsonObject(reply))
    check submission.script == @["while true:", "  place()"]

  test "trailing prose after the closing brace is ignored":
    let reply = "{\"script\": [\"while true:\", \"  place()\"]}\n\n" &
      "I hope this warrior serves you well."
    let submission = parseSubmission(extractJsonObject(reply))
    check submission.script.len == 2

  test "a missing or empty script is a rejection":
    expect GridWarsError:
      discard parseSubmission(extractJsonObject("""{"notes": "hi"}"""))
    expect GridWarsError:
      discard parseSubmission(extractJsonObject("""{"script": []}"""))
    expect GridWarsError:
      discard parseSubmission(extractJsonObject("""{"script": [""]}"""))

  test "a script that does not compile raises with its line number":
    let reply = """{"script": ["while true:", "  place()", "  move(1"]}"""
    try:
      discard parseSubmission(extractJsonObject(reply))
      check false
    except GwlCompileError as error:
      check "line 3" in error.msg

  test "tabs become two spaces and trailing whitespace goes":
    let reply = "{\"script\": [\"while true:\", \"\\tplace()   \"]}"
    let submission = parseSubmission(extractJsonObject(reply))
    check submission.script[1] == "  place()"

  test "over-long lines, 120 lines and 4000 characters are capped":
    var script = newJArray()
    for index in 0 ..< 200:
      script.add(%("var v" & $index & " = " & repeat("9", 200)))
    let payload = %*{"script": script}
    let capped = capScript(normaliseScript(payload["script"]))
    check capped.len <= MaxScriptLines
    var total = 0
    for line in capped:
      check line.runeLen <= MaxLineChars
      total += line.runeLen + 1
    check total <= MaxScriptChars

  test "notes and banner cap on RUNE boundaries, never bytes":
    ## A byte cut through a multi-byte character produces replay bytes that
    ## render in a browser and fail a strict JSON parser.
    let long = repeat("é", 700)
    let payload = %*{
      "script": ["while true:", "  place()"],
      "notes": long,
      "banner": repeat("ü", 200) & "\nsecond line"
    }
    let submission = parseSubmission(payload)
    check submission.notes.runeLen == MaxNotesLen
    check submission.notes.validateUtf8() == -1
    check submission.banner.runeLen == MaxBannerLen
    check submission.banner.validateUtf8() == -1
    check "\n" notin submission.banner

  test "a reply with no JSON object at all quotes what arrived":
    try:
      discard extractJsonObject("I cannot help with that request.")
      check false
    except GridWarsError as error:
      check "no JSON object" in error.msg
      check "I cannot help" in error.msg

  test "the quoted excerpt is cut on runes at every offset":
    ## The excerpt travels into the retry prompt and, on a fallback, into
    ## the replay's compileError. A byte cut at the 160-character mark
    ## through the multi-byte character sitting on it would put a split
    ## character in both.
    for pad in 150 .. 170:
      let refusal = "I am sorry, I cannot" & repeat("a", pad) & "é tail"
      try:
        discard extractJsonObject(refusal)
        check false
      except GridWarsError as error:
        check error.msg.validateUtf8() == -1
        check cleanText(error.msg, 300).validateUtf8() == -1
        check fallbackSubmission(error.msg).rejected.validateUtf8() == -1

  test "a UTF-8 BOM does not defeat the parser":
    let reply = "\xEF\xBB\xBF{\"script\": [\"while true:\", \"  place()\"]}"
    let submission = parseSubmission(extractJsonObject(reply))
    check submission.script.len == 2

  test "parseScriptKind maps every documented value":
    check parseScriptKind("1") == skPainter
    check parseScriptKind("true") == skPainter
    check parseScriptKind("yes") == skPainter
    check parseScriptKind("painter") == skPainter
    check parseScriptKind("bomber") == skBomber
    check parseScriptKind("sentry") == skSentry
    check parseScriptKind("") == skNone
    check parseScriptKind("nonsense") == skNone
