## Pure game rules for Grid Wars. No IO, no networking, no LLM — the
## server, the tests and the wasm replay viewer all drive this same module.
##
## A `Sim` is one whole episode: a best-of series of rounds, each round a
## submission phase (four warrior programs arrive) followed by a battle on
## an empty 30x30 toroidal board. The battle is a pure function of
## (scripts, round seed, config) — integer-only, no hash-table iteration,
## no wall clock — so `replayMatch` re-derives every tick in the browser
## from the recorded events alone and checks its own work against the
## recorded digest.

import std/[json, math, random, strutils, unicode], types, gwl

export types, gwl

const
  Seats* = 4
  ## `Grid` (30) and `Cells` (900) come from gwl, which sim re-exports.
  SpawnCells* = [(4, 4), (25, 4), (4, 25), (25, 25)]
  BombFuse* = 5
  IdleLimit* = 50
  EnergyStart* = 12
  EnergyCap* = 60
  StepInstructions* = 2000
  MaxScriptLines* = 120
  MaxLineChars* = 100
  MaxScriptChars* = 4000
  MaxNotesLen* = 600
  MaxBannerLen* = 80
  SurviveBonus* = 100
  KillBonus* = 50
  MinRounds* = 1
  MaxRounds* = 12
  MinTicks* = 20
  MaxTicks* = 1200
  KeyframeEvery* = 25            ## viewer grid keyframe + tile-curve cadence
  PacingBudgetMs* = 20_000
  CogNames* = [
    "Sprocket", "Gizmo", "Ratchet", "Widget", "Bolt",
    "Piston", "Flywheel", "Rivet", "Tinker", "Gasket"
  ]
  ColorNames* = ["red", "blue", "green", "yellow"]

type
  Phase* = enum
    phSubmit = "submit"    ## waiting for this round's four warrior programs
    phBattle = "battle"    ## the battle is running (synchronous)
    phDone = "done"

  Warrior* = object
    alive*: bool
    x*, y*, energy*, idle*, tiles*, kills*, selfKills*: int
    illegal*, blocked*, refused*, stalls*, peakTiles*, ticksLived*: int
    deathTick*: int          ## -1 while alive
    deathCause*: string      ## "" | "bomb" | "idle" | "fault"
    faultLine*: int
    faultText*: string
    line*: int               ## the source line it executed this tick (viewer)
    action*: ActionKind
    halted*: bool
    vm*: GwlVm

  Bomb* = object
    x*, y*, fuse*, seat*: int

  Board* = object
    owner*: array[Cells, int8]     ## 0 = unclaimed, 1..4
    corpse*: array[Cells, bool]
    bombs*: seq[Bomb]              ## kept sorted by y*30+x

  RoundRecord* = object
    seed*: int
    spawn*: array[Seats, int]      ## seat -> spawn cell index
    scripts*: array[Seats, seq[string]]
    origin*: array[Seats, string]  ## "llm" | "retry" | "fallback" | "scripted"
    compileError*: array[Seats, string]
    banner*, notes*: array[Seats, string]
    stat*: array[Seats, SeatStat]
    curve*: array[Seats, seq[int]]
    ticksPlayed*: int
    ticks*: int
    reason*: string                ## "horizon" | "lastStanding" | "wipeout"
    digest*: string                ## FNV-1a 64 of the final board + warriors, hex
    ascii*: string                 ## the final board, for the next prompt
    finalX*, finalY*: array[Seats, int]
    finalAlive*: array[Seats, bool]

  Sim* = object
    config*: GameConfig
    names*: seq[string]
    round*: int                    ## 1-based; the round being submitted for
    roundsPlayed*: int
    phase*: Phase
    pending*: array[Seats, bool]   ## submission still due this round
    scripts*: array[Seats, seq[string]]   ## the live round's sources
    origin*: array[Seats, string]
    compileError*: array[Seats, string]
    banner*: array[Seats, string]
    notes*: array[Seats, string]
    history*: seq[RoundRecord]
    done*: bool
    reason*: string                ## "complete" | "deadline"
    events*: seq[GameEvent]

# ---- Setup ------------------------------------------------------------------

proc tableNames*(players: seq[PlayerConfig], seed: int): seq[string] =
  ## Policy display names never reach the arena: every seat plays under an
  ## anonymous cog name, drawn deterministically from the seed so replays
  ## and the live board agree.
  var rng = initRand(int64(seed) * 6779 + 31)
  var pool = @CogNames
  rng.shuffle(pool)
  for index in 0 ..< players.len:
    if index < pool.len:
      result.add(pool[index])
    else:
      result.add("Cog " & $(index + 1))

proc sampleEpisode*(config: GameConfig): GameConfig =
  ## Fits the series into the episode's limits. Idempotent: a config that
  ## already carries the cap (a replay being re-read) is untouched.
  result = config
  if result.sampled:
    return
  result.rounds = max(min(config.rounds, MaxRounds), MinRounds)
  result.ticks = max(min(config.ticks, MaxTicks), MinTicks)
  result.bombCost = max(min(config.bombCost, 60), 0)
  result.roundDelayMs =
    min(config.roundDelayMs, PacingBudgetMs div max(result.rounds, 1))
  result.sampled = true

proc roundSeed*(sim: Sim, round: int): int =
  ## The round's derived seed. It is logged in the `round` event, which is
  ## what makes the engine RNG server-side AND auditable.
  sim.config.seed * 1000003 + round * 97

proc spawnFor(seed: int): array[Seats, int] =
  ## A seeded permutation of the four fixed corners, seat -> cell index.
  var rng = initRand(int64(seed) * 2654435761 + 12345)
  var order = @[0, 1, 2, 3]
  rng.shuffle(order)
  for seat in 0 ..< Seats:
    let corner = SpawnCells[order[seat]]
    result[seat] = corner[1] * Grid + corner[0]

proc addEvent(sim: var Sim, event: GameEvent) =
  sim.events.add(event)

proc blankEvent(kind: EventKind): GameEvent =
  GameEvent(kind: kind, round: -1, seat: -1, seed: -1, ticks: -1, lines: -1,
    ticksPlayed: -1)

proc openRound(sim: var Sim) =
  ## Opens the submission phase: the round's seed and spawn permutation are
  ## fixed and logged BEFORE the first tick of the round can run.
  sim.phase = phSubmit
  for seat in 0 ..< Seats:
    sim.pending[seat] = true
    sim.origin[seat] = ""
    sim.compileError[seat] = ""
  var event = blankEvent(evRound)
  event.round = sim.round
  event.seed = sim.roundSeed(sim.round)
  event.ticks = sim.config.ticks
  let spawn = spawnFor(event.seed)
  for seat in 0 ..< Seats:
    event.spawn.add(spawn[seat])
  sim.addEvent(event)

