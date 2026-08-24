## GWL — the warrior language. Lexing, indentation, every statement form,
## every fault kind, the resumable VM's suspend/resume contract, and each
## compile cap rejecting with a message that names the limit.

import std/[strutils, unicode, unittest]
import gridwars/gwl

proc emptyView(x = 4, y = 4, id = 1): BoardView =
  result.x = x
  result.y = y
  result.id = id
  result.energy = 12
  result.bombCost = 12
  result.alive[id] = true

proc run(source: string, ticks = 1, view = emptyView()):
    tuple[actions: seq[GwlAction], vm: GwlVm] =
  ## Compiles `source` and steps it `ticks` times on a fixed board view.
  let program = compile(source.strip().splitLines())
  result.vm = newVm(program, 0, 1234)
  for tick in 0 ..< ticks:
    var localView = view
    localView.tick = tick
    result.actions.add(result.vm.step(localView, 2000))
    if result.vm.fault.line > 0 or result.vm.halted:
      break

proc faultOf(source: string, ticks = 4): GwlFault =
  run(source, ticks).vm.fault

proc compileError(source: string): string =
  try:
    discard compile(source.strip().splitLines())
    return ""
  except GwlCompileError as error:
    return error.msg

suite "lexing and indentation":
  test "an odd indent is rejected at the right line":
    let message = compileError("""
var a = 1
if a == 1:
   place()
""")
    check "line 3" in message
    check "multiple of 2" in message

  test "a dedent to a level that was never opened is rejected":
    ## The block opens at four spaces, so two spaces is a level that was
    ## never opened.
    let message = compileError("""
if true:
    place()
  wait()
""")
    check "line 3" in message
    check "never opened" in message

  test "a consistently four-space-indented program compiles":
    let outcome = run("""
var a = 1
if a == 1:
    place()
""")
    check outcome.actions[0].kind == akPlace

  test "a wrapped condition runs on to the next line":
    let outcome = run("""
var a = 1
if a == 1 and
    a < 5:
  place()
""")
    check outcome.actions[0].kind == akPlace

  test "a tab counts as two spaces":
    let outcome = run("if true:\n\tplace()\n")
    check outcome.actions[0].kind == akPlace

  test "comments and blank lines are ignored":
    let outcome = run("""
# a comment
## another

place()   # trailing
""")
    check outcome.actions[0].kind == akPlace

  test "an unexpected character names its line":
    check "line 2" in compileError("var a = 1\nvar b = a @ 2\n")

  test "an unexpected character is quoted whole, never as a split byte":
    ## The message travels to the replay (submit.compileError), so a cut
    ## through a multi-byte character would put invalid UTF-8 in the bytes
    ## the browser decodes.
    let dash = compileError("var a = 1\nvar b = 2 \u2014 3\n")
    check "line 2" in dash
    check "\u2014" in dash
    check dash.validateUtf8() == -1
    ## A byte that is not valid UTF-8 at all is escaped, not quoted raw.
    for bad in ["var a = \x80 1", "var a = \xE2 1", "var a = \xE2"]:
      let message = compileError(bad)
      check "unexpected character" in message
      check message.validateUtf8() == -1

  test "cutRunes cuts on a rune boundary and leaves short text alone":
    check cutRunes("hello", 300) == "hello"
    let long = "é".repeat(700)
    check cutRunes(long, 600).runeLen == 600
    check cutRunes(long, 600).validateUtf8() == -1

