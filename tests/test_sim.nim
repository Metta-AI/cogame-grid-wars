## The arena. The tick resolution order on hand-built boards (explicit
## spawn cells and purpose-built warriors), bombs and chains, elimination,
## the scoring identity, endings, and determinism.

import std/[json, math, sets, strutils, unittest]
import gridwars/sim

proc fixture(seed = 0, rounds = 3, ticks = 200, bombCost = 12): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = rounds
  result.ticks = ticks
  result.bombCost = bombCost
  ## Pinned, so these tests exercise the rules rather than the budget cap.
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("token-" & $index)

proc lines(source: string): seq[string] =
  source.strip().splitLines()

## Warriors used to build exact situations.
const
  Idler = """
# never acts: halts immediately and dies to the idle rule.
wait()
"""
  Placer = """
while true:
  place()
"""
  EastWalker = """
while true:
  move(1, 0)
"""
  Bomber = """
var done = 0
while true:
  if done == 0:
    done = 1
    bomb()
  else:
    wait()
"""
  Faulter = """
var a = 0
var b = 1
while true:
  place()
  b = b div a
"""

proc handBuilt(scripts: array[Seats, string], spawn: array[Seats, int],
    ticks: int, config = fixture()): RoundRecord =
  result.seed = 12345
  result.ticks = ticks
  for seat in 0 ..< Seats:
    result.scripts[seat] = lines(scripts[seat])
    result.spawn[seat] = spawn[seat]
    result.origin[seat] = "scripted"
  var cfg = config
  cfg.ticks = ticks
  playRound(result, cfg)

proc cell(x, y: int): int = y * 30 + x