const SeedScript* = @[
  "# sentry - the fallback warrior: walk a box and paint it.",
  "var dx = 1",
  "var dy = 0",
  "var t = 0",
  "var run = 0",
  "while true:",
  "  place()",
  "  if check(dx, dy) == BOMB or check(dx, dy) == CORPSE or who(dx, dy) != 0:",
  "    t = dx",
  "    dx = 0 - dy",
  "    dy = t",
  "    run = 0",
  "  else:",
  "    move(dx, dy)",
  "    run = run + 1",
  "    if run == 8:",
  "      run = 0",
  "      t = dx",
  "      dx = 0 - dy",
  "      dy = t"
]

proc initSim*(config: GameConfig): Sim =
  if config.players.len != Seats:
    raise newException(GridWarsError,
      "grid wars needs exactly " & $Seats & " players")
  if config.rounds < MinRounds:
    raise newException(GridWarsError,
      "rounds must be at least " & $MinRounds)
  if config.ticks < MinTicks:
    raise newException(GridWarsError, "ticks must be at least " & $MinTicks)
  result = Sim(config: config, names: tableNames(config.players, config.seed))
  result.round = 1
  for seat in 0 ..< Seats:
    result.scripts[seat] = SeedScript
  var start = blankEvent(evStart)
  start.text = "grid-wars"
  result.addEvent(start)
  result.openRound()

# ---- Queries ----------------------------------------------------------------

proc pendingSeats*(sim: Sim): seq[int] =
  if sim.done:
    return
  for seat in 0 ..< Seats:
    if sim.pending[seat]:
      result.add(seat)

proc score*(sim: Sim, seat: int): float =
  if sim.roundsPlayed == 0:
    return 0.0
  var total = 0.0
  for record in sim.history:
    total += record.stat[seat].roundScore
  total / sim.roundsPlayed.float

proc roundsWon*(sim: Sim, seat: int): int =
  for record in sim.history:
    var best = record.stat[0].raw
    var unique = true
    for other in 1 ..< Seats:
      if record.stat[other].raw > best:
        best = record.stat[other].raw
        unique = true
      elif record.stat[other].raw == best:
        unique = false
    if unique and record.stat[seat].raw == best:
      inc result

proc totalTiles*(sim: Sim, seat: int): int =
  for record in sim.history:
    result += record.stat[seat].tiles

# ---- The battle -------------------------------------------------------------

type
  BattleState = object
    board: Board
    warrior: array[Seats, Warrior]
    bombCost: int
    ticks: int

  FrameSink = object
    ## Optional per-tick frame collector. The battle runs identically with
    ## and without it; the frames are only ever built by a viewer.
    want: bool
    frames: seq[JsonNode]
    prevGrid: string
    names: seq[string]
    record: RoundRecord
    round, rounds, roundsPlayed: int
    series: seq[seq[SeatStat]]
    seriesScore: array[Seats, float]

proc seatName(sink: FrameSink, seat: int): string =
  if seat >= 0 and seat < sink.names.len: sink.names[seat] else: "Seat " & $seat

proc tickPriority*(tick: int): array[Seats, int] =
  ## The tick's priority order. It rotates every tick, so no seat has a
  ## structural first-mover advantage, and it is the ONLY tie-break in the
  ## bomb, place and move passes.
  for k in 0 ..< Seats:
    result[k] = (k + tick) mod Seats

proc cellOf(x, y: int): int = y * Grid + x

proc wrap(value: int): int = ((value mod Grid) + Grid) mod Grid

proc fnvStart(): uint64 = 0xcbf29ce484222325'u64

proc fnvByte(hash: var uint64, value: uint8) =
  hash = hash xor uint64(value)
  hash = hash * 0x100000001b3'u64