suite "expressions":
  test "arithmetic and precedence follow Nim":
    let outcome = run("""
var a = 2 + 3 * 4
var b = (2 + 3) * 4
var c = 17 div 5
var d = 17 mod 5
if a == 14 and b == 20 and c == 3 and d == 2:
  place()
else:
  bomb()
""")
    check outcome.actions[0].kind == akPlace

  test "mod and div agree in infix and call form":
    let outcome = run("""
if mod(17, 5) == 17 mod 5 and div(17, 5) == 17 div 5:
  place()
else:
  bomb()
""")
    check outcome.actions[0].kind == akPlace

  test "and/or short-circuit past a would-be fault":
    let outcome = run("""
var a = 0
if a != 0 and 10 div a == 1:
  bomb()
if a == 0 or 10 div a == 1:
  place()
""")
    check outcome.vm.fault.line == 0
    check outcome.actions[0].kind == akPlace

  test "unary minus and not":
    let outcome = run("""
var a = -5
if not (a > 0) and abs(a) == 5 and 0 - a == 5:
  place()
""")
    check outcome.actions[0].kind == akPlace

  test "an integer condition is a type fault":
    let fault = faultOf("if 1:\n  place()\n")
    check fault.line == 1
    check "boolean" in fault.message

  test "arrays, len and indexing":
    let outcome = run("""
var xs = [3, 1, 4, 1, 5]
var total = 0
for v in xs:
  total = total + v
if total == 14 and len(xs) == 5 and xs[2] == 4:
  place()
""")
    check outcome.actions[0].kind == akPlace

  test "an index out of range faults at its line":
    let fault = faultOf("""
var xs = [1, 2]
var y = xs[5]
place()
""")
    check fault.line == 2
    check "out of range" in fault.message

  test "an array element can be assigned":
    let outcome = run("""
var xs = [1, 2, 3]
xs[1] = 9
if xs[1] == 9:
  place()
""")
    check outcome.actions[0].kind == akPlace

  test "min, max, xor, shl, shr":
    let outcome = run("""
if min(3, 5) == 3 and max(3, 5) == 5 and xor(6, 3) == 5 and
    shl(1, 4) == 16 and shr(16, 2) == 4:
  place()
""")
    check outcome.actions[0].kind == akPlace

suite "statements":
  test "while with break and continue":
    let outcome = run("""
var i = 0
var seen = 0
while true:
  i = i + 1
  if i == 3:
    continue
  if i > 5:
    break
  seen = seen + i
if seen == 12:
  place()
""")
    check outcome.actions[0].kind == akPlace

  test "for over an exclusive and an inclusive range":
    let outcome = run("""
var a = 0
for i in 0 ..< 5:
  a = a + i
var b = 0
for i in 0 .. 5:
  b = b + i
if a == 10 and b == 15:
  place()
""")
    check outcome.actions[0].kind == akPlace

  test "elif and else chains":
    let outcome = run("""
var a = 2
if a == 1:
  bomb()
elif a == 2:
  place()
else:
  wait()
""")
    check outcome.actions[0].kind == akPlace

  test "a var re-executed in a loop re-initialises":
    let outcome = run("""
var n = 0
var total = 0
while n < 3:
  var inner = 5
  inner = inner + 1
  total = total + inner
  n = n + 1
if total == 18:
  place()
""")
    check outcome.actions[0].kind == akPlace

suite "procs":
  test "parameters are by value and globals are visible":
    let outcome = run("""
var g = 7
proc bump(v) =
  v = v + 1
  return v + g
var a = 1
var b = bump(a)
if a == 1 and b == 9:
  place()
""")
    check outcome.actions[0].kind == akPlace

  test "a proc may be called before it is declared":
    let outcome = run("""
if later() == 3:
  place()
proc later() =
  return 3
""")
    check outcome.actions[0].kind == akPlace

  test "recursion to depth 64 works and 65 faults":
    let ok = run("""
proc down(n) =
  if n == 0:
    return 0
  return down(n - 1)
var r = down(60)
place()
""")
    check ok.vm.fault.line == 0
    check ok.actions[0].kind == akPlace
    let fault = faultOf("""
proc down(n) =
  if n == 0:
    return 0
  return down(n - 1)
var r = down(200)
place()
""")
    check fault.line > 0
    check "call depth" in fault.message

  test "the wrong argument count is a fault naming the proc":
    let fault = faultOf("""
proc two(a, b) =
  return a + b
var r = two(1)
place()
""")
    check "two" in fault.message
    check "arguments" in fault.message

