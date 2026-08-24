## Sealing and redaction. A seat's prompt carries its own script and its
## own diagnostics and NOTHING of anyone else's: no other seat's source, no
## other seat's notes or banner, no policy name, and not the round seed.
##
## Sealing is enforced by `seatObservation`, not by convention, and this is
## the test that says so.

import std/[json, strutils, unittest]
import gridwars/[llm, sim]

proc fixture(seed = 21, rounds = 3, ticks = 120): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.ticks = ticks
  result.sampled = true
  ## Policy names that are unmistakable if one ever leaks into a prompt.
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "SECRETPOLICY" & $(index + 1)))
    result.tokens.add("t" & $index)

## Four warriors that are legal, distinct, and carry a marker no other
## seat's script contains — so "contains a substring of another seat's
## script" is a question with a sharp answer.
proc markedScript(seat: int): seq[string] =
  @[
    "# WARRIORMARKER" & $seat & " is this seat's private signature.",
    "var stride" & $seat & " = " & $(seat + 1),
    "var dx = 1",
    "var dy = 0",
    "var t = 0",
    "while true:",
    "  place()",
    "  if check(dx, dy) == BOMB or check(dx, dy) == CORPSE:",
    "    t = dx",
    "    dx = 0 - dy",
    "    dy = t",
    "  else:",
    "    move(dx, dy)"
  ]

proc played(config: GameConfig, rounds: int): Sim =
  result = initSim(config)
  var round = 0
  while not result.done and round < rounds:
    for seat in result.pendingSeats():
      result.submit(seat, markedScript(seat),
        "NOTESFOR" & $seat & " keep painting east",
        "BANNERFOR" & $seat, "llm")
    inc round

suite "the seat observation":
  test "a seat sees its own script, its own diagnostics and the board":
    let sim = played(fixture(), 1)
    check sim.roundsPlayed == 1
    for seat in 0 ..< Seats:
      let text = sim.seatObservation(seat)
      check ("WARRIORMARKER" & $seat) in text
      check ("NOTESFOR" & $seat) in text
      check sim.names[seat] in text
      check "YOUR LAST ROUND" in text
      check "SERIES SO FAR" in text
      check "THE BOARD AT THE END OF ROUND" in text
      check "ticks survived" in text
      check "illegal" in text
      check "tiles every 25 ticks" in text
      ## The ASCII map really is 30 rows of 30.
      let board = sim.boardAscii(1)
      check board in text
      let rows = board.split("\n")
      check rows.len == 30
      for row in rows:
        check row.len == 30
        for c in row:
          check c in {'.', '1', '2', '3', '4', '*', 'x'}

  test "a seat sees NO other seat's script, notes or banner":
    let sim = played(fixture(), 2)
    for seat in 0 ..< Seats:
      let text = sim.seatObservation(seat)
      for other in 0 ..< Seats:
        if other == seat:
          continue
        check ("WARRIORMARKER" & $other) notin text
        check ("stride" & $other) notin text
        check ("NOTESFOR" & $other) notin text
        check ("BANNERFOR" & $other) notin text
        ## Nothing of the other seat's SOURCE at all: every line of it that
        ## is not also a line of this seat's own script must be absent.
        var mine: seq[string]
        for line in markedScript(seat):
          mine.add(line.strip())
        for line in markedScript(other):
          let stripped = line.strip()
          if stripped.len > 8 and stripped notin mine:
            check stripped notin text

  test "no prompt ever contains a policy name":
    let sim = played(fixture(), 2)
    for seat in 0 ..< Seats:
      let system = systemPrompt(sim, seat)
      let user = userPrompt(sim, seat, "your operator prompt goes here")
      for other in 0 ..< Seats:
        check ("SECRETPOLICY" & $(other + 1)) notin system
        check ("SECRETPOLICY" & $(other + 1)) notin user
      check "SECRETPOLICY" notin system
      check "SECRETPOLICY" notin user

  test "no prompt ever contains the round seed or the spawn permutation":
    let sim = played(fixture(), 2)
    for seat in 0 ..< Seats:
      let text = systemPrompt(sim, seat) & "\n" &
        userPrompt(sim, seat, "operator")
      for round in 1 .. sim.config.rounds:
        check $sim.roundSeed(round) notin text
      check $sim.config.seed notin text or sim.config.seed < 100

  test "the user prompt carries the operator block and the format reminder":
    let sim = played(fixture(), 1)
    let text = userPrompt(sim, 0, "PROMPTFROMOPERATOR")
    check "PROMPTFROMOPERATOR" in text
    check "GUIDANCE FROM YOUR OPERATOR" in text
    check "\"script\"" in text
    check $MaxScriptLines in text
    check $MaxNotesLen in text

  test "the system prompt is the rules and the full language reference":
    let sim = played(fixture(), 1)
    let text = systemPrompt(sim, 1)
    check sim.names[1] in text
    check "warrior id 2" in text
    check "blue" in text
    for needle in ["check(dx, dy)", "who(dx, dy)", "BOMBCOST", "gridSize",
        "MAXFUSE", "while true:", "TICK RESOLUTION ORDER", "roundScore",
        "ARRAY OF LINES", "must begin with the character {"]:
      check needle in text

  test "round 1 shows the sentry seed script and no diagnostics":
    let sim = initSim(fixture())
    let text = sim.seatObservation(0)
    check "No round has been played yet" in text
    check "SENTRY" in text
    check "sentry - the fallback warrior" in text
    check "YOUR LAST ROUND" notin text

suite "the player socket frame":
  test "the state frame is redacted to the seat":
    let sim = played(fixture(), 2)
    for seat in 0 ..< Seats:
      let frame = $sim.playerStateJson(seat)
      check ("WARRIORMARKER" & $seat) in frame
      check ("NOTESFOR" & $seat) in frame
      for other in 0 ..< Seats:
        if other == seat:
          continue
        check ("WARRIORMARKER" & $other) notin frame
        check ("NOTESFOR" & $other) notin frame
        check ("BANNERFOR" & $other) notin frame
        check ("SECRETPOLICY" & $(other + 1)) notin frame
      ## The public board summary is not hidden information.
      let node = sim.playerStateJson(seat)
      check node["tiles"].len == Seats
      check node["slot"].getInt() == seat
      check node["name"].getStr() == sim.names[seat]

  test "results attribute by POLICY name, never by alias":
    let sim = played(fixture(rounds = 1), 1)
    let results = sim.resultsJson()
    for seat in 0 ..< Seats:
      check results["names"][seat].getStr() == "SECRETPOLICY" & $(seat + 1)
    for name in sim.names:
      check name != results["winner"].getStr()