proc fnvInt(hash: var uint64, value: int) =
  var v = cast[uint64](value)
  for _ in 0 ..< 8:
    fnvByte(hash, uint8(v and 0xFF'u64))
    v = v shr 8

proc digestOf(state: BattleState): string =
  var hash = fnvStart()
  for cell in 0 ..< Cells:
    fnvByte(hash, uint8(state.board.owner[cell]))
    fnvByte(hash, (if state.board.corpse[cell]: 1'u8 else: 0'u8))
  for bomb in state.board.bombs:
    fnvInt(hash, bomb.x)
    fnvInt(hash, bomb.y)
    fnvInt(hash, bomb.fuse)
    fnvInt(hash, bomb.seat)
  for seat in 0 ..< Seats:
    let w = state.warrior[seat]
    fnvByte(hash, (if w.alive: 1'u8 else: 0'u8))
    fnvInt(hash, w.x)
    fnvInt(hash, w.y)
    fnvInt(hash, w.energy)
    fnvInt(hash, w.idle)
    fnvInt(hash, w.tiles)
    fnvInt(hash, w.kills)
    fnvInt(hash, w.selfKills)
  toHex(hash, 16).toLowerAscii()

proc gridString(board: Board): string =
  result = newString(Cells)
  for cell in 0 ..< Cells:
    result[cell] = (if board.owner[cell] == 0: '.'
                    else: char(ord('0') + int(board.owner[cell])))

proc asciiBoard(board: Board): string =
  ## `.` unclaimed, `1`-`4` tile owner, `*` live bomb, `x` corpse.
  var cells = newString(Cells)
  for cell in 0 ..< Cells:
    cells[cell] = (if board.owner[cell] == 0: '.'
                   else: char(ord('0') + int(board.owner[cell])))
  for cell in 0 ..< Cells:
    if board.corpse[cell]:
      cells[cell] = 'x'
  for bomb in board.bombs:
    cells[cellOf(bomb.x, bomb.y)] = '*'
  var lines: seq[string]
  for y in 0 ..< Grid:
    lines.add(cells[y * Grid ..< (y + 1) * Grid])
  lines.join("\n")

proc viewFor(state: BattleState, seat, tick: int): BoardView =
  ## The board exactly as it stood at the end of the previous tick, for
  ## every seat in the decision pass.
  result.owner = state.board.owner
  result.corpse = state.board.corpse
  for bomb in state.board.bombs:
    result.bomb[cellOf(bomb.x, bomb.y)] = true
  for other in 0 ..< Seats:
    if state.warrior[other].alive:
      result.occupant[cellOf(state.warrior[other].x, state.warrior[other].y)] =
        int8(other + 1)
      result.alive[other + 1] = true
  result.x = state.warrior[seat].x
  result.y = state.warrior[seat].y
  result.id = seat + 1
  result.energy = state.warrior[seat].energy
  result.tiles = state.warrior[seat].tiles
  result.tick = tick
  result.bombCost = state.bombCost

proc recount(state: var BattleState) =
  for seat in 0 ..< Seats:
    state.warrior[seat].tiles = 0
  for cell in 0 ..< Cells:
    let owner = int(state.board.owner[cell])
    if owner > 0:
      inc state.warrior[owner - 1].tiles
  for seat in 0 ..< Seats:
    if state.warrior[seat].tiles > state.warrior[seat].peakTiles:
      state.warrior[seat].peakTiles = state.warrior[seat].tiles

proc unpaint(state: var BattleState, seat: int) =
  for cell in 0 ..< Cells:
    if int(state.board.owner[cell]) == seat + 1:
      state.board.owner[cell] = 0

proc sortBombs(board: var Board) =
  ## Insertion sort on the cell index: tiny, stable, and free of any
  ## library ordering the wasm build might disagree about.
  for index in 1 ..< board.bombs.len:
    let bomb = board.bombs[index]
    let key = cellOf(bomb.x, bomb.y)
    var position = index - 1
    while position >= 0 and
        cellOf(board.bombs[position].x, board.bombs[position].y) > key:
      board.bombs[position + 1] = board.bombs[position]
      dec position
    board.bombs[position + 1] = bomb

proc rawScore(stat: SeatStat): int =
  stat.tiles + (if stat.alive: SurviveBonus else: 0) +
    KillBonus * stat.kills - KillBonus * stat.selfKills

proc seatJson(sink: FrameSink, state: BattleState, seat, tick: int,
    pending: bool): JsonNode =
  let w = state.warrior[seat]
  var stat = SeatStat(tiles: w.tiles, alive: w.alive, kills: w.kills,
    selfKills: w.selfKills)
  %*{
    "name": sink.seatName(seat),
    "seat": seat,
    "color": seat,
    "id": seat + 1,
    "score": sink.seriesScore[seat],
    "raw": rawScore(stat),
    "tiles": w.tiles,
    "peakTiles": w.peakTiles,
    "energy": w.energy,
    "alive": w.alive,
    "x": w.x,
    "y": w.y,
    "idle": w.idle,
    "kills": w.kills,
    "selfKills": w.selfKills,
    "line": w.line,
    "action": $w.action,
    "banner": sink.record.banner[seat],
    "deathCause": w.deathCause,
    "faultLine": w.faultLine,
    "faultText": w.faultText,
    "origin": sink.record.origin[seat],
    "scriptLines": sink.record.scripts[seat].len,
    "pending": pending
  }

proc seriesJson(sink: FrameSink): JsonNode =
  result = newJArray()
  for round in sink.series:
    var row = newJArray()
    for stat in round:
      row.add(%*{
        "raw": stat.raw,
        "tiles": stat.tiles,
        "kills": stat.kills,
        "alive": stat.alive,
        "roundScore": stat.roundScore
      })
    result.add(row)

proc emitFrame(sink: var FrameSink, state: BattleState, phase: string,
    tick: int, blast: seq[int], log: seq[string], keyframe: bool,
    focus: int, pending: array[Seats, bool], gameDone: bool,
    reason: string, withScripts: bool) =
  if not sink.want:
    return
  var seats = newJArray()
  for seat in 0 ..< Seats:
    seats.add(sink.seatJson(state, seat, tick, pending[seat]))
  var frame = %*{
    "seats": seats,
    "round": sink.round,
    "rounds": sink.rounds,
    "tick": tick,
    "ticks": sink.record.ticks,
    "roundsPlayed": sink.roundsPlayed,
    "phase": phase,
    "focus": focus,
    "series": sink.seriesJson(),
    "gameDone": gameDone,
    "reason": reason
  }
  let grid = gridString(state.board)
  if keyframe or sink.prevGrid.len != Cells:
    frame["grid"] = %grid
  else:
    var delta = newJArray()
    for cell in 0 ..< Cells:
      if grid[cell] != sink.prevGrid[cell]:
        delta.add(%*[cell, $grid[cell]])
    frame["gridDelta"] = delta
  sink.prevGrid = grid
  var bombs = newJArray()
  for bomb in state.board.bombs:
    bombs.add(%*{"x": bomb.x, "y": bomb.y, "fuse": bomb.fuse,
      "seat": bomb.seat})
  frame["bombs"] = bombs
  var corpses = newJArray()
  for cell in 0 ..< Cells:
    if state.board.corpse[cell]:
      corpses.add(%*[cell mod Grid, cell div Grid])
  frame["corpses"] = corpses
  var blastNode = newJArray()
  for cell in blast:
    blastNode.add(%*[cell mod Grid, cell div Grid])
  frame["blast"] = blastNode
  var logNode = newJArray()
  for line in log:
    logNode.add(%line)
  frame["log"] = logNode
  if withScripts:
    var scripts = newJArray()
    for seat in 0 ..< Seats:
      var lines = newJArray()
      for line in sink.record.scripts[seat]:
        lines.add(%line)
      scripts.add(lines)
    frame["scripts"] = scripts
  sink.frames.add(frame)

proc focusSeat(state: BattleState): int =
  var best = -1
  for seat in 0 ..< Seats:
    if best < 0 or state.warrior[seat].tiles > state.warrior[best].tiles:
      best = seat
  max(best, 0)

proc runBattle(record: var RoundRecord, config: GameConfig,
    sink: var FrameSink) =
  ## Runs one whole battle from the record's scripts, seed and spawn, and
  ## fills in the record's stats, curve, digest and final board. With
  ## `sink.want` it also emits one frame per tick plus the round-end frame.
  var state = BattleState(bombCost: config.bombCost, ticks: record.ticks)
  var noPending: array[Seats, bool]
  ## The frame builder reads the round's scripts, origins and banners; they
  ## are fixed for the whole battle, so snapshot them up front.
  sink.record = record
  for seat in 0 ..< Seats:
    var program: GwlProgram
    var compiled = true
    try:
      program = compile(record.scripts[seat])
    except GwlCompileError:
      compiled = false
    state.warrior[seat] = Warrior(
      alive: true,
      x: record.spawn[seat] mod Grid,
      y: record.spawn[seat] div Grid,
      energy: EnergyStart,
      deathTick: -1,
      vm: newVm(program, seat, record.seed),
      halted: not compiled
    )
    record.curve[seat] = @[]
  if sink.want:
    sink.prevGrid = ""
    ## The four submission frames: an empty board and the programs as they
    ## arrived, which is the pane a spectator reads the new warrior in.
    var arriving: array[Seats, bool]
    for seat in 0 ..< Seats:
      arriving[seat] = true
    for seat in 0 ..< Seats:
      arriving[seat] = false
      sink.emitFrame(state, "submit", -1, @[],
        @[sink.seatName(seat) & " submits a " & $record.scripts[seat].len & "-line warrior" &
          (if record.compileError[seat].len > 0:
             " (rejected: " & record.compileError[seat] & ")" else: "")],
        true, seat, arriving, false, "", true)

  var ticksPlayed = 0
  var reason = "horizon"
  for tick in 0 ..< record.ticks:
    var log: seq[string]
    var blast: seq[int]
    let order = tickPriority(tick)
    var prevX, prevY: array[Seats, int]
    for seat in 0 ..< Seats:
      prevX[seat] = state.warrior[seat].x
      prevY[seat] = state.warrior[seat].y

    ## 2. Decision pass — reads the board of tick t-1, mutates nothing.
    var intent: array[Seats, GwlAction]
    var faulted: array[Seats, bool]
    for k in 0 ..< Seats:
      let seat = order[k]
      if not state.warrior[seat].alive or state.warrior[seat].halted:
        intent[seat] = GwlAction(kind: akNone, line: 0)
        state.warrior[seat].action = akNone
        continue
      let view = viewFor(state, seat, tick)
      let action = state.warrior[seat].vm.step(view, StepInstructions)
      intent[seat] = action
      state.warrior[seat].action = action.kind
      if action.line > 0:
        state.warrior[seat].line = action.line
      if state.warrior[seat].vm.fault.line > 0:
        faulted[seat] = true
        state.warrior[seat].faultLine = state.warrior[seat].vm.fault.line
        state.warrior[seat].faultText = state.warrior[seat].vm.fault.message
      elif state.warrior[seat].vm.halted:
        state.warrior[seat].halted = true
      elif action.stalled:
        inc state.warrior[seat].stalls
      elif action.kind == akMove:
        if action.dx < -1 or action.dx > 1 or action.dy < -1 or action.dy > 1 or
            (action.dx == 0 and action.dy == 0):
          inc state.warrior[seat].illegal
          intent[seat] = GwlAction(kind: akWait, line: action.line)
          log.add(sink.seatName(seat) & " wastes a tick on an illegal move")

    ## 3. Bomb pass.
    for k in 0 ..< Seats:
      let seat = order[k]
      if not state.warrior[seat].alive or intent[seat].kind != akBomb:
        continue
      let cell = cellOf(state.warrior[seat].x, state.warrior[seat].y)
      var occupied = false
      for bomb in state.board.bombs:
        if cellOf(bomb.x, bomb.y) == cell:
          occupied = true
          break
      if state.warrior[seat].energy >= state.bombCost and not occupied:
        state.board.bombs.add(Bomb(x: state.warrior[seat].x,
          y: state.warrior[seat].y, fuse: BombFuse, seat: seat))
        state.board.sortBombs()
        state.warrior[seat].energy -= state.bombCost
      else:
        inc state.warrior[seat].refused

    ## 4. Place pass.
    for k in 0 ..< Seats:
      let seat = order[k]
      if not state.warrior[seat].alive or intent[seat].kind != akPlace:
        continue
      state.board.owner[cellOf(state.warrior[seat].x, state.warrior[seat].y)] =
        int8(seat + 1)

    ## 5. Move pass.
    var occupant: array[Cells, int8]
    var bombAt: array[Cells, bool]
    for seat in 0 ..< Seats:
      if state.warrior[seat].alive:
        occupant[cellOf(state.warrior[seat].x, state.warrior[seat].y)] =
          int8(seat + 1)
    for bomb in state.board.bombs:
      bombAt[cellOf(bomb.x, bomb.y)] = true
    for k in 0 ..< Seats:
      let seat = order[k]
      if not state.warrior[seat].alive or intent[seat].kind != akMove:
        continue
      let fromCell = cellOf(state.warrior[seat].x, state.warrior[seat].y)
      let targetX = wrap(state.warrior[seat].x + intent[seat].dx)
      let targetY = wrap(state.warrior[seat].y + intent[seat].dy)
      let target = cellOf(targetX, targetY)
      if bombAt[target] or state.board.corpse[target] or occupant[target] != 0:
        inc state.warrior[seat].blocked
      else:
        occupant[fromCell] = 0
        occupant[target] = int8(seat + 1)
        state.warrior[seat].x = targetX
        state.warrior[seat].y = targetY

    ## 6. Fuse pass.
    for index in 0 ..< state.board.bombs.len:
      dec state.board.bombs[index].fuse

    ## 7. Detonation pass — the plus of every bomb at fuse 0, closed over
    ## every bomb the growing blast reaches, resolved as one wave.
    var detonating = newSeq[bool](state.board.bombs.len)
    var anyDetonating = false
    for index, bomb in state.board.bombs:
      if bomb.fuse <= 0:
        detonating[index] = true
        anyDetonating = true
    if anyDetonating:
      var inBlast: array[Cells, bool]
      var growing = true
      while growing:
        growing = false
        for index, bomb in state.board.bombs:
          if not detonating[index]:
            continue
          for offset in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)]:
            let cell = cellOf(wrap(bomb.x + offset[0]), wrap(bomb.y + offset[1]))
            if not inBlast[cell]:
              inBlast[cell] = true
              growing = true
        for index, bomb in state.board.bombs:
          if not detonating[index] and inBlast[cellOf(bomb.x, bomb.y)]:
            detonating[index] = true
            growing = true
      ## Attribution runs over the PRE-blast bomb list, in ascending cell
      ## index (the list is kept sorted), so "whose bomb killed whom" is a
      ## pure function of the board.
      var killerOf: array[Seats, int]
      for seat in 0 ..< Seats:
        killerOf[seat] = -1
        if not state.warrior[seat].alive:
          continue
        let cell = cellOf(state.warrior[seat].x, state.warrior[seat].y)
        if not inBlast[cell]:
          continue
        for index, bomb in state.board.bombs:
          if not detonating[index]:
            continue
          var covers = false
          for offset in [(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1)]:
            if cellOf(wrap(bomb.x + offset[0]), wrap(bomb.y + offset[1])) == cell:
              covers = true
              break
          if covers:
            killerOf[seat] = bomb.seat
            break
      for cell in 0 ..< Cells:
        if inBlast[cell]:
          blast.add(cell)
          state.board.owner[cell] = 0
      var survivors: seq[Bomb]
      for bomb in state.board.bombs:
        if not inBlast[cellOf(bomb.x, bomb.y)]:
          survivors.add(bomb)
      state.board.bombs = survivors
      for seat in 0 ..< Seats:
        if not state.warrior[seat].alive or killerOf[seat] < 0:
          continue
        state.warrior[seat].alive = false
        state.warrior[seat].deathCause = "bomb"
        state.warrior[seat].deathTick = tick
        state.board.corpse[cellOf(state.warrior[seat].x,
          state.warrior[seat].y)] = true
        let victim = sink.seatName(seat)
        if killerOf[seat] == seat:
          inc state.warrior[seat].selfKills
          log.add(victim & " is caught in their own blast at (" &
            $state.warrior[seat].x & "," & $state.warrior[seat].y & ")")
        else:
          inc state.warrior[killerOf[seat]].kills
          log.add(sink.seatName(killerOf[seat]) & "'s bomb kills " & victim &
            " at (" & $state.warrior[seat].x & "," &
            $state.warrior[seat].y & ")")

    ## 8. Idle pass.
    for seat in 0 ..< Seats:
      if not state.warrior[seat].alive:
        continue
      if state.warrior[seat].x == prevX[seat] and
          state.warrior[seat].y == prevY[seat]:
        inc state.warrior[seat].idle
      else:
        state.warrior[seat].idle = 0
      if state.warrior[seat].idle >= IdleLimit:
        state.warrior[seat].alive = false
        state.warrior[seat].deathCause = "idle"
        state.warrior[seat].deathTick = tick
        state.board.corpse[cellOf(state.warrior[seat].x,
          state.warrior[seat].y)] = true
        log.add(sink.seatName(seat) & " idles out at tick " & $tick)

    ## 9. Fault pass.
    for seat in 0 ..< Seats:
      if not state.warrior[seat].alive or not faulted[seat]:
        continue
      state.warrior[seat].alive = false
      state.warrior[seat].deathCause = "fault"
      state.warrior[seat].deathTick = tick
      state.board.corpse[cellOf(state.warrior[seat].x,
        state.warrior[seat].y)] = true
      log.add(sink.seatName(seat) & "'s warrior faulted at line " &
        $state.warrior[seat].faultLine & ": " & state.warrior[seat].faultText)

    ## 10. Bookkeeping.
    for seat in 0 ..< Seats:
      if not state.warrior[seat].alive and state.warrior[seat].deathTick == tick:
        state.unpaint(seat)
    state.recount()
    for seat in 0 ..< Seats:
      if state.warrior[seat].alive:
        state.warrior[seat].energy = min(EnergyCap,
          state.warrior[seat].energy + 1 + state.warrior[seat].tiles div 60)
        inc state.warrior[seat].ticksLived
    if tick mod KeyframeEvery == 0:
      for seat in 0 ..< Seats:
        record.curve[seat].add(state.warrior[seat].tiles)

    ticksPlayed = tick + 1
    var aliveCount = 0
    for seat in 0 ..< Seats:
      if state.warrior[seat].alive:
        inc aliveCount

    if sink.want:
      sink.emitFrame(state, "battle", tick, blast, log,
        tick mod KeyframeEvery == 0, focusSeat(state), noPending, false, "",
        false)

    ## 11. Round end test.
    if tick + 1 == record.ticks:
      reason = "horizon"
      break
    if aliveCount == 1:
      reason = "lastStanding"
      break
    if aliveCount == 0:
      reason = "wipeout"
      break

  for seat in 0 ..< Seats:
    record.curve[seat].add(state.warrior[seat].tiles)

  record.ticksPlayed = ticksPlayed
  record.reason = reason
  record.digest = digestOf(state)
  record.ascii = asciiBoard(state.board)
  var rawTotal = 0
  for seat in 0 ..< Seats:
    let w = state.warrior[seat]
    var stat = SeatStat(
      tiles: w.tiles, peakTiles: w.peakTiles, kills: w.kills,
      selfKills: w.selfKills, alive: w.alive, deathTick: w.deathTick,
      deathCause: w.deathCause, faultLine: w.faultLine,
      faultText: w.faultText, illegal: w.illegal, blocked: w.blocked,
      refused: w.refused, stalls: w.stalls, ticksLived: w.ticksLived
    )
    stat.raw = rawScore(stat)
    rawTotal += stat.raw
    record.stat[seat] = stat
    record.finalX[seat] = w.x
    record.finalY[seat] = w.y
    record.finalAlive[seat] = w.alive
  for seat in 0 ..< Seats:
    record.stat[seat].roundScore =
      record.stat[seat].raw.float - rawTotal.float / Seats.float

  if sink.want:
    var series = sink.series
    var row: seq[SeatStat]
    for seat in 0 ..< Seats:
      row.add(record.stat[seat])
    series.add(row)
    sink.series = series
    inc sink.roundsPlayed
    for seat in 0 ..< Seats:
      var total = 0.0
      for played in sink.series:
        total += played[seat].roundScore
      sink.seriesScore[seat] = total / sink.roundsPlayed.float
    sink.record = record
    var log: seq[string]
    var best = 0
    for seat in 1 ..< Seats:
      if record.stat[seat].raw > record.stat[best].raw:
        best = seat
    log.add("Round " & $sink.round & " — " & sink.seatName(best) &
      " " & $record.stat[best].tiles & " tiles, " &
      formatFloat(record.stat[best].roundScore, ffDecimal, 1))
    sink.emitFrame(state, "roundEnd", ticksPlayed, @[], log, true,
      focusSeat(state), noPending, false, "", false)