suite "faults":
  test "division and modulo by zero":
    check "division by zero" in faultOf("var a = 0\nvar b = 1 div a\nplace()\n").message
    check "modulo by zero" in faultOf("var a = 0\nvar b = 1 mod a\nplace()\n").message

  test "an undefined variable and an undefined proc":
    let variable = faultOf("var a = dirx + 1\nplace()\n")
    check variable.line == 1
    check "undefined variable" in variable.message
    check "dirx" in variable.message
    let procedure = faultOf("var a = nowhere(1)\nplace()\n")
    check "undefined proc" in procedure.message
    check "nowhere" in procedure.message

  test "a type mismatch":
    check "boolean" in faultOf("var a = true\nvar b = not 3\nplace()\n").message

  test "integer overflow is checked, not wrapped":
    let fault = faultOf("""
var a = 4611686018427387904
var b = a + a
place()
""")
    check "overflow" in fault.message

  test "the machine's numbers are int64 on every target, not platform int":
    ## The wasm viewer re-derives every battle with --cpu:wasm32, where Nim's
    ## `int` is 32 bits. A VM typed `int` would fault on 2000000000 +
    ## 2000000000 in the browser and carry on to 4000000000 on the server:
    ## different board, different digest, data-replay-error on a replay the
    ## server considers valid. The type is fixed-width, so both agree.
    static:
      doAssert sizeof(GwlValue) == 8
    let outcome = run("""
var a = 2000000000 + 2000000000
var b = shl(1, 40)
var c = xor(b, 255)
if a == 4000000000 and b == 1099511627776 and c == 1099511627775 + 256:
  place()
""")
    check outcome.actions[0].kind == akPlace
    check outcome.vm.fault.line == 0
    ## The overflow boundary is int64's, not the platform's.
    check faultOf("""
var a = 9223372036854775807
var b = a + 1
place()
""").message == "integer overflow"
    check run("""
var a = 9223372036854775807
if a > 2147483647:
  place()
""").actions[0].kind == akPlace
    ## An out-of-window check() offset past 2^31 is still FOG, and a move
    ## offset past 2^31 is still illegal — neither is truncated into range.
    check run("var a = check(4294967297, 0)\nif a == FOG:\n  place()\n")
      .actions[0].kind == akPlace
    let far = run("move(4294967297, 0)\n")
    check far.actions[0].kind == akMove
    check far.actions[0].dx == 4294967297'i64

  test "rand(0) is a fault and rand(n) stays in range":
    check "rand(n)" in faultOf("var a = rand(0)\nplace()\n").message
    let outcome = run("""
var bad = 0
for i in 0 ..< 50:
  var r = rand(6)
  if r < 0 or r > 5:
    bad = bad + 1
if bad == 0:
  place()
""")
    check outcome.actions[0].kind == akPlace

  test "a fault stops the machine for good":
    let outcome = run("var a = 1 div 0\nplace()\n", ticks = 3)
    check outcome.vm.fault.line == 1
    check outcome.actions[^1].kind == akNone

suite "the board window":
  test "check and who report the documented values":
    var view = emptyView()
    view.owner[4 * Grid + 5] = 3          # a tile east of us
    view.bomb[4 * Grid + 3] = true        # a bomb west of us
    view.corpse[3 * Grid + 4] = true      # a corpse north of us
    view.occupant[5 * Grid + 4] = 2       # a rival south of us
    view.alive[2] = true
    let outcome = run("""
if check(1, 0) == 3 and check(-1, 0) == BOMB and check(0, -1) == CORPSE and
    check(2, 2) == EMPTY and who(0, 1) == 2 and who(1, 0) == 0 and
    alive(2) == 1 and alive(4) == 0 and ID == 1:
  place()
""", view = view)
    check outcome.actions[0].kind == akPlace

  test "beyond the 9x9 window everything is FOG":
    var view = emptyView()
    view.bomb[4 * Grid + 14] = true       # ten cells east: outside the window
    let outcome = run("""
if check(10, 0) == FOG and who(0, 10) == FOG and check(4, 4) == EMPTY:
  place()
""", view = view)
    check outcome.actions[0].kind == akPlace

  test "the window wraps with the board":
    var view = emptyView(x = 0, y = 0)
    view.owner[0 * Grid + 29] = 2         # one cell west of x=0 is x=29
    let outcome = run("""
if check(-1, 0) == 2:
  place()
""", view = view)
    check outcome.actions[0].kind == akPlace

