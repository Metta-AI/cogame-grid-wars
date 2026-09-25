# The Grid Wars warrior language (GWL v1)

A Grid Wars policy submits a **program**, through the player socket. This page is the language reference player policies may include in their prompts, plus the three warriors that ship inside the image.

```
GWL — the warrior language

A warrior is a program. It runs from the top; wrap your behaviour in
`while true:` or it will run off the end, stop acting and die to the idle
rule. Indentation is 2 spaces per level and is significant. `#` starts a
comment. INTEGERS ONLY — there are no floats, no strings, no tables.

STATEMENTS
  var NAME = EXPR            declare and initialise
  NAME = EXPR                assign
  NAME[EXPR] = EXPR          assign into an array
  if EXPR: / elif EXPR: / else:    with an indented block
  while EXPR:                with break and continue
  for NAME in A ..< B:       also `A .. B` and `for NAME in ARRAY:`
  proc NAME(p1, p2) =        globals visible, parameters by value
  return EXPR                or bare `return`
  discard EXPR               evaluate and drop
  move(dx, dy)  place()  bomb()  wait()      ACTIONS — each ENDS your tick

EXPRESSIONS
  integers, true/false, names, [a, b, c], a[i], calls, ( ), unary - and not,
  and infix  *  div  mod  +  -  ==  !=  <  <=  >  >=  and  or
  with Nim's precedence. `and`/`or` short-circuit. Booleans are a distinct
  type: `if 1:` is a fault. `div`/`mod` also exist as calls: `mod(a, b)`.

BUILTINS
  check(dx, dy)  BOMB (-1) live bomb, CORPSE (-2) corpse, FOG (-3) outside
                 the 9x9 window around you, else the tile owner 1..4 or
                 EMPTY (0)
  who(dx, dy)    the id 1..4 of the LIVING warrior standing there, else 0;
                 FOG outside the window
  x()  y()       your coordinates, 0..29
  tiles()  energy()  tick()
  alive(id)      1 if warrior id is alive, else 0
  rand(n)        0..n-1 from your own seeded stream; n <= 0 is a fault
  abs(a)  min(a,b)  max(a,b)  len(a)  xor(a,b)  shl(a,b)  shr(a,b)

CONSTANTS
  BOMB -1, CORPSE -2, FOG -3, EMPTY 0, ID (your warrior id), gridSize 30,
  MAXFUSE 5, BOMBCOST (the energy a bomb costs this episode)

ACTIONS
  move(dx, dy) is ONE STEP: dx and dy are each -1, 0 or 1 and not both 0.
  Any other offset is an ILLEGAL action: the tick is spent and nothing
  happens. place() claims the cell you stand on. bomb() plants a bomb on
  the cell you stand on; it is refused if you cannot afford it or a bomb is
  already there. wait() does nothing. Executing an action SUSPENDS your
  program there; next tick it resumes on the next line.

LIMITS
  at most 120 lines, 100 characters a line, 4000 characters, 4000 AST
  nodes, 32 procs, blocks nested 8 deep; at most 2000 VM instructions per
  tick (running out is a STALL: the tick counts as wait() and you resume
  where you were), call depth 64, 4096 live array elements.

FAULTS kill your warrior on the spot, with the line number reported back to
you: divide or modulo by zero, an array index out of range, an undefined
variable or proc, a wrong argument count, a type mismatch, call depth
exceeded, the allocation limit, rand(n <= 0), integer overflow. An illegal
move, a refused bomb, a blocked move and a stall are NOT faults.
```

## Reply contract

A player policy submits one JSON action through the socket:

```json
{"script": ["var dx = 1", "var dy = 0", "while true:", "  place()", "  move(dx, dy)"],
 "notes": "private, fed back to you next round",
 "banner": "one line the spectators see"}
```

`script` is canonically an ARRAY OF LINES — that removes the single most common JSON failure, a literal newline inside a string — but a single string with newlines is accepted, markdown fences are stripped, and trailing prose after the closing brace is ignored. `script` is capped at 120 lines of 100 characters and 4000 characters in total, `notes` at 600 characters and `banner` at 80, all cut on rune boundaries. The game compiles every submitted program. An invalid or missing action uses the built-in `sentry` warrior for that round and increments `results.fallbacks`.

## The three shipped warriors

`PLAYER_SCRIPTED=painter|bomber|sentry` seats one of these instead of an LLM. They are also the no-credentials fallback, which is why offline certification always completes.

### painter — claim ground, turn away from walls, bomb a rival that leans in

```
# painter - claim ground, turn away from walls, bomb a rival that leans in.
var dx = 1
var dy = 0
var t = 0
var run = 0
var last = 0 - MAXFUSE
proc wall(ax, ay) =
  var c = check(ax, ay)
  return c == BOMB or c == CORPSE or who(ax, ay) != 0
proc rival() =
  if who(1, 0) != 0 and who(1, 0) != ID:
    return 1
  if who(-1, 0) != 0 and who(-1, 0) != ID:
    return 1
  if who(0, 1) != 0 and who(0, 1) != ID:
    return 1
  if who(0, -1) != 0 and who(0, -1) != ID:
    return 1
  if who(2, 0) != 0 and who(2, 0) != ID:
    return 1
  if who(-2, 0) != 0 and who(-2, 0) != ID:
    return 1
  if who(0, 2) != 0 and who(0, 2) != ID:
    return 1
  if who(0, -2) != 0 and who(0, -2) != ID:
    return 1
  if who(1, 1) != 0 and who(1, 1) != ID:
    return 1
  if who(1, -1) != 0 and who(1, -1) != ID:
    return 1
  if who(-1, 1) != 0 and who(-1, 1) != ID:
    return 1
  if who(-1, -1) != 0 and who(-1, -1) != ID:
    return 1
  return 0
while true:
  if rival() == 1 and energy() >= BOMBCOST and tick() - last > MAXFUSE:
    last = tick()
    bomb()
  else:
    place()
  if wall(dx, dy):
    t = dx
    dx = 0 - dy
    dy = t
    run = 0
  else:
    move(dx, dy)
    run = run + 1
    if run == 22:
      run = 0
      t = dx
      dx = 0 - dy
      dy = t
```

### bomber — mine the ground you leave, fence yourself in

```
# bomber - mine the ground you leave, fence yourself in, paint inside the fence.
var dx = 1
var dy = 0
var t = 0
var step = 0
while true:
  step = step + 1
  if energy() >= BOMBCOST and mod(step, 3) == 0:
    bomb()
  else:
    place()
  if check(dx, dy) == BOMB or check(dx, dy) == CORPSE or who(dx, dy) != 0:
    t = dx
    dx = 0 - dy
    dy = t
  else:
    move(dx, dy)
```

### sentry — the always-legal fallback, and the round-1 seed script every LLM seat is shown

```
# sentry - the fallback warrior: walk a box and paint it.
var dx = 1
var dy = 0
var t = 0
var run = 0
while true:
  place()
  if check(dx, dy) == BOMB or check(dx, dy) == CORPSE or who(dx, dy) != 0:
    t = dx
    dx = 0 - dy
    dy = t
    run = 0
  else:
    move(dx, dy)
    run = run + 1
    if run == 8:
      run = 0
      t = dx
      dx = 0 - dy
      dy = t
```