proc playRound*(record: var RoundRecord, config: GameConfig) =
  ## Runs one battle from an explicit record — its scripts, seed, spawn
  ## cells and tick horizon — and fills in its stats, curve, digest and
  ## final board. This is the whole arena, and it is what the series, the
  ## frame builder and the replay all drive.
  var sink = FrameSink(want: false)
  runBattle(record, config, sink)

# ---- Submission and the series ---------------------------------------------

proc capScript*(lines: seq[string]): seq[string] =
  ## Line-wise first, then rune boundaries: at most MaxScriptLines lines of
  ## at most MaxLineChars runes, joined source at most MaxScriptChars runes.
  var used = 0
  for line in lines:
    if result.len >= MaxScriptLines:
      break
    var text = line.replace("\t", "  ")
    while text.len > 0 and text[^1] in {' ', '\r'}:
      text.setLen(text.len - 1)
    if text.runeLen > MaxLineChars:
      text = text.runeSubStr(0, MaxLineChars)
    if used + text.runeLen + 1 > MaxScriptChars:
      break
    used += text.runeLen + 1
    result.add(text)

proc settle(sim: var Sim, reason: string) =
  sim.done = true
  sim.reason = reason
  sim.phase = phDone
  var event = blankEvent(evEnd)
  event.round = sim.roundsPlayed
  event.text = reason
  sim.addEvent(event)