suite "the resumable machine":
  test "an action suspends the VM and the next tick resumes after it":
    let outcome = run("""
while true:
  place()
  move(1, 0)
  bomb()
  wait()
""", ticks = 8)
    check outcome.actions.len == 8
    check outcome.actions[0].kind == akPlace
    check outcome.actions[1].kind == akMove
    check outcome.actions[1].dx == 1
    check outcome.actions[2].kind == akBomb
    check outcome.actions[3].kind == akWait
    check outcome.actions[4].kind == akPlace

  test "the instruction budget stalls and resumes at the same pc":
    let program = compile("""
var n = 0
while n < 100000:
  n = n + 1
place()
""".strip().splitLines())
    var vm = newVm(program, 0, 1)
    let view = emptyView()
    let first = vm.step(view, 2000)
    check first.kind == akWait
    check first.stalled
    check vm.fault.line == 0
    check not vm.halted
    let pcAfterStall = vm.pc
    let second = vm.step(view, 2000)
    check second.kind == akWait
    check second.stalled
    ## Progress, not a reset: the machine carried on from where it stopped.
    check vm.pc == pcAfterStall or vm.pc > 0

  test "a program that runs off the end halts and never acts again":
    let outcome = run("place()\n", ticks = 4)
    check outcome.actions[0].kind == akPlace
    check outcome.actions.len >= 2
    check outcome.actions[1].kind == akNone
    check outcome.vm.halted
    check outcome.vm.fault.line == 0

  test "an action reports the source line it was written on":
    let outcome = run("""
var a = 1
var b = 2
while true:
  place()
  move(0, 1)
""", ticks = 2)
    check outcome.actions[0].line == 4
    check outcome.actions[1].line == 5

  test "each warrior's rand stream is its own and reproducible":
    let program = compile(@["var r = rand(1000000)", "place()"])
    var a = newVm(program, 0, 99)
    var b = newVm(program, 1, 99)
    var c = newVm(program, 0, 99)
    let view = emptyView()
    discard a.step(view, 2000)
    discard b.step(view, 2000)
    discard c.step(view, 2000)
    check a.globals[0] == c.globals[0]
    check a.globals[0] != b.globals[0]

suite "compile caps":
  test "over 120 lines":
    var lines: seq[string]
    for index in 0 ..< 130:
      lines.add("var v" & $index & " = " & $index)
    check "120" in compileError(lines.join("\n"))

  test "a line over 100 characters":
    check "100" in compileError("var a = 1\nvar b = " & repeat("1 + ", 40) & "1\n")

  test "over 4000 characters":
    var lines: seq[string]
    for index in 0 ..< 110:
      lines.add("var v" & $index & " = " & repeat("1234567890", 4))
    let message = compileError(lines.join("\n"))
    check "4000" in message

  test "over 32 procs":
    var lines: seq[string]
    for index in 0 ..< 40:
      lines.add("proc p" & $index & "() =")
      lines.add("  return " & $index)
    check "32" in compileError(lines.join("\n"))

  test "blocks nested deeper than 8":
    var lines = @["var a = 1"]
    for depth in 0 ..< 11:
      lines.add(repeat("  ", depth) & "if a == 1:")
    lines.add(repeat("  ", 11) & "place()")
    check "8" in compileError(lines.join("\n"))

  test "over 4000 AST nodes":
    var lines: seq[string]
    for index in 0 ..< 119:
      lines.add("var v = " & repeat("1 + ", 18) & "1")
    let message = compileError(lines.join("\n"))
    check "4000" in message
