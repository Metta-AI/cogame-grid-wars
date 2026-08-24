## Grid harness for the painter baseline (design note, phase 20 step 5).
##
## Sweeps painter's three free parameters — the turn-run length, the rival
## trigger distance and the bomb cadence — and reports each candidate's mean
## `score` against `sentry` (the note's criterion: "painter beats sentry on
## mean score over ten seeds") and against `bomber`, four seats, one round of
## 400 ticks, over the assertion seeds 1..10 AND a held-out 11..40 so the
## pick is not an artefact of the ten seeds the test asserts on.
##
##   nim r --hints:off -d:release --path:src tools/tune_painter.nim
##
## Result kept (data/warriors/painter.gwl): run 22, a two-cell trigger, at
## most one bomb per fuse —
##   run= 22 reach=2 cadence=  6  sentry[1..10]  39.67  sentry[11..40]  33.85
##                                bomber[1..10]  -7.10  bomber[11..40]  -9.46
## against the note's original guess (run 6, one-cell trigger, no cadence):
##   run=  6 reach=1 cadence=  6  sentry[1..10]  -3.90  sentry[11..40]  -3.80
##                                bomber[1..10] -30.80  bomber[11..40] -54.80

import std/[algorithm, strformat, strutils]
import gridwars/[llm, sim]

type Candidate = object
  run: int          ## steps before the walk turns
  reach: int        ## rival trigger distance in cells (1 or 2)
  cadence: int      ## bomb at most every `cadence` ticks (1 = whenever it can)

proc source(c: Candidate): seq[string] =
  result.add("# painter - claim ground, turn away from walls, bomb a rival that leans in.")
  result.add("var dx = 1")
  result.add("var dy = 0")
  result.add("var t = 0")
  result.add("var run = 0")
  result.add("var last = 0 - " & $c.cadence)
  result.add("proc wall(ax, ay) =")
  result.add("  var c = check(ax, ay)")
  result.add("  return c == BOMB or c == CORPSE or who(ax, ay) != 0")
  result.add("proc rival() =")
  for (ax, ay) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
    result.add(&"  if who({ax}, {ay}) != 0 and who({ax}, {ay}) != ID:")
    result.add("    return 1")
  if c.reach >= 2:
    for (ax, ay) in [(2, 0), (-2, 0), (0, 2), (0, -2), (1, 1), (1, -1),
                     (-1, 1), (-1, -1)]:
      result.add(&"  if who({ax}, {ay}) != 0 and who({ax}, {ay}) != ID:")
      result.add("    return 1")
  result.add("  return 0")
  result.add("while true:")
  result.add("  if rival() == 1 and energy() >= BOMBCOST and tick() - last >= " &
    $c.cadence & ":")   ## the shipped file writes the winning 6 as MAXFUSE + 1
  result.add("    last = tick()")
  result.add("    bomb()")
  result.add("  else:")
  result.add("    place()")
  result.add("  if wall(dx, dy):")
  result.add("    t = dx")
  result.add("    dx = 0 - dy")
  result.add("    dy = t")
  result.add("    run = 0")
  result.add("  else:")
  result.add("    move(dx, dy)")
  result.add("    run = run + 1")
  result.add(&"    if run == {c.run}:")
  result.add("      run = 0")
  result.add("      t = dx")
  result.add("      dx = 0 - dy")
  result.add("      dy = t")

proc fixture(seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.rounds = 1
  result.ticks = 400
  result.sampled = true
  for index in 0 ..< Seats:
    result.players.add(PlayerConfig(name: "P" & $(index + 1)))
    result.tokens.add("t" & $index)

type Outcome = object
  score: float        ## mean score of the two candidate seats
  faults, stalls, illegal, refused: int

proc duel(candidate: seq[string], opponent: seq[string],
    seeds: Slice[int]): Outcome =
  ## Seats [candidate, opponent, candidate, opponent] over `seeds`.
  var total = 0.0
  for seed in seeds:
    var sim = initSim(fixture(seed))
    while not sim.done:
      for seat in sim.pendingSeats():
        let script = if seat mod 2 == 0: candidate else: opponent
        sim.submit(seat, script, "", "", "scripted")
    total += sim.score(0) + sim.score(2)
    for record in sim.history:
      for seat in [0, 2]:
        if record.stat[seat].faultLine != 0: inc result.faults
        result.stalls += record.stat[seat].stalls
        result.illegal += record.stat[seat].illegal
        result.refused += record.stat[seat].refused
  result.score = total / float(2 * (seeds.b - seeds.a + 1))

when isMainModule:
  let sentry = warriorLines(skSentry)
  let bomber = warriorLines(skBomber)
  var rows: seq[(float, string, Candidate)]
  for run in [6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 29, 32, 36, 40]:
    for reach in [1, 2]:
      for cadence in [3, 6, 12]:
        let candidate = Candidate(run: run, reach: reach, cadence: cadence)
        let lines = candidate.source()
        if lines.len > MaxScriptLines:
          continue
        discard compile(lines)
        let vsSentry = duel(lines, sentry, 1 .. 10)
        let vsBomber = duel(lines, bomber, 1 .. 10)
        let holdSentry = duel(lines, sentry, 11 .. 40)
        let holdBomber = duel(lines, bomber, 11 .. 40)
        let clean = vsSentry.faults + vsSentry.stalls + vsSentry.illegal +
          vsSentry.refused + vsBomber.faults + vsBomber.stalls +
          vsBomber.illegal + vsBomber.refused
        let line = &"run={run:>3} reach={reach} cadence={cadence:>3}  " &
          &"sentry[1..10] {vsSentry.score:>7.2f}  sentry[11..40] {holdSentry.score:>7.2f}" &
          &"  bomber[1..10] {vsBomber.score:>7.2f}  bomber[11..40] {holdBomber.score:>7.2f}" &
          &"  lines={lines.len:>3} clean={clean == 0}"
        echo line
        if clean == 0 and holdSentry.faults + holdSentry.stalls +
            holdSentry.illegal + holdSentry.refused + holdBomber.faults +
            holdBomber.stalls + holdBomber.illegal + holdBomber.refused == 0:
          rows.add((min(vsSentry.score, holdSentry.score), line, candidate))
  rows.sort(proc (a, b: (float, string, Candidate)): int =
    cmp(b[0], a[0]))
  echo "\n---- best by WORST of the two seed sets, legality-clean only ----"
  for index in 0 ..< min(8, rows.len):
    echo rows[index][1]
  if rows.len > 0:
    echo "\n---- winning source ----"
    for line in rows[0][2].source():
      echo line