proc currentRecord(sim: Sim): RoundRecord =
  result.seed = sim.roundSeed(sim.round)
  result.spawn = spawnFor(result.seed)
  result.ticks = sim.config.ticks
  for seat in 0 ..< Seats:
    result.scripts[seat] = sim.scripts[seat]
    result.origin[seat] = sim.origin[seat]
    result.compileError[seat] = sim.compileError[seat]
    result.banner[seat] = sim.banner[seat]
    result.notes[seat] = sim.notes[seat]

proc runRound(sim: var Sim) =
  ## The fourth submission seals the round: the battle runs synchronously,
  ## the `battle` event lands, and the next round opens (or the series
  ## settles).
  sim.phase = phBattle
  var record = sim.currentRecord()
  var sink = FrameSink(want: false, names: sim.names)
  runBattle(record, sim.config, sink)
  sim.history.add(record)
  inc sim.roundsPlayed
  var event = blankEvent(evBattle)
  event.round = sim.round
  event.ticksPlayed = record.ticksPlayed
  event.reason = record.reason
  event.digest = record.digest
  for seat in 0 ..< Seats:
    event.stats.add(record.stat[seat])
    event.curve.add(record.curve[seat])
  sim.addEvent(event)
  if sim.roundsPlayed >= sim.config.rounds:
    sim.settle("complete")
  else:
    inc sim.round
    sim.openRound()