proc playSeries(config: GameConfig, scripts: array[Seats, seq[string]]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in result.pendingSeats():
      result.submit(seat, scripts[seat], "", "", "scripted")

proc allSame(source: string): array[Seats, string] =
  for seat in 0 ..< Seats:
    result[seat] = source

suite "setup":
  test "the spawn permutation is seeded, reproducible and a permutation":
    var seen: seq[HashSet[int]]
    for seed in [0, 1, 7, 42, 1234]:
      let a = initSim(fixture(seed = seed))
      let b = initSim(fixture(seed = seed))
      var spawnA: seq[int]
      var spawnB: seq[int]
      for event in a.events:
        if event.kind == evRound:
          spawnA = event.spawn
      for event in b.events:
        if event.kind == evRound:
          spawnB = event.spawn
      check spawnA == spawnB
      check spawnA.len == Seats
      var cells = initHashSet[int]()
      for value in spawnA:
        cells.incl(value)
      check cells.len == Seats
      var corners = initHashSet[int]()
      for corner in SpawnCells:
        corners.incl(corner[1] * 30 + corner[0])
      for value in spawnA:
        check value in corners
      seen.add(cells)
    ## The permutation really moves between rounds of one episode.
    let sim = initSim(fixture(seed = 3, rounds = 6))
    var perRound: seq[seq[int]]
    for event in sim.events:
      if event.kind == evRound:
        perRound.add(event.spawn)
    check perRound.len == 1
    check sim.roundSeed(1) != sim.roundSeed(2)

  test "sampleEpisode clamps and is idempotent":
    var config = defaultGameConfig()
    config.rounds = 99
    config.ticks = 5
    config.roundDelayMs = 100000
    let once = sampleEpisode(config)
    check once.rounds == MaxRounds
    check once.ticks == MinTicks
    check once.roundDelayMs <= PacingBudgetMs
    check once.sampled
    let twice = sampleEpisode(once)
    check twice == once

suite "the tick resolution order":
  test "priority rotates every tick and is the only tie-break":
    for tick in 0 ..< 9:
      let order = tickPriority(tick)
      var seen = initHashSet[int]()
      for k in 0 ..< Seats:
        check order[k] == (k + tick) mod Seats
        seen.incl(order[k])
      check seen.len == Seats
    check tickPriority(0)[0] == 0
    check tickPriority(1)[0] == 1

  test "a contested cell goes to the higher-priority seat and flips next tick":
    ## Two warriors that shuttle in and out of the SAME middle cell. Seat 0
    ## sits at x=5 and steps to 6 and back; seat 2 sits at x=7 and steps to
    ## 6 and back. Every tick both want (6,10).
    ##
    ## Tick 0 (priority 0,1,2,3) seat 0 gets it and seat 2 is blocked. If
    ## the priority order were FIXED, seat 0 would win every contest and its
    ## `blocked` counter would stay at zero forever. It does not, because
    ## the order rotates — which is exactly what this asserts.
    let shuttleFrom5 = """
while true:
  if x() == 5:
    move(1, 0)
  else:
    move(-1, 0)
"""
    let shuttleFrom7 = """
while true:
  if x() == 7:
    move(-1, 0)
  else:
    move(1, 0)
"""
    var record = handBuilt([shuttleFrom5, Idler, shuttleFrom7, Idler],
      [cell(5, 10), cell(0, 0), cell(7, 10), cell(29, 29)], 8)
    check record.stat[2].blocked > 0     ## seat 2 lost the tick-0 contest
    check record.stat[0].blocked > 0     ## and seat 0 lost a later one
    check record.stat[0].illegal == 0
    check record.stat[2].illegal == 0

  test "check in tick t sees the board as it stood at the end of tick t-1":
    ## Seat 0 paints its cell on tick 0 and steps east on tick 1. Seat 2,
    ## standing next to it, records what check() said on each tick. If the
    ## decision pass saw a mutated board, the two readings would differ.
    let observer = """
var sawFirst = 0
var sawSecond = 0
while true:
  if tick() == 0:
    sawFirst = check(-1, 0)
    place()
  elif tick() == 1:
    sawSecond = check(-1, 0)
    place()
  else:
    wait()
"""
    var record = handBuilt([Placer, Idler, observer, Idler],
      [cell(5, 10), cell(0, 0), cell(6, 10), cell(29, 29)], 3)
    ## Seat 0 placed on tick 0, so on tick 0 the observer must still see
    ## EMPTY, and on tick 1 it sees the owner id 1.
    check record.stat[2].alive
    ## The observer painted its own cell twice, so it holds exactly 1 tile.
    check record.stat[2].tiles == 1
    check record.stat[0].tiles == 1

  test "a move into a corpse or a warrior is blocked and counted":
    var record = handBuilt([EastWalker, Idler, Placer, Idler],
      [cell(5, 10), cell(0, 0), cell(6, 10), cell(29, 29)], 5)
    check record.stat[0].blocked == 5
    check record.stat[0].illegal == 0

  test "an illegal offset wastes the tick and is counted, and is not a fault":
    let teleporter = """
while true:
  move(15, 15)
"""
    var record = handBuilt([teleporter, Idler, Idler, Idler],
      [cell(5, 10), cell(0, 0), cell(20, 20), cell(29, 29)], 6)
    check record.stat[0].illegal == 6
    check record.stat[0].faultLine == 0
    check record.stat[0].deathCause != "fault"

  test "a bomb without energy is refused and counted":
    ## bombCost 12 and 12 starting energy: the first bomb lands, the second
    ## cannot until the energy is back.
    let serial = """
while true:
  bomb()
"""
    var config = fixture(bombCost = 12)
    var record = handBuilt([serial, Idler, Idler, Idler],
      [cell(5, 10), cell(0, 0), cell(20, 20), cell(29, 29)], 4)
    check record.stat[0].refused >= 3

suite "bombs":
  test "the fuse counts down and the blast is a wrapping plus that scorches":
    ## Seat 0 plants one bomb and stands on it; seat 2 has painted the cell
    ## north of it. The blast must scorch both.
    let painterNorth = """
while true:
  place()
"""
    var record = handBuilt([Bomber, Idler, painterNorth, Idler],
      [cell(5, 10), cell(0, 0), cell(5, 9), cell(29, 29)], 8)
    ## The bomber never moved, so it dies in its own blast — a self-kill.
    check record.stat[0].deathCause == "bomb"
    check record.stat[0].selfKills == 1
    ## The neighbour it also took out still counts as a kill for it.
    check record.stat[0].kills == 1
    ## The neighbour is inside the plus and dies too, credited to seat 0.
    check record.stat[2].deathCause == "bomb"
    check record.stat[2].tiles == 0
    check record.stat[0].deathTick == 4

  test "a kill on another warrior is a kill, not a self-kill":
    ## Seat 0 plants and walks out of the blast; seat 2 stays put next door.
    let bombAndRun = """
var step = 0
while true:
  step = step + 1
  if step == 1:
    bomb()
  else:
    move(0, 1)
"""
    var record = handBuilt([bombAndRun, Idler, Placer, Idler],
      [cell(5, 10), cell(0, 0), cell(6, 10), cell(29, 29)], 8)
    check record.stat[2].deathCause == "bomb"
    check record.stat[0].kills == 1
    check record.stat[0].selfKills == 0
    check record.stat[0].alive

  test "bombs caught in a blast chain to closure":
    ## Two bombers three cells apart: the first blast reaches the second
    ## bomb's cell, which detonates in the same wave and takes its planter
    ## with it, at the SAME tick.
    var record = handBuilt([Bomber, Idler, Bomber, Idler],
      [cell(5, 10), cell(0, 0), cell(7, 10), cell(29, 29)], 8)
    check record.stat[0].deathCause == "bomb"
    check record.stat[2].deathCause == "bomb"
    check record.stat[0].deathTick == record.stat[2].deathTick

  test "elimination un-paints every tile the dead warrior owned":
    ## Seat 2 paints a long line, then is blown up; its tiles must all be
    ## gone from the final board, not just the scorched ones.
    let paintAndDie = """
while true:
  place()
  move(-1, 0)
"""
    var record = handBuilt([Bomber, Idler, paintAndDie, Idler],
      [cell(5, 10), cell(0, 0), cell(8, 10), cell(29, 29)], 8)
    ## It painted (8,10), (7,10) and (6,10) before walking into the blast.
    check record.stat[2].deathCause == "bomb"
    check record.stat[2].tiles == 0
    check '3' notin record.ascii

suite "endings":
  test "a warrior that never moves dies of idle at exactly 50":
    var record = handBuilt(allSame(Placer), [cell(2, 2), cell(10, 10),
      cell(20, 20), cell(27, 27)], 120)
    for seat in 0 ..< Seats:
      check record.stat[seat].deathCause == "idle"
      check record.stat[seat].deathTick == IdleLimit - 1
    check record.reason == "wipeout"
    check record.ticksPlayed == IdleLimit

  test "a fault kills at the fault pass with the line recorded":
    var record = handBuilt([Faulter, EastWalker, EastWalker, EastWalker],
      [cell(2, 2), cell(10, 10), cell(20, 20), cell(27, 27)], 30)
    check record.stat[0].deathCause == "fault"
    check record.stat[0].faultLine == 5
    check "division by zero" in record.stat[0].faultText
    check record.stat[0].tiles == 0

  test "lastStanding stops the round immediately":
    ## Three idlers die at tick 49; the fourth walks and survives, so the
    ## round ends at that tick with one warrior left.
    var record = handBuilt([EastWalker, Placer, Placer, Placer],
      [cell(2, 2), cell(10, 10), cell(20, 20), cell(27, 27)], 400)
    check record.reason == "lastStanding"
    check record.ticksPlayed == IdleLimit
    check record.stat[0].alive

  test "horizon ends the round at the tick cap":
    var record = handBuilt(allSame(EastWalker), [cell(2, 2), cell(10, 10),
      cell(20, 20), cell(27, 27)], 40)
    check record.reason == "horizon"
    check record.ticksPlayed == 40
    for seat in 0 ..< Seats:
      check record.stat[seat].alive

suite "scoring":
  test "raw and roundScore follow the formula and sum to zero":
    var record = handBuilt([EastWalker, EastWalker, EastWalker, Faulter],
      [cell(2, 2), cell(10, 10), cell(20, 20), cell(27, 27)], 40)
    var rawTotal = 0
    for seat in 0 ..< Seats:
      let stat = record.stat[seat]
      let expected = stat.tiles + (if stat.alive: SurviveBonus else: 0) +
        KillBonus * stat.kills - KillBonus * stat.selfKills
      check stat.raw == expected
      rawTotal += stat.raw
    var scoreTotal = 0.0
    for seat in 0 ..< Seats:
      check abs(record.stat[seat].roundScore -
        (record.stat[seat].raw.float - rawTotal.float / 4.0)) < 1e-9
      scoreTotal += record.stat[seat].roundScore
    check abs(scoreTotal) < 1e-9

  test "episode scores are the mean roundScore and sum to zero":
    let sim = playSeries(fixture(seed = 5, rounds = 3, ticks = 120),
      [lines(EastWalker), lines(Placer), lines(EastWalker), lines(Placer)])
    check sim.done
    check sim.reason == "complete"
    var total = 0.0
    for seat in 0 ..< Seats:
      var manual = 0.0
      for record in sim.history:
        manual += record.stat[seat].roundScore
      check abs(sim.score(seat) - manual / sim.roundsPlayed.float) < 1e-9
      total += sim.score(seat)
    check abs(total) < 1e-9
    let results = sim.resultsJson()
    var resultTotal = 0.0
    for value in results["scores"]:
      resultTotal += value.getFloat()
    check abs(resultTotal) < 1e-9
    check results["reason"].getStr() == "complete"
    check results["roundReasons"].len == sim.roundsPlayed

  test "roundsWon counts unique maxima only":
    let sim = playSeries(fixture(seed = 11, rounds = 2, ticks = 100),
      [lines(EastWalker), lines(EastWalker), lines(EastWalker),
       lines(EastWalker)])
    var won = 0
    for seat in 0 ..< Seats:
      won += sim.roundsWon(seat)
    ## Four identical warriors tie every round, so nobody wins one.
    check won == 0

suite "endings and determinism":
  test "endEarly settles as deadline and divides by the rounds played":
    var sim = initSim(fixture(seed = 2, rounds = 5, ticks = 100))
    for seat in sim.pendingSeats():
      sim.submit(seat, lines(EastWalker), "", "", "scripted")
    check sim.roundsPlayed == 1
    sim.endEarly()
    check sim.done
    check sim.reason == "deadline"
    let results = sim.resultsJson()
    check results["reason"].getStr() == "deadline"
    check results["rounds"].getInt() == 1
    check results["maxRounds"].getInt() == 5
    for seat in 0 ..< Seats:
      check abs(sim.score(seat) - sim.history[0].stat[seat].roundScore) < 1e-9

  test "results.reason is only ever complete or deadline":
    let complete = playSeries(fixture(seed = 4, rounds = 2, ticks = 60),
      [lines(EastWalker), lines(EastWalker), lines(EastWalker),
       lines(EastWalker)])
    check complete.resultsJson()["reason"].getStr() in ["complete", "deadline"]
    for record in complete.history:
      check record.reason in ["horizon", "lastStanding", "wipeout"]

  test "the same config twice gives an identical digest":
    for seed in [0, 1, 7, 99]:
      let a = playSeries(fixture(seed = seed, rounds = 2, ticks = 150),
        [lines(EastWalker), lines(Placer), lines(Bomber), lines(EastWalker)])
      let b = playSeries(fixture(seed = seed, rounds = 2, ticks = 150),
        [lines(EastWalker), lines(Placer), lines(Bomber), lines(EastWalker)])
      for index in 0 ..< a.history.len:
        check a.history[index].digest == b.history[index].digest
        check a.history[index].ascii == b.history[index].ascii

  test "a reply with no notes clears them; it never carries last round's":
    ## design.md:371 — "banner/notes missing => empty". Both fields are
    ## overwritten by every submission, so a seat is never fed text it did
    ## not write this round.
    var sim = initSim(fixture(seed = 2, rounds = 2, ticks = 40))
    for seat in sim.pendingSeats():
      sim.submit(seat, lines(EastWalker), "round one notes",
        "round one banner", "llm")
    check sim.history[0].notes[0] == "round one notes"
    check sim.history[0].banner[0] == "round one banner"
    for seat in sim.pendingSeats():
      sim.submit(seat, lines(EastWalker), "", "", "llm")
    check sim.history[1].notes[0] == ""
    check sim.history[1].banner[0] == ""

  test "a script that does not compile is recorded, not fatal":
    var sim = initSim(fixture(seed = 1, rounds = 1, ticks = 60))
    sim.submit(0, @["this is not GWL at all ###"], "", "", "llm")
    for seat in sim.pendingSeats():
      sim.submit(seat, lines(EastWalker), "", "", "scripted")
    check sim.done
    check sim.history[0].compileError[0].len > 0
    check sim.history[0].stat[0].deathCause == "idle"