proc submit*(sim: var Sim, seat: int, lines: seq[string],
    notes, banner, origin: string, rejected = "") =
  ## `seat` submits its warrior for the live round. The script is capped
  ## and compiled here — the sim is the authority, not the caller — and the
  ## fourth submission seals the round and runs the whole battle.
  if sim.done:
    raise newException(GridWarsError, "the episode is over")
  if seat < 0 or seat >= Seats:
    raise newException(GridWarsError, "bad seat: " & $seat)
  if not sim.pending[seat]:
    raise newException(GridWarsError,
      sim.names[seat] & " has already submitted this round")
  var script = capScript(lines)
  var compileError = ""
  try:
    discard compile(script)
  except GwlCompileError as error:
    ## Defensive: the LLM layer compiles before it submits and falls back
    ## to `sentry` on failure, so this only fires for a caller that skipped
    ## it. The warrior is left with no program, which halts it immediately.
    compileError = cutRunes(error.msg, 300)
    script = @[]
  if script.len == 0 and compileError.len == 0:
    compileError = "empty script"
  if compileError.len == 0 and rejected.len > 0:
    ## A fallback: the seat's own reply was rejected and `sentry` is
    ## standing in. Record WHY, so the feed and the next prompt can say so.
    compileError = cutRunes(rejected, 300)
  sim.scripts[seat] = script
  sim.origin[seat] = (if origin.len > 0: origin else: "llm")
  sim.compileError[seat] = compileError
  sim.banner[seat] = cutRunes(banner.replace("\n", " ").strip(), MaxBannerLen)
  if notes.len > 0:
    sim.notes[seat] = cutRunes(notes.strip(), MaxNotesLen)
  sim.pending[seat] = false
  var event = blankEvent(evSubmit)
  event.round = sim.round
  event.seat = seat
  event.script = script
  event.lines = script.len
  event.origin = sim.origin[seat]
  event.compileError = compileError
  event.banner = sim.banner[seat]
  event.scripted = sim.origin[seat] == "scripted"
  event.text = sim.notes[seat]
  sim.addEvent(event)
  if sim.pendingSeats().len == 0:
    sim.runRound()

proc endEarly*(sim: var Sim) =
  ## Stop now, between rounds. The platform kills an episode that outlives
  ## its timeout and keeps NOTHING, so a short honest series always beats a
  ## long one that never lands. Scores use the rounds actually played.
  if sim.done:
    return
  sim.settle("deadline")

# ---- Results ----------------------------------------------------------------

proc winnerSeat*(sim: Sim): int =
  result = 0
  for seat in 1 ..< Seats:
    let a = (sim.score(seat), sim.roundsWon(seat), sim.totalTiles(seat))
    let b = (sim.score(result), sim.roundsWon(result), sim.totalTiles(result))
    if a > b:
      result = seat

proc resultsJson*(sim: Sim): JsonNode =
  var names = newJArray()
  var scores = newJArray()
  var tiles = newJArray()
  var won = newJArray()
  var kills = newJArray()
  var deaths = newJArray()
  var faults = newJArray()
  var fallbacks = newJArray()
  for seat in 0 ..< Seats:
    ## Results are platform-facing: the league attributes scores by POLICY
    ## name, never by the anonymous alias the seat played under.
    names.add(%sim.config.players[seat].name)
    scores.add(%sim.score(seat))
    tiles.add(%sim.totalTiles(seat))
    won.add(%sim.roundsWon(seat))
    var seatKills = 0
    var seatDeaths = 0
    var seatFaults = 0
    var seatFallbacks = 0
    for record in sim.history:
      seatKills += record.stat[seat].kills
      if not record.stat[seat].alive:
        inc seatDeaths
      if record.stat[seat].deathCause == "fault":
        inc seatFaults
      if record.origin[seat] == "fallback":
        inc seatFallbacks
    kills.add(%seatKills)
    deaths.add(%seatDeaths)
    faults.add(%seatFaults)
    fallbacks.add(%seatFallbacks)
  var reasons = newJArray()
  for record in sim.history:
    reasons.add(%record.reason)
  %*{
    "names": names,
    "scores": scores,
    "tiles": tiles,
    "roundsWon": won,
    "kills": kills,
    "deaths": deaths,
    "faults": faults,
    "fallbacks": fallbacks,
    "rounds": sim.roundsPlayed,
    "maxRounds": sim.config.rounds,
    "ticks": sim.config.ticks,
    "roundReasons": reasons,
    "winner": (if sim.roundsPlayed > 0:
      sim.config.players[sim.winnerSeat()].name else: ""),
    "reason": (if sim.done: sim.reason else: "")
  }

# ---- Frames -----------------------------------------------------------------

proc buildFrames(config: GameConfig, names: seq[string],
    records: seq[RoundRecord], rounds: int, done: bool,
    reason: string): seq[JsonNode] =
  var sink = FrameSink(want: true, names: names, rounds: rounds)
  for index in 0 ..< records.len:
    var record = records[index]
    sink.round = index + 1
    runBattle(record, config, sink)
  if result.len == 0:
    discard
  result = sink.frames
  if result.len > 0 and done:
    result[^1]["gameDone"] = %true
    result[^1]["reason"] = %reason
    result[^1]["phase"] = %"done"

proc frameStates*(sim: Sim): seq[JsonNode] =
  buildFrames(sim.config, sim.names, sim.history, sim.config.rounds,
    sim.done, sim.reason)

proc framesJson*(sim: Sim): JsonNode =
  result = newJArray()
  for frame in sim.frameStates():
    result.add(frame)

proc liveStateJson*(sim: Sim): JsonNode =
  ## The live spectator snapshot: the same frame shape the replay viewer
  ## reads, so one renderer serves both. It is the tail of the completed
  ## rounds with the live round's pending flags laid over it.
  let frames = sim.frameStates()
  if frames.len > 0:
    result = frames[^1]
  else:
    var seats = newJArray()
    for seat in 0 ..< Seats:
      seats.add(%*{
        "name": sim.names[seat], "seat": seat, "color": seat, "id": seat + 1,
        "score": 0.0, "raw": 0, "tiles": 0, "peakTiles": 0,
        "energy": EnergyStart, "alive": true, "x": 0, "y": 0, "idle": 0,
        "kills": 0, "selfKills": 0, "line": 0, "action": "none",
        "banner": "", "deathCause": "", "faultLine": 0, "faultText": "",
        "origin": "", "scriptLines": sim.scripts[seat].len, "pending": true
      })
    var grid = newString(Cells)
    for cell in 0 ..< Cells:
      grid[cell] = '.'
    result = %*{
      "seats": seats, "grid": grid, "bombs": newJArray(),
      "corpses": newJArray(), "blast": newJArray(), "series": newJArray(),
      "log": newJArray(), "ticks": sim.config.ticks, "tick": -1,
      "focus": 0, "phase": "submit"
    }
  result["round"] = %sim.round
  result["rounds"] = %sim.config.rounds
  result["roundsPlayed"] = %sim.roundsPlayed
  result["gameDone"] = %sim.done
  result["reason"] = %sim.reason
  if not sim.done:
    result["phase"] = %"submit"
    var seats = result["seats"]
    for seat in 0 ..< Seats:
      seats[seat]["pending"] = %sim.pending[seat]
    var scripts = newJArray()
    for seat in 0 ..< Seats:
      var lines = newJArray()
      for line in sim.scripts[seat]:
        lines.add(%line)
      scripts.add(lines)
    result["scripts"] = scripts

# ---- Event JSON -------------------------------------------------------------

proc eventToJson*(event: GameEvent): JsonNode =
  result = %*{"kind": $event.kind}
  if event.round >= 0:
    result["round"] = %event.round
  case event.kind
  of evStart:
    discard
  of evRound:
    result["seed"] = %event.seed
    result["ticks"] = %event.ticks
    var spawn = newJArray()
    for cell in event.spawn:
      spawn.add(%cell)
    result["spawn"] = spawn
  of evSubmit:
    result["seat"] = %event.seat
    var script = newJArray()
    for line in event.script:
      script.add(%line)
    result["script"] = script
    result["lines"] = %event.lines
    result["origin"] = %event.origin
    result["compileError"] = %event.compileError
    result["banner"] = %event.banner
    result["scripted"] = %event.scripted
  of evBattle:
    result["ticksPlayed"] = %event.ticksPlayed
    result["reason"] = %event.reason
    result["digest"] = %event.digest
    var stats = newJArray()
    for stat in event.stats:
      stats.add(statJson(stat))
    result["stats"] = stats
    var curve = newJArray()
    for series in event.curve:
      var row = newJArray()
      for value in series:
        row.add(%value)
      curve.add(row)
    result["curve"] = curve
  of evEnd:
    discard
  if event.text.len > 0:
    result["text"] = %event.text

proc eventFromJson*(node: JsonNode): GameEvent =
  result = GameEvent(
    kind: parseEnum[EventKind](node["kind"].getStr()),
    round: node{"round"}.getInt(-1),
    seat: node{"seat"}.getInt(-1),
    seed: node{"seed"}.getInt(-1),
    ticks: node{"ticks"}.getInt(-1),
    lines: node{"lines"}.getInt(-1),
    origin: node{"origin"}.getStr(""),
    compileError: node{"compileError"}.getStr(""),
    banner: node{"banner"}.getStr(""),
    scripted: node{"scripted"}.getBool(false),
    text: node{"text"}.getStr(""),
    ticksPlayed: node{"ticksPlayed"}.getInt(-1),
    reason: node{"reason"}.getStr(""),
    digest: node{"digest"}.getStr("")
  )
  if node.hasKey("spawn"):
    for cell in node["spawn"]:
      result.spawn.add(cell.getInt())
  if node.hasKey("script"):
    for line in node["script"]:
      result.script.add(line.getStr())
  if node.hasKey("stats"):
    for stat in node["stats"]:
      result.stats.add(statFromJson(stat))
  if node.hasKey("curve"):
    for series in node["curve"]:
      var row: seq[int]
      for value in series:
        row.add(value.getInt())
      result.curve.add(row)

# ---- Replay -----------------------------------------------------------------

proc recordsFromEvents*(events: seq[GameEvent]): seq[RoundRecord] =
  ## Rebuilds one RoundRecord per round from the recorded log. The per-tick
  ## history is NOT in the log: it is re-derived from the seed, the spawn
  ## permutation and the scripts, which is the whole point.
  var current: RoundRecord
  var open = false
  for event in events:
    case event.kind
    of evRound:
      if open:
        result.add(current)
      current = RoundRecord()
      open = true
      current.seed = event.seed
      current.ticks = event.ticks
      for seat in 0 ..< Seats:
        if seat < event.spawn.len:
          current.spawn[seat] = event.spawn[seat]
    of evSubmit:
      if open and event.seat >= 0 and event.seat < Seats:
        current.scripts[event.seat] = event.script
        current.origin[event.seat] = event.origin
        current.compileError[event.seat] = event.compileError
        current.banner[event.seat] = event.banner
        current.notes[event.seat] = event.text
    of evBattle:
      if open:
        current.ticksPlayed = event.ticksPlayed
        current.reason = event.reason
        current.digest = event.digest
        for seat in 0 ..< Seats:
          if seat < event.stats.len:
            current.stat[seat] = event.stats[seat]
        result.add(current)
        open = false
    else:
      discard

proc replayMatch*(config: GameConfig, events: seq[GameEvent]): seq[JsonNode] =
  ## Re-derives every tick of every round from the recorded events and
  ## asserts the recomputed digest equals the recorded one. A mismatch
  ## raises, which the wasm module reports as `data-replay-error` rather
  ## than silently drawing a different game.
  let records = recordsFromEvents(events)
  var names = tableNames(config.players, config.seed)
  var rounds = config.rounds
  var done = false
  var reason = ""
  for event in events:
    if event.kind == evEnd:
      done = true
      reason = event.text
  var sink = FrameSink(want: true, names: names, rounds: rounds)
  for index in 0 ..< records.len:
    var record = records[index]
    let recorded = record.digest
    sink.round = index + 1
    runBattle(record, config, sink)
    if recorded.len > 0 and record.digest != recorded:
      raise newException(GridWarsError,
        "round " & $(index + 1) & " does not re-derive: digest " &
        record.digest & " != recorded " & recorded)
  result = sink.frames
  if result.len > 0 and done:
    result[^1]["gameDone"] = %true
    result[^1]["reason"] = %reason
    result[^1]["phase"] = %"done"

proc replayJson*(sim: Sim): JsonNode =
  ## The `gridwars.replay.v1` payload the server writes. Self-sufficient:
  ## aliases, policy names, the full config, the seed and every derived
  ## round seed, the spawn permutation, every script and the results. The
  ## per-tick history is NOT here — the viewer re-derives it and checks the
  ## recorded digest.
  var names = newJArray()
  for name in sim.names:
    names.add(%name)
  var policyNames = newJArray()
  for player in sim.config.players:
    policyNames.add(%player.name)
  var events = newJArray()
  for event in sim.events:
    events.add(event.eventToJson())
  %*{
    "protocol": "gridwars.replay.v1",
    "names": names,
    "policyNames": policyNames,
    "config": {
      "rounds": sim.config.rounds,
      "ticks": sim.config.ticks,
      "bombCost": sim.config.bombCost,
      "seed": sim.config.seed,
      "sampled": true
    },
    "events": events,
    "results": sim.resultsJson()
  }

# ---- Per-seat observation ---------------------------------------------------

proc boardAscii*(sim: Sim, round: int): string =
  ## The final board of `round` (1-based) as the 30x30 map a seat is shown.
  if round < 1 or round > sim.history.len:
    return ""
  sim.history[round - 1].ascii

proc seriesTable(sim: Sim): string =
  var lines: seq[string]
  lines.add("round | warrior | tiles | kills | alive | raw | round score")
  for index, record in sim.history:
    for seat in 0 ..< Seats:
      let stat = record.stat[seat]
      lines.add($(index + 1) & " | " & sim.names[seat] & " | " & $stat.tiles &
        " | " & $stat.kills & " | " & (if stat.alive: "yes" else: "no") &
        " | " & $stat.raw & " | " &
        formatFloat(stat.roundScore, ffDecimal, 1))
  lines.add("")
  lines.add("running series score (higher is better, the four sum to zero):")
  for seat in 0 ..< Seats:
    lines.add("  " & sim.names[seat] & ": " &
      formatFloat(sim.score(seat), ffDecimal, 1))
  lines.join("\n")

proc numberedScript(lines: seq[string]): string =
  var numbered: seq[string]
  for index, line in lines:
    numbered.add(align($(index + 1), 3) & " | " & line)
  numbered.join("\n")

proc seatObservation*(sim: Sim, seat: int): string =
  ## Everything this seat may see, and nothing else. There is no code path
  ## here that reads another seat's `scripts`, `notes` or `banner`, and no
  ## path that reads a policy name or the round seed — sealing is enforced
  ## by this function, not by convention (tests/test_prompt.nim).
  result.add("Round " & $sim.round & " of " & $sim.config.rounds &
    ". You are " & sim.names[seat] & ", warrior id " & $(seat + 1) &
    " (" & ColorNames[seat] & ").\n")
  result.add("Each battle runs up to " & $sim.config.ticks &
    " ticks. A bomb costs " & $sim.config.bombCost & " energy and has a " &
    $BombFuse & "-tick fuse. " & $IdleLimit &
    " ticks without moving kills you. You get " & $StepInstructions &
    " VM instructions per tick before the tick is spent.\n\n")

  if sim.history.len == 0:
    result.add("No round has been played yet. You are shown the SENTRY " &
      "seed warrior below; replace it with something better.\n\n")
  else:
    let last = sim.history[^1]
    let stat = last.stat[seat]
    result.add("YOUR LAST ROUND (round " & $sim.history.len & "):\n")
    if last.compileError[seat].len > 0:
      result.add("  your script did NOT compile: " & last.compileError[seat] &
        "\n")
    result.add("  ticks survived " & $stat.ticksLived & " of " &
      $last.ticksPlayed & "; " &
      (if stat.alive: "you were alive at the end"
       else: "you died at tick " & $stat.deathTick & " (" & stat.deathCause &
         ")") & "\n")
    if stat.faultLine > 0:
      result.add("  YOUR WARRIOR FAULTED at line " & $stat.faultLine & ": " &
        stat.faultText & "\n")
    result.add("  tiles " & $stat.tiles & " (peak " & $stat.peakTiles &
      "), kills " & $stat.kills & ", selfKills " & $stat.selfKills & "\n")
    result.add("  illegal " & $stat.illegal & ", blocked " & $stat.blocked &
      ", refused bombs " & $stat.refused & ", stalls " & $stat.stalls & "\n")
    var curve: seq[string]
    for value in last.curve[seat]:
      curve.add($value)
    result.add("  your tiles every " & $KeyframeEvery & " ticks: " &
      curve.join(", ") & "\n\n")
    result.add("SERIES SO FAR:\n" & sim.seriesTable() & "\n\n")
    result.add("THE BOARD AT THE END OF ROUND " & $sim.history.len &
      " (. unclaimed, 1-4 owner, * live bomb, x corpse):\n")
    result.add(last.ascii & "\n")
    for other in 0 ..< Seats:
      result.add(sim.names[other] & " (id " & $(other + 1) & ") finished at (" &
        $last.finalX[other] & "," & $last.finalY[other] & "), " &
        (if last.finalAlive[other]: "alive" else: "dead") & "\n")
    result.add("\n")

  result.add("YOUR CURRENT WARRIOR (this is what you are editing):\n")
  result.add(numberedScript(sim.scripts[seat]) & "\n\n")
  result.add("YOUR PRIVATE NOTES:\n" &
    (if sim.notes[seat].len > 0: sim.notes[seat] else: "(none)") & "\n\n")

proc playerStateJson*(sim: Sim, seat: int): JsonNode =
  ## The redacted per-seat frame the player socket receives: its own
  ## warrior, its own script, its own notes, and the PUBLIC tile counts.
  ## Never another seat's source.
  var tiles = newJArray()
  var alive = newJArray()
  for other in 0 ..< Seats:
    if sim.history.len > 0:
      tiles.add(%sim.history[^1].stat[other].tiles)
      alive.add(%sim.history[^1].stat[other].alive)
    else:
      tiles.add(%0)
      alive.add(%true)
  var script = newJArray()
  for line in sim.scripts[seat]:
    script.add(%line)
  var own = %*{
    "id": seat + 1,
    "color": ColorNames[seat],
    "score": sim.score(seat),
    "roundsWon": sim.roundsWon(seat),
    "tiles": (if sim.history.len > 0: sim.history[^1].stat[seat].tiles else: 0),
    "notes": sim.notes[seat],
    "script": script
  }
  if sim.history.len > 0:
    own["lastRound"] = statJson(sim.history[^1].stat[seat])
  %*{
    "type": "state",
    "slot": seat,
    "name": sim.names[seat],
    "seat": own,
    "tiles": tiles,
    "aliveLastRound": alive,
    "round": sim.round,
    "rounds": sim.config.rounds,
    "roundsPlayed": sim.roundsPlayed,
    "ticks": sim.config.ticks,
    "done": sim.done,
    "reason": sim.reason
  }
