## GWL — the Grid Wars warrior language.
##
## Lexer, parser, compiler to a flat op array, and the resumable VM that
## runs one warrior. Pure: no IO, no clock, no allocation beyond the
## program's own arrays, and **no floating point anywhere** — the native
## server and the wasm replay viewer must agree bit for bit, so int64 is
## the only numeric type the machine has.
##
## The VM suspends on an action (`move`/`place`/`bomb`/`wait`) and resumes
## at the next instruction on the following tick, which is what makes "one
## action per tick" a property of the machine rather than a convention.
## The VM never touches the board: `check`/`who` read a `BoardView`
## snapshot handed in by the sim, so "every check in tick t sees the board
## as it stood at the end of tick t-1" is true by construction.

import std/[strutils, unicode]

const
  Grid* = 30
  Cells* = Grid * Grid
  MaxSourceLines* = 120
  MaxSourceLineChars* = 100
  MaxSourceChars* = 4000
  MaxNodes* = 4000
  MaxProcs* = 32
  MaxNesting* = 8
  MaxCallDepth* = 64
  MaxArrayElements* = 4096
  FogRadius* = 4
  ## Constants a warrior program can name.
  ValBomb* = -1
  ValCorpse* = -2
  ValFog* = -3
  ValEmpty* = 0
  MaxFuse* = 5

type
  GwlValue* = int64
    ## The VM's ONE numeric type. It is int64 EXPLICITLY, never platform
    ## `int`: the wasm viewer re-derives every battle with `--cpu:wasm32`,
    ## where `int` is 32 bits, so a VM typed `int` would overflow in the
    ## browser at 2^31 while the server ran on to 2^63 — the two halves
    ## would disagree, the digest would mismatch and the viewer would show
    ## data-replay-error for a replay the server considers valid.

  GwlCompileError* = object of CatchableError
    line*: int

  ActionKind* = enum
    akNone = "none"
    akMove = "move"
    akPlace = "place"
    akBomb = "bomb"
    akWait = "wait"

  GwlOpKind* = enum
    opPush, opLoad, opStore, opIndex, opBin, opUn, opCall,
    opJump, opJumpFalse, opEnter, opLeave, opReturn,
    opAction, opHalt

  GwlOp* = object
    kind*: GwlOpKind
    a*, b*: int            ## operand slots (constant index, name id, arg count, target pc)
    line*: int             ## 1-based source line, for the highlight and for faults

  GwlProgram* = object
    ops*: seq[GwlOp]
    names*: seq[string]
    consts*: seq[GwlValue]
    source*: seq[string]   ## the submitted lines, verbatim, for the viewer's code pane
    globalCount*: int
    procEntry*: seq[int]   ## proc index -> entry pc
    procArity*: seq[int]
    procName*: seq[string]
    procLocals*: seq[int]

  GwlFault* = object
    line*: int
    message*: string

  Frame* = object
    returnPc*: int
    base*: int             ## first slot of this frame in `locals`
    count*: int

  GwlVm* = object          ## one warrior's resumable machine
    program*: GwlProgram
    pc*: int
    stack*: seq[GwlValue]
    stackKind*: seq[int8]  ## value tag parallel to `stack`: 0 int, 1 bool, 2 array
    frames*: seq[Frame]
    globals*: seq[GwlValue]
    globalKind*: seq[int8]
    locals*: seq[GwlValue]
    localKind*: seq[int8]
    arrays*: seq[seq[GwlValue]]
    arraySlot*: seq[int]   ## pc -> array index an array literal reuses (-1 = none)
    halted*: bool
    fault*: GwlFault       ## line 0 = none
    rng*: uint64

  GwlAction* = object
    kind*: ActionKind
    dx*, dy*: GwlValue
    line*: int
    stalled*: bool         ## akWait produced by the instruction budget, not by wait()

  BoardView* = object
    ## Read-only snapshot of the board as it stood at the end of the
    ## previous tick, plus the acting warrior's own numbers.
    owner*: array[Cells, int8]
    corpse*: array[Cells, bool]
    bomb*: array[Cells, bool]
    occupant*: array[Cells, int8]   ## living warrior id on the cell, 0 = none
    alive*: array[5, bool]          ## by warrior id 1..4
    x*, y*, id*, energy*, tiles*, tick*, bombCost*: int

# ---- Rune-safe text ---------------------------------------------------------

proc cutRunes*(text: string, limit: int): string =
  ## The one truncation used by everything that can reach the replay —
  ## notes, banner, compile errors, transport errors, model reply excerpts.
  ## The cut is on a RUNE boundary: a byte slice through a multi-byte
  ## character leaves invalid UTF-8 in the replay, which still renders in a
  ## browser and fails a strict JSON parser.
  result = text
  if result.runeLen > limit:
    result = result.runeSubStr(0, max(limit - 1, 0)) & "…"

proc charAt(text: string, pos: int): string =
  ## The bytes of the WHOLE character at `pos`. Quoting a single byte of a
  ## multi-byte character into a compile error puts a split character into
  ## the replay; a byte that is not valid UTF-8 at all is escaped instead.
  var stop = pos + 1
  while stop < text.len and (text[stop].uint8 and 0b1100_0000'u8) == 0b1000_0000'u8:
    inc stop
  result = text[pos ..< stop]
  if result.validateUtf8() != -1:
    result = "\\x" & toHex(text[pos].uint8, 2)

# ---- Value tags -------------------------------------------------------------

const
  kInt: int8 = 0
  kBool: int8 = 1
  kArray: int8 = 2

# ---- Operators --------------------------------------------------------------

type
  BinOp = enum
    bAdd, bSub, bMul, bDiv, bMod, bEq, bNe, bLt, bLe, bGt, bGe
  UnOp = enum
    uNeg, uNot, uAssertBool
  Builtin = enum
    fCheck, fWho, fX, fY, fTiles, fEnergy, fTick, fAlive, fRand,
    fAbs, fMin, fMax, fLen, fXor, fShl, fShr, fMod, fDiv,
    fId, fBombCost, fArray

const
  BuiltinArity: array[Builtin, int] = [
    2, 2, 0, 0, 0, 0, 0, 1, 1,
    1, 2, 2, 1, 2, 2, 2, 2, 2,
    0, 0, -1
  ]
  BuiltinNames: array[Builtin, string] = [
    "check", "who", "x", "y", "tiles", "energy", "tick", "alive", "rand",
    "abs", "min", "max", "len", "xor", "shl", "shr", "mod", "div",
    "ID", "BOMBCOST", "[]"
  ]
  BuiltinBase = 100

# ---- Lexer ------------------------------------------------------------------

type
  TokKind = enum
    tkInt, tkIdent, tkOp, tkNewline, tkIndent, tkDedent, tkEof
  Token = object
    kind: TokKind
    text: string
    value: GwlValue
    line: int

proc compileError(line: int, message: string) {.noreturn.} =
  var error = newException(GwlCompileError, "line " & $line & ": " & message)
  error.line = line
  raise error

proc isIdentStart(c: char): bool = c in {'a' .. 'z', 'A' .. 'Z', '_'}
proc isIdentChar(c: char): bool = c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}

proc continuesLine(token: Token): bool =
  ## A line whose last token is a binary operator, a comma or an open
  ## bracket runs on to the next one, exactly as Nim's does. Without this a
  ## model that wraps a long condition (and the 100-character line cap
  ## makes that likely) writes a program that cannot compile.
  case token.kind
  of tkOp:
    ## NOT "=": a `proc f() =` header ends the line, and an assignment with
    ## nothing after the `=` is an error rather than a continuation.
    ## Open brackets are covered by the depth counter instead.
    token.text in ["+", "-", "*", "==", "!=", "<", "<=", ">", ">=", ",",
      "..", "..<"]
  of tkIdent:
    token.text in ["and", "or", "not", "div", "mod", "in"]
  else:
    false

proc lex(lines: seq[string]): seq[Token] =
  var indents = @[0]
  var depth = 0        ## unclosed ( and [
  var continuing = false
  for index, rawLine in lines:
    let lineNo = index + 1
    ## Tabs read as two spaces; `#` (and `##`) run to end of line.
    var text = rawLine.replace("\t", "  ")
    let hash = text.find('#')
    if hash >= 0:
      text = text[0 ..< hash]
    if text.strip().len == 0:
      continue
    var spaces = 0
    while spaces < text.len and text[spaces] == ' ':
      inc spaces
    if not continuing:
      if spaces mod 2 != 0:
        compileError(lineNo,
          "indentation must be a multiple of 2 spaces, got " & $spaces)
      let level = spaces div 2
      if level > indents[^1]:
        indents.add(level)
        result.add(Token(kind: tkIndent, line: lineNo))
      else:
        while level < indents[^1]:
          discard indents.pop()
          result.add(Token(kind: tkDedent, line: lineNo))
        if level != indents[^1]:
          compileError(lineNo, "dedent to a level that was never opened")
    var pos = spaces
    while pos < text.len:
      let c = text[pos]
      if c == ' ':
        inc pos
      elif c in {'0' .. '9'}:
        var stop = pos
        while stop < text.len and text[stop] in {'0' .. '9'}:
          inc stop
        var value: GwlValue = 0
        try:
          value = parseBiggestInt(text[pos ..< stop])
        except ValueError:
          compileError(lineNo, "integer literal out of range: " &
            text[pos ..< stop])
        result.add(Token(kind: tkInt, value: value, line: lineNo))
        pos = stop
      elif isIdentStart(c):
        var stop = pos
        while stop < text.len and isIdentChar(text[stop]):
          inc stop
        result.add(Token(kind: tkIdent, text: text[pos ..< stop], line: lineNo))
        pos = stop
      else:
        var op = ""
        for candidate in ["..<", "..", "==", "!=", "<=", ">="]:
          if text.len - pos >= candidate.len and
              text[pos ..< pos + candidate.len] == candidate:
            op = candidate
            break
        if op.len == 0:
          if c in {'(', ')', '[', ']', ',', ':', '=', '<', '>', '+', '-',
                   '*'}:
            op = $c
          else:
            compileError(lineNo,
              "unexpected character '" & text.charAt(pos) & "'")
        if op == "(" or op == "[":
          inc depth
        elif op == ")" or op == "]":
          depth = max(depth - 1, 0)
        result.add(Token(kind: tkOp, text: op, line: lineNo))
        pos += op.len
    if result.len > 0 and (depth > 0 or continuesLine(result[^1])):
      continuing = true
    else:
      continuing = false
      result.add(Token(kind: tkNewline, line: lineNo))
  if continuing:
    result.add(Token(kind: tkNewline, line: max(lines.len, 1)))
  let lastLine = max(lines.len, 1)
  while indents.len > 1:
    discard indents.pop()
    result.add(Token(kind: tkDedent, line: lastLine))
  result.add(Token(kind: tkEof, line: lastLine))

# ---- AST --------------------------------------------------------------------

type
  NodeKind = enum
    nkInt, nkBool, nkIdent, nkArray, nkIndex, nkCall, nkUnary, nkBinary,
    nkAnd, nkOr,
    nkVar, nkAssign, nkAssignIndex, nkIf, nkWhile, nkForRange, nkForArray,
    nkProc, nkReturn, nkBreak, nkContinue, nkDiscard, nkAction, nkBlock
  Node = ref object
    kind: NodeKind
    line: int
    intVal: GwlValue
    boolVal: bool
    name: string
    op: string
    inclusive: bool
    action: ActionKind
    params: seq[string]
    kids: seq[Node]

  Parser = object
    tokens: seq[Token]
    pos: int
    nodes: int
    procs: int

proc peek(p: Parser): Token = p.tokens[p.pos]
proc advance(p: var Parser): Token =
  result = p.tokens[p.pos]
  if p.pos + 1 < p.tokens.len:
    inc p.pos

proc atOp(p: Parser, text: string): bool =
  p.peek.kind == tkOp and p.peek.text == text

proc atIdent(p: Parser, text: string): bool =
  p.peek.kind == tkIdent and p.peek.text == text

proc expectOp(p: var Parser, text: string) =
  if not p.atOp(text):
    compileError(p.peek.line, "expected '" & text & "'")
  discard p.advance()

proc expectNewline(p: var Parser) =
  if p.peek.kind != tkNewline:
    compileError(p.peek.line, "unexpected token after the end of the statement")
  discard p.advance()

proc newNode(p: var Parser, kind: NodeKind, line: int): Node =
  inc p.nodes
  if p.nodes > MaxNodes:
    compileError(line, "program is too complex: over " & $MaxNodes &
      " AST nodes")
  Node(kind: kind, line: line)

const Keywords = ["var", "if", "elif", "else", "while", "for", "in", "proc",
  "return", "break", "continue", "discard", "true", "false", "and", "or",
  "not", "div", "mod"]

proc parseExpr(p: var Parser): Node
proc parseBlock(p: var Parser, depth: int): Node

proc parsePrimary(p: var Parser): Node =
  let token = p.peek
  case token.kind
  of tkInt:
    discard p.advance()
    result = p.newNode(nkInt, token.line)
    result.intVal = token.value
  of tkIdent:
    if token.text == "true" or token.text == "false":
      discard p.advance()
      result = p.newNode(nkBool, token.line)
      result.boolVal = token.text == "true"
      return
    if token.text == "not":
      discard p.advance()
      result = p.newNode(nkUnary, token.line)
      result.op = "not"
      result.kids.add(p.parsePrimary())
      return
    ## `div`/`mod` exist in BOTH forms: infix `a mod b` and the call form
    ## `mod(a, b)` the prototype's warriors are written in.
    let callForm = (token.text == "div" or token.text == "mod") and
      p.tokens[p.pos + 1].kind == tkOp and p.tokens[p.pos + 1].text == "("
    if token.text in Keywords and not callForm:
      compileError(token.line, "'" & token.text & "' is not an expression")
    discard p.advance()
    if p.atOp("("):
      discard p.advance()
      result = p.newNode(nkCall, token.line)
      result.name = token.text
      if not p.atOp(")"):
        while true:
          result.kids.add(p.parseExpr())
          if p.atOp(","):
            discard p.advance()
          else:
            break
      p.expectOp(")")
    else:
      result = p.newNode(nkIdent, token.line)
      result.name = token.text
  of tkOp:
    if token.text == "(":
      discard p.advance()
      result = p.parseExpr()
      p.expectOp(")")
    elif token.text == "-":
      discard p.advance()
      result = p.newNode(nkUnary, token.line)
      result.op = "-"
      result.kids.add(p.parsePrimary())
      return
    elif token.text == "[":
      discard p.advance()
      result = p.newNode(nkArray, token.line)
      if not p.atOp("]"):
        while true:
          result.kids.add(p.parseExpr())
          if p.atOp(","):
            discard p.advance()
          else:
            break
      p.expectOp("]")
    else:
      compileError(token.line, "unexpected '" & token.text & "'")
  else:
    compileError(token.line, "unexpected end of expression")
  ## Postfix indexing.
  while p.atOp("["):
    let line = p.peek.line
    discard p.advance()
    var index = p.newNode(nkIndex, line)
    index.kids.add(result)
    index.kids.add(p.parseExpr())
    p.expectOp("]")
    result = index

proc binPrecedence(p: Parser): int =
  let token = p.peek
  if token.kind == tkIdent:
    case token.text
    of "or": return 3
    of "and": return 4
    of "div", "mod": return 9
    else: return 0
  if token.kind != tkOp:
    return 0
  case token.text
  of "==", "!=", "<", "<=", ">", ">=": 5
  of "+", "-": 8
  of "*": 9
  else: 0

proc parseBin(p: var Parser, minPrecedence: int): Node =
  result = p.parsePrimary()
  while true:
    let precedence = p.binPrecedence()
    if precedence == 0 or precedence < minPrecedence:
      break
    let token = p.advance()
    let right = p.parseBin(precedence + 1)
    let kind =
      if token.text == "and": nkAnd
      elif token.text == "or": nkOr
      else: nkBinary
    var node = p.newNode(kind, token.line)
    node.op = token.text
    node.kids.add(result)
    node.kids.add(right)
    result = node

proc parseExpr(p: var Parser): Node =
  p.parseBin(1)

proc parseStatement(p: var Parser, depth: int): Node =
  let token = p.peek
  if token.kind != tkIdent:
    compileError(token.line, "a statement must start with a name")
  case token.text
  of "var":
    discard p.advance()
    if p.peek.kind != tkIdent or p.peek.text in Keywords:
      compileError(p.peek.line, "expected a variable name after 'var'")
    result = p.newNode(nkVar, token.line)
    result.name = p.advance().text
    p.expectOp("=")
    result.kids.add(p.parseExpr())
    p.expectNewline()
  of "return":
    discard p.advance()
    result = p.newNode(nkReturn, token.line)
    if p.peek.kind != tkNewline:
      result.kids.add(p.parseExpr())
    p.expectNewline()
  of "break":
    discard p.advance()
    result = p.newNode(nkBreak, token.line)
    p.expectNewline()
  of "continue":
    discard p.advance()
    result = p.newNode(nkContinue, token.line)
    p.expectNewline()
  of "discard":
    discard p.advance()
    result = p.newNode(nkDiscard, token.line)
    result.kids.add(p.parseExpr())
    p.expectNewline()
  of "if":
    discard p.advance()
    result = p.newNode(nkIf, token.line)
    result.kids.add(p.parseExpr())
    p.expectOp(":")
    p.expectNewline()
    result.kids.add(p.parseBlock(depth + 1))
    while p.atIdent("elif"):
      discard p.advance()
      result.kids.add(p.parseExpr())
      p.expectOp(":")
      p.expectNewline()
      result.kids.add(p.parseBlock(depth + 1))
    if p.atIdent("else"):
      discard p.advance()
      p.expectOp(":")
      p.expectNewline()
      result.kids.add(p.parseBlock(depth + 1))
  of "while":
    discard p.advance()
    result = p.newNode(nkWhile, token.line)
    result.kids.add(p.parseExpr())
    p.expectOp(":")
    p.expectNewline()
    result.kids.add(p.parseBlock(depth + 1))
  of "for":
    discard p.advance()
    if p.peek.kind != tkIdent or p.peek.text in Keywords:
      compileError(p.peek.line, "expected a loop variable after 'for'")
    let name = p.advance().text
    if not p.atIdent("in"):
      compileError(p.peek.line, "expected 'in' in a for loop")
    discard p.advance()
    let first = p.parseExpr()
    if p.atOp("..<") or p.atOp(".."):
      let dots = p.advance().text
      result = p.newNode(nkForRange, token.line)
      result.name = name
      result.inclusive = dots == ".."
      result.kids.add(first)
      result.kids.add(p.parseExpr())
    else:
      result = p.newNode(nkForArray, token.line)
      result.name = name
      result.kids.add(first)
    p.expectOp(":")
    p.expectNewline()
    result.kids.add(p.parseBlock(depth + 1))
  of "proc":
    if depth != 0:
      compileError(token.line, "a proc may only be declared at the top level")
    discard p.advance()
    inc p.procs
    if p.procs > MaxProcs:
      compileError(token.line, "too many procs: the limit is " & $MaxProcs)
    if p.peek.kind != tkIdent or p.peek.text in Keywords:
      compileError(p.peek.line, "expected a proc name")
    result = p.newNode(nkProc, token.line)
    result.name = p.advance().text
    p.expectOp("(")
    if not p.atOp(")"):
      while true:
        if p.peek.kind != tkIdent or p.peek.text in Keywords:
          compileError(p.peek.line, "expected a parameter name")
        result.params.add(p.advance().text)
        if p.atOp(","):
          discard p.advance()
        else:
          break
    p.expectOp(")")
    p.expectOp("=")
    p.expectNewline()
    result.kids.add(p.parseBlock(depth + 1))
  of "move", "place", "bomb", "wait":
    discard p.advance()
    result = p.newNode(nkAction, token.line)
    result.action =
      case token.text
      of "move": akMove
      of "place": akPlace
      of "bomb": akBomb
      else: akWait
    p.expectOp("(")
    if not p.atOp(")"):
      while true:
        result.kids.add(p.parseExpr())
        if p.atOp(","):
          discard p.advance()
        else:
          break
    p.expectOp(")")
    let want = if result.action == akMove: 2 else: 0
    if result.kids.len != want:
      compileError(token.line, token.text & "() takes " & $want &
        " arguments, got " & $result.kids.len)
    p.expectNewline()
  else:
    ## Assignment, indexed assignment, or a bare call statement.
    let target = p.parseExpr()
    if p.atOp("="):
      discard p.advance()
      if target.kind == nkIdent:
        result = p.newNode(nkAssign, token.line)
        result.name = target.name
        result.kids.add(p.parseExpr())
      elif target.kind == nkIndex:
        result = p.newNode(nkAssignIndex, token.line)
        result.kids.add(target.kids[0])
        result.kids.add(target.kids[1])
        result.kids.add(p.parseExpr())
      else:
        compileError(token.line, "cannot assign to this expression")
    elif target.kind == nkCall:
      result = p.newNode(nkDiscard, token.line)
      result.kids.add(target)
    else:
      compileError(token.line, "expected a statement, found an expression")
    p.expectNewline()

proc parseBlock(p: var Parser, depth: int): Node =
  if depth > MaxNesting:
    compileError(p.peek.line, "blocks nest deeper than " & $MaxNesting)
  if p.peek.kind != tkIndent:
    compileError(p.peek.line, "expected an indented block")
  discard p.advance()
  result = p.newNode(nkBlock, p.peek.line)
  while p.peek.kind != tkDedent and p.peek.kind != tkEof:
    result.kids.add(p.parseStatement(depth))
  if p.peek.kind == tkDedent:
    discard p.advance()

proc parseProgram(p: var Parser): Node =
  result = p.newNode(nkBlock, 1)
  while p.peek.kind != tkEof:
    if p.peek.kind == tkNewline:
      discard p.advance()
      continue
    if p.peek.kind == tkIndent or p.peek.kind == tkDedent:
      compileError(p.peek.line, "unexpected indentation at the top level")
    result.kids.add(p.parseStatement(0))

# ---- Compiler ---------------------------------------------------------------

type
  Scope = object
    names: seq[string]
    slots: seq[int]
  Compiler = object
    program: GwlProgram
    globalScopes: seq[Scope]
    localScopes: seq[Scope]
    inProc: bool
    localCount: int
    breaks: seq[seq[int]]
    continues: seq[seq[int]]

proc emit(c: var Compiler, kind: GwlOpKind, a, b, line: int): int =
  result = c.program.ops.len
  c.program.ops.add(GwlOp(kind: kind, a: a, b: b, line: line))

proc constIndex(c: var Compiler, value: GwlValue): int =
  for index, existing in c.program.consts:
    if existing == value:
      return index
  c.program.consts.add(value)
  c.program.consts.len - 1

proc nameIndex(c: var Compiler, name: string): int =
  for index, existing in c.program.names:
    if existing == name:
      return index
  c.program.names.add(name)
  c.program.names.len - 1

proc declare(c: var Compiler, name: string): tuple[slot, scope: int] =
  if c.inProc:
    result = (c.localCount, 1)
    inc c.localCount
    c.localScopes[^1].names.add(name)
    c.localScopes[^1].slots.add(result.slot)
  else:
    ## Top-level names live in ONE flat global scope: procs are compiled
    ## before the statements that declare them, and a proc must be able to
    ## see every global (`globals visible, params by value`).
    for position in countdown(c.globalScopes[0].names.high, 0):
      if c.globalScopes[0].names[position] == name and name != " tmp":
        return (c.globalScopes[0].slots[position], 0)
    result = (c.program.globalCount, 0)
    inc c.program.globalCount
    c.globalScopes[0].names.add(name)
    c.globalScopes[0].slots.add(result.slot)

proc lookup(c: Compiler, name: string): tuple[slot, scope: int] =
  if c.inProc:
    for index in countdown(c.localScopes.high, 0):
      let scope = c.localScopes[index]
      for position in countdown(scope.names.high, 0):
        if scope.names[position] == name:
          return (scope.slots[position], 1)
  for position in countdown(c.globalScopes[0].names.high, 0):
    if c.globalScopes[0].names[position] == name:
      return (c.globalScopes[0].slots[position], 0)
  (-1, -1)

proc builtinOf(name: string): int =
  for builtin in Builtin:
    if BuiltinNames[builtin] == name:
      return ord(builtin)
  -1

proc procOf(c: Compiler, name: string): int =
  for index, existing in c.program.procName:
    if existing == name:
      return index
  -1

const ConstantNames = {
  "BOMB": ValBomb, "CORPSE": ValCorpse, "FOG": ValFog, "EMPTY": ValEmpty,
  "gridSize": Grid, "MAXFUSE": MaxFuse
}

proc compileNode(c: var Compiler, node: Node)

proc compileExpr(c: var Compiler, node: Node) =
  case node.kind
  of nkInt:
    discard c.emit(opPush, c.constIndex(node.intVal), 0, node.line)
  of nkBool:
    discard c.emit(opPush, (if node.boolVal: 1 else: 0), 1, node.line)
  of nkIdent:
    for pair in ConstantNames:
      if pair[0] == node.name:
        discard c.emit(opPush, c.constIndex(pair[1]), 0, node.line)
        return
    if node.name == "ID":
      discard c.emit(opCall, ord(fId), 0, node.line)
      return
    if node.name == "BOMBCOST":
      discard c.emit(opCall, ord(fBombCost), 0, node.line)
      return
    let found = c.lookup(node.name)
    if found.scope < 0:
      discard c.emit(opLoad, c.nameIndex(node.name), 2, node.line)
    else:
      discard c.emit(opLoad, found.slot, found.scope, node.line)
  of nkArray:
    for kid in node.kids:
      c.compileExpr(kid)
    discard c.emit(opCall, ord(fArray), node.kids.len, node.line)
  of nkIndex:
    c.compileExpr(node.kids[0])
    c.compileExpr(node.kids[1])
    discard c.emit(opIndex, 0, 0, node.line)
  of nkUnary:
    c.compileExpr(node.kids[0])
    discard c.emit(opUn, (if node.op == "-": ord(uNeg) else: ord(uNot)), 0,
      node.line)
  of nkBinary:
    c.compileExpr(node.kids[0])
    c.compileExpr(node.kids[1])
    let op =
      case node.op
      of "+": bAdd
      of "-": bSub
      of "*": bMul
      of "div": bDiv
      of "mod": bMod
      of "==": bEq
      of "!=": bNe
      of "<": bLt
      of "<=": bLe
      of ">": bGt
      else: bGe
    discard c.emit(opBin, ord(op), 0, node.line)
  of nkAnd:
    c.compileExpr(node.kids[0])
    let jump = c.emit(opJumpFalse, 0, 0, node.line)
    c.compileExpr(node.kids[1])
    discard c.emit(opUn, ord(uAssertBool), 0, node.line)
    let over = c.emit(opJump, 0, 0, node.line)
    c.program.ops[jump].a = c.program.ops.len
    discard c.emit(opPush, 0, 1, node.line)
    c.program.ops[over].a = c.program.ops.len
  of nkOr:
    c.compileExpr(node.kids[0])
    let jump = c.emit(opJumpFalse, 0, 0, node.line)
    discard c.emit(opPush, 1, 1, node.line)
    let over = c.emit(opJump, 0, 0, node.line)
    c.program.ops[jump].a = c.program.ops.len
    c.compileExpr(node.kids[1])
    discard c.emit(opUn, ord(uAssertBool), 0, node.line)
    c.program.ops[over].a = c.program.ops.len
  of nkCall:
    for kid in node.kids:
      c.compileExpr(kid)
    let builtin = builtinOf(node.name)
    if builtin >= 0 and builtin != ord(fArray):
      discard c.emit(opCall, builtin, node.kids.len, node.line)
      return
    let target = c.procOf(node.name)
    if target >= 0:
      discard c.emit(opCall, BuiltinBase + target, node.kids.len, node.line)
      return
    discard c.emit(opCall, -1 - c.nameIndex(node.name), node.kids.len,
      node.line)
  else:
    compileError(node.line, "expected an expression")

proc pushScope(c: var Compiler) =
  if c.inProc:
    c.localScopes.add(Scope())

proc popScope(c: var Compiler) =
  if c.inProc:
    discard c.localScopes.pop()

proc compileBlock(c: var Compiler, node: Node) =
  c.pushScope()
  for kid in node.kids:
    c.compileNode(kid)
  c.popScope()

proc hiddenSlot(c: var Compiler): tuple[slot, scope: int] =
  c.declare(" tmp")

proc compileNode(c: var Compiler, node: Node) =
  case node.kind
  of nkBlock:
    c.compileBlock(node)
  of nkVar:
    c.compileExpr(node.kids[0])
    ## Re-executing a `var` re-initialises the same slot, so a declaration
    ## inside a loop body costs one slot, not one per iteration.
    var found = (slot: -1, scope: -1)
    if c.inProc:
      let scope = c.localScopes[^1]
      for position in countdown(scope.names.high, 0):
        if scope.names[position] == node.name:
          found = (scope.slots[position], 1)
          break
    if found.scope < 0:
      found = c.declare(node.name)
    discard c.emit(opStore, found.slot, found.scope, node.line)
  of nkAssign:
    c.compileExpr(node.kids[0])
    let found = c.lookup(node.name)
    if found.scope < 0:
      discard c.emit(opStore, c.nameIndex(node.name), 2, node.line)
    else:
      discard c.emit(opStore, found.slot, found.scope, node.line)
  of nkAssignIndex:
    c.compileExpr(node.kids[0])
    c.compileExpr(node.kids[1])
    c.compileExpr(node.kids[2])
    discard c.emit(opIndex, 1, 0, node.line)
  of nkDiscard:
    c.compileExpr(node.kids[0])
    discard c.emit(opLeave, 1, 0, node.line)
  of nkIf:
    var jumpsToEnd: seq[int]
    var index = 0
    while index + 1 < node.kids.len:
      c.compileExpr(node.kids[index])
      let jump = c.emit(opJumpFalse, 0, 0, node.kids[index].line)
      c.compileBlock(node.kids[index + 1])
      jumpsToEnd.add(c.emit(opJump, 0, 0, node.line))
      c.program.ops[jump].a = c.program.ops.len
      index += 2
    if index < node.kids.len:
      c.compileBlock(node.kids[index])
    for jump in jumpsToEnd:
      c.program.ops[jump].a = c.program.ops.len
  of nkWhile:
    let top = c.program.ops.len
    c.compileExpr(node.kids[0])
    let exit = c.emit(opJumpFalse, 0, 0, node.line)
    c.breaks.add(@[])
    c.continues.add(@[])
    c.compileBlock(node.kids[1])
    let continueTarget = c.program.ops.len
    discard c.emit(opJump, top, 0, node.line)
    c.program.ops[exit].a = c.program.ops.len
    for jump in c.breaks.pop():
      c.program.ops[jump].a = c.program.ops.len
    for jump in c.continues.pop():
      c.program.ops[jump].a = continueTarget
  of nkForRange:
    c.pushScope()
    let loopVar = c.declare(node.name)
    let limit = c.hiddenSlot()
    c.compileExpr(node.kids[0])
    discard c.emit(opStore, loopVar.slot, loopVar.scope, node.line)
    c.compileExpr(node.kids[1])
    discard c.emit(opStore, limit.slot, limit.scope, node.line)
    let top = c.program.ops.len
    discard c.emit(opLoad, loopVar.slot, loopVar.scope, node.line)
    discard c.emit(opLoad, limit.slot, limit.scope, node.line)
    discard c.emit(opBin, (if node.inclusive: ord(bLe) else: ord(bLt)), 0,
      node.line)
    let exit = c.emit(opJumpFalse, 0, 0, node.line)
    c.breaks.add(@[])
    c.continues.add(@[])
    c.compileBlock(node.kids[2])
    let continueTarget = c.program.ops.len
    discard c.emit(opLoad, loopVar.slot, loopVar.scope, node.line)
    discard c.emit(opPush, c.constIndex(1), 0, node.line)
    discard c.emit(opBin, ord(bAdd), 0, node.line)
    discard c.emit(opStore, loopVar.slot, loopVar.scope, node.line)
    discard c.emit(opJump, top, 0, node.line)
    c.program.ops[exit].a = c.program.ops.len
    for jump in c.breaks.pop():
      c.program.ops[jump].a = c.program.ops.len
    for jump in c.continues.pop():
      c.program.ops[jump].a = continueTarget
    c.popScope()
  of nkForArray:
    c.pushScope()
    let loopVar = c.declare(node.name)
    let arraySlot = c.hiddenSlot()
    let indexSlot = c.hiddenSlot()
    c.compileExpr(node.kids[0])
    discard c.emit(opStore, arraySlot.slot, arraySlot.scope, node.line)
    discard c.emit(opPush, c.constIndex(0), 0, node.line)
    discard c.emit(opStore, indexSlot.slot, indexSlot.scope, node.line)
    let top = c.program.ops.len
    discard c.emit(opLoad, indexSlot.slot, indexSlot.scope, node.line)
    discard c.emit(opLoad, arraySlot.slot, arraySlot.scope, node.line)
    discard c.emit(opCall, ord(fLen), 1, node.line)
    discard c.emit(opBin, ord(bLt), 0, node.line)
    let exit = c.emit(opJumpFalse, 0, 0, node.line)
    discard c.emit(opLoad, arraySlot.slot, arraySlot.scope, node.line)
    discard c.emit(opLoad, indexSlot.slot, indexSlot.scope, node.line)
    discard c.emit(opIndex, 0, 0, node.line)
    discard c.emit(opStore, loopVar.slot, loopVar.scope, node.line)
    c.breaks.add(@[])
    c.continues.add(@[])
    c.compileBlock(node.kids[1])
    let continueTarget = c.program.ops.len
    discard c.emit(opLoad, indexSlot.slot, indexSlot.scope, node.line)
    discard c.emit(opPush, c.constIndex(1), 0, node.line)
    discard c.emit(opBin, ord(bAdd), 0, node.line)
    discard c.emit(opStore, indexSlot.slot, indexSlot.scope, node.line)
    discard c.emit(opJump, top, 0, node.line)
    c.program.ops[exit].a = c.program.ops.len
    for jump in c.breaks.pop():
      c.program.ops[jump].a = c.program.ops.len
    for jump in c.continues.pop():
      c.program.ops[jump].a = continueTarget
    c.popScope()
  of nkBreak:
    if c.breaks.len == 0:
      compileError(node.line, "'break' outside a loop")
    c.breaks[^1].add(c.emit(opJump, 0, 0, node.line))
  of nkContinue:
    if c.continues.len == 0:
      compileError(node.line, "'continue' outside a loop")
    c.continues[^1].add(c.emit(opJump, 0, 0, node.line))
  of nkReturn:
    if not c.inProc:
      compileError(node.line, "'return' outside a proc")
    if node.kids.len > 0:
      c.compileExpr(node.kids[0])
    else:
      discard c.emit(opPush, c.constIndex(0), 0, node.line)
    discard c.emit(opReturn, 0, 0, node.line)
  of nkAction:
    for kid in node.kids:
      c.compileExpr(kid)
    discard c.emit(opAction, ord(node.action), node.kids.len, node.line)
  of nkProc:
    compileError(node.line, "proc declarations are hoisted, not compiled here")
  else:
    compileError(node.line, "unexpected statement")

proc compileProc(c: var Compiler, node: Node, index: int) =
  c.inProc = true
  c.localCount = 0
  c.localScopes = @[Scope()]
  for param in node.params:
    discard c.declare(param)
  c.program.procEntry[index] = c.program.ops.len
  let enterOp = c.emit(opEnter, 0, 0, node.line)
  c.compileBlock(node.kids[0])
  discard c.emit(opPush, c.constIndex(0), 0, node.line)
  discard c.emit(opReturn, 0, 0, node.line)
  c.program.ops[enterOp].a = c.localCount
  c.program.procLocals[index] = c.localCount
  c.inProc = false
  c.localScopes = @[]

proc hoistGlobals(c: var Compiler, node: Node) =
  ## Procs are compiled before the top-level statements, so every global a
  ## proc might read has to have a slot already. Walk everything that is
  ## not a proc body and declare each name once.
  case node.kind
  of nkProc:
    discard
  of nkVar, nkForRange, nkForArray:
    discard c.declare(node.name)
    for kid in node.kids:
      c.hoistGlobals(kid)
  else:
    for kid in node.kids:
      c.hoistGlobals(kid)

proc compile*(lines: seq[string]): GwlProgram =
  ## Compiles a submitted warrior. Raises GwlCompileError with a line
  ## number and a message a model can act on.
  if lines.len > MaxSourceLines:
    compileError(lines.len, "a warrior is at most " & $MaxSourceLines &
      " lines, got " & $lines.len)
  var chars = 0
  for index, line in lines:
    if line.runeLen > MaxSourceLineChars:
      compileError(index + 1, "a line is at most " & $MaxSourceLineChars &
        " characters, got " & $line.runeLen)
    chars += line.runeLen + 1
  if chars > MaxSourceChars:
    compileError(lines.len, "a warrior is at most " & $MaxSourceChars &
      " characters, got " & $chars)
  var parser = Parser(tokens: lex(lines), pos: 0)
  let tree = parser.parseProgram()

  var c = Compiler(globalScopes: @[Scope()])
  c.program.source = lines
  ## Procs are hoisted so any proc may call any other, in any order.
  for kid in tree.kids:
    if kid.kind == nkProc:
      if c.procOf(kid.name) >= 0:
        compileError(kid.line, "proc '" & kid.name & "' is declared twice")
      c.program.procName.add(kid.name)
      c.program.procArity.add(kid.params.len)
      c.program.procEntry.add(0)
      c.program.procLocals.add(0)
  c.hoistGlobals(tree)
  let skipProcs = c.emit(opJump, 0, 0, 1)
  var procIndex = 0
  for kid in tree.kids:
    if kid.kind == nkProc:
      c.compileProc(kid, procIndex)
      inc procIndex
  c.program.ops[skipProcs].a = c.program.ops.len
  for kid in tree.kids:
    if kid.kind != nkProc:
      c.compileNode(kid)
  discard c.emit(opHalt, 0, 0, max(lines.len, 1))
  result = c.program

# ---- VM ---------------------------------------------------------------------

proc newVm*(program: GwlProgram, seat, seed: int): GwlVm =
  ## `seed` is the round's derived seed; the warrior's `rand` stream is
  ## seeded `seed + seat`, i.e. `config.seed * 1000003 + round * 97 + seat`.
  result = GwlVm(
    program: program,
    pc: 0,
    globals: newSeq[GwlValue](program.globalCount),
    globalKind: newSeq[int8](program.globalCount),
    arraySlot: newSeq[int](program.ops.len)
  )
  for index in 0 ..< result.arraySlot.len:
    result.arraySlot[index] = -1
  var state = uint64(seed + seat)
  if state == 0:
    state = 0x9E3779B97F4A7C15'u64
  result.rng = state

proc nextRandom(vm: var GwlVm): uint64 =
  ## xorshift64: integer-only, identical on x86-64 and wasm32.
  var state = vm.rng
  state = state xor (state shl 13)
  state = state xor (state shr 7)
  state = state xor (state shl 17)
  vm.rng = state
  state

proc fail(vm: var GwlVm, line: int, message: string) =
  if vm.fault.line == 0:
    vm.fault = GwlFault(line: line, message: message)

proc push(vm: var GwlVm, value: GwlValue, kind: int8) =
  vm.stack.add(value)
  vm.stackKind.add(kind)

proc popValue(vm: var GwlVm): tuple[value: GwlValue, kind: int8] =
  result = (vm.stack[^1], vm.stackKind[^1])
  discard vm.stack.pop()
  discard vm.stackKind.pop()

proc addChecked(a, b: GwlValue, ok: var bool): GwlValue =
  if (b > 0 and a > high(int64) - b) or (b < 0 and a < low(int64) - b):
    ok = false
    return 0
  a + b

proc subChecked(a, b: GwlValue, ok: var bool): GwlValue =
  if (b < 0 and a > high(int64) + b) or (b > 0 and a < low(int64) + b):
    ok = false
    return 0
  a - b

proc mulChecked(a, b: GwlValue, ok: var bool): GwlValue =
  ## The multiply itself must never execute unchecked: a debug build traps
  ## on OverflowDefect, and the VM reports overflow as a warrior fault.
  if a == 0 or b == 0:
    return 0
  if a == -1:
    if b == low(int64):
      ok = false
      return 0
    return -b
  if b == -1:
    if a == low(int64):
      ok = false
      return 0
    return -a
  if a > 0:
    if b > 0:
      if a > high(int64) div b:
        ok = false
        return 0
    else:
      if b < low(int64) div a:
        ok = false
        return 0
  else:
    if b > 0:
      if a < low(int64) div b:
        ok = false
        return 0
    else:
      if a < high(int64) div b:
        ok = false
        return 0
  a * b

proc cellIndex(x, y: int): int =
  ((y mod Grid + Grid) mod Grid) * Grid + ((x mod Grid + Grid) mod Grid)

proc outsideWindow(dx, dy: GwlValue): bool =
  ## Written without `abs`, which has no answer for low(int64).
  dx > FogRadius or dx < -FogRadius or dy > FogRadius or dy < -FogRadius

proc checkAt(view: BoardView, dx, dy: GwlValue): GwlValue =
  ## The 9x9 window comes FIRST: `check`/`who` are the game's partial
  ## observability, so nothing outside the window may leak, not even a
  ## bomb (design note, Deviations: "check/who see a 9x9 window; beyond
  ## is FOG").
  if outsideWindow(dx, dy):
    return ValFog
  let cell = cellIndex(view.x + int(dx), view.y + int(dy))
  if view.bomb[cell]:
    return ValBomb
  if view.corpse[cell]:
    return ValCorpse
  int(view.owner[cell])

proc whoAt(view: BoardView, dx, dy: GwlValue): GwlValue =
  if outsideWindow(dx, dy):
    return ValFog
  int(view.occupant[cellIndex(view.x + int(dx), view.y + int(dy))])

proc liveElements(vm: GwlVm): int =
  for entry in vm.arrays:
    result += entry.len

proc step*(vm: var GwlVm, view: BoardView, budget: int): GwlAction =
  ## Runs until the warrior reaches an action, faults, halts, or spends
  ## `budget` instructions. `akNone` with `vm.fault.line > 0` is a fault,
  ## `akNone` with `vm.halted` is a program that ran off its end, and
  ## `akWait` with `stalled` is the instruction budget running out.
  result = GwlAction(kind: akNone, line: 0)
  if vm.halted or vm.fault.line > 0:
    return
  var used = 0
  while used < budget:
    inc used
    if vm.pc < 0 or vm.pc >= vm.program.ops.len:
      vm.halted = true
      return
    let op = vm.program.ops[vm.pc]
    let line = op.line
    inc vm.pc
    case op.kind
    of opPush:
      if op.b == 1:
        vm.push(GwlValue(op.a), kBool)
      else:
        vm.push(vm.program.consts[op.a], kInt)
    of opLoad:
      case op.b
      of 0:
        vm.push(vm.globals[op.a], vm.globalKind[op.a])
      of 1:
        let base = vm.frames[^1].base
        vm.push(vm.locals[base + op.a], vm.localKind[base + op.a])
      else:
        vm.fail(line, "undefined variable '" & vm.program.names[op.a] & "'")
        return
    of opStore:
      let value = vm.popValue()
      case op.b
      of 0:
        vm.globals[op.a] = value.value
        vm.globalKind[op.a] = value.kind
      of 1:
        let base = vm.frames[^1].base
        vm.locals[base + op.a] = value.value
        vm.localKind[base + op.a] = value.kind
      else:
        vm.fail(line, "undefined variable '" & vm.program.names[op.a] & "'")
        return
    of opIndex:
      if op.a == 0:
        let indexValue = vm.popValue()
        let arrayValue = vm.popValue()
        if arrayValue.kind != kArray:
          vm.fail(line, "indexing a value that is not an array")
          return
        if indexValue.kind != kInt:
          vm.fail(line, "an array index must be an integer")
          return
        let entry = vm.arrays[int(arrayValue.value)]
        if indexValue.value < 0 or indexValue.value >= entry.len:
          vm.fail(line, "array index " & $indexValue.value &
            " out of range 0.." & $(entry.len - 1))
          return
        vm.push(entry[int(indexValue.value)], kInt)
      else:
        let value = vm.popValue()
        let indexValue = vm.popValue()
        let arrayValue = vm.popValue()
        if arrayValue.kind != kArray:
          vm.fail(line, "indexing a value that is not an array")
          return
        if indexValue.kind != kInt or value.kind != kInt:
          vm.fail(line, "an array holds integers indexed by an integer")
          return
        if indexValue.value < 0 or
            indexValue.value >= vm.arrays[int(arrayValue.value)].len:
          vm.fail(line, "array index " & $indexValue.value &
            " out of range 0.." & $(vm.arrays[int(arrayValue.value)].len - 1))
          return
        vm.arrays[int(arrayValue.value)][int(indexValue.value)] = value.value
    of opBin:
      let right = vm.popValue()
      let left = vm.popValue()
      let op2 = BinOp(op.a)
      case op2
      of bEq, bNe:
        if left.kind != right.kind or left.kind == kArray:
          vm.fail(line, "cannot compare values of different types")
          return
        let equal = left.value == right.value
        vm.push((if (op2 == bEq) == equal: 1 else: 0), kBool)
      of bLt, bLe, bGt, bGe:
        if left.kind != kInt or right.kind != kInt:
          vm.fail(line, "an ordering comparison needs two integers")
          return
        let outcome =
          case op2
          of bLt: left.value < right.value
          of bLe: left.value <= right.value
          of bGt: left.value > right.value
          else: left.value >= right.value
        vm.push((if outcome: 1 else: 0), kBool)
      else:
        if left.kind != kInt or right.kind != kInt:
          vm.fail(line, "arithmetic needs two integers")
          return
        var ok = true
        var value: GwlValue = 0
        case op2
        of bAdd: value = addChecked(left.value, right.value, ok)
        of bSub: value = subChecked(left.value, right.value, ok)
        of bMul: value = mulChecked(left.value, right.value, ok)
        of bDiv:
          if right.value == 0:
            vm.fail(line, "division by zero")
            return
          if left.value == low(int64) and right.value == -1:
            ok = false
          else:
            value = left.value div right.value
        else:
          if right.value == 0:
            vm.fail(line, "modulo by zero")
            return
          if left.value == low(int64) and right.value == -1:
            value = 0
          else:
            value = left.value mod right.value
        if not ok:
          vm.fail(line, "integer overflow")
          return
        vm.push(value, kInt)
    of opUn:
      let value = vm.popValue()
      case UnOp(op.a)
      of uNeg:
        if value.kind != kInt:
          vm.fail(line, "unary '-' needs an integer")
          return
        if value.value == low(int64):
          vm.fail(line, "integer overflow")
          return
        vm.push(-value.value, kInt)
      of uNot:
        if value.kind != kBool:
          vm.fail(line, "'not' needs a boolean")
          return
        vm.push(1 - value.value, kBool)
      of uAssertBool:
        if value.kind != kBool:
          vm.fail(line, "'and'/'or' need booleans")
          return
        vm.push(value.value, kBool)
    of opCall:
      if op.a < 0:
        let name = vm.program.names[-1 - op.a]
        vm.fail(line, "undefined proc '" & name & "'")
        return
      if op.a >= BuiltinBase:
        let target = op.a - BuiltinBase
        if op.b != vm.program.procArity[target]:
          vm.fail(line, "proc '" & vm.program.procName[target] & "' takes " &
            $vm.program.procArity[target] & " arguments, got " & $op.b)
          return
        if vm.frames.len >= MaxCallDepth:
          vm.fail(line, "call depth exceeded (" & $MaxCallDepth & ")")
          return
        let base = vm.locals.len
        for _ in 0 ..< op.b:
          vm.locals.add(0)
          vm.localKind.add(kInt)
        for index in countdown(op.b - 1, 0):
          let value = vm.popValue()
          vm.locals[base + index] = value.value
          vm.localKind[base + index] = value.kind
        vm.frames.add(Frame(returnPc: vm.pc, base: base, count: op.b))
        vm.pc = vm.program.procEntry[target]
      else:
        let builtin = Builtin(op.a)
        let arity = BuiltinArity[builtin]
        if arity >= 0 and op.b != arity:
          vm.fail(line, BuiltinNames[builtin] & "() takes " & $arity &
            " arguments, got " & $op.b)
          return
        if builtin == fArray:
          var entry = newSeq[GwlValue](op.b)
          for index in countdown(op.b - 1, 0):
            let value = vm.popValue()
            if value.kind != kInt:
              vm.fail(line, "an array literal holds integers")
              return
            entry[index] = value.value
          var slot = vm.arraySlot[vm.pc - 1]
          if slot < 0:
            if vm.liveElements() + entry.len > MaxArrayElements:
              vm.fail(line, "allocation limit exceeded (" &
                $MaxArrayElements & " array elements)")
              return
            vm.arrays.add(entry)
            slot = vm.arrays.high
            vm.arraySlot[vm.pc - 1] = slot
          else:
            vm.arrays[slot] = entry
          vm.push(GwlValue(slot), kArray)
        else:
          var args: array[2, tuple[value: GwlValue, kind: int8]]
          for index in countdown(op.b - 1, 0):
            args[index] = vm.popValue()
          for index in 0 ..< op.b:
            if args[index].kind == kBool:
              vm.fail(line, BuiltinNames[builtin] &
                "() does not take a boolean")
              return
          let arg0 = args[0].value
          let arg1 = args[1].value
          case builtin
          of fCheck, fWho:
            if args[0].kind != kInt or args[1].kind != kInt:
              vm.fail(line, BuiltinNames[builtin] & "() needs two integers")
              return
            vm.push((if builtin == fCheck: checkAt(view, arg0, arg1)
                     else: whoAt(view, arg0, arg1)), kInt)
          of fX: vm.push(GwlValue(view.x), kInt)
          of fY: vm.push(GwlValue(view.y), kInt)
          of fTiles: vm.push(GwlValue(view.tiles), kInt)
          of fEnergy: vm.push(GwlValue(view.energy), kInt)
          of fTick: vm.push(GwlValue(view.tick), kInt)
          of fId: vm.push(GwlValue(view.id), kInt)
          of fBombCost: vm.push(GwlValue(view.bombCost), kInt)
          of fAlive:
            vm.push((if arg0 >= 1 and arg0 <= 4 and view.alive[int(arg0)]: 1
                     else: 0), kInt)
          of fRand:
            if arg0 <= 0:
              vm.fail(line, "rand(n) needs n > 0, got " & $arg0)
              return
            vm.push(GwlValue(vm.nextRandom() mod uint64(arg0)), kInt)
          of fAbs:
            if arg0 == low(int64):
              vm.fail(line, "integer overflow")
              return
            vm.push(abs(arg0), kInt)
          of fMin: vm.push(min(arg0, arg1), kInt)
          of fMax: vm.push(max(arg0, arg1), kInt)
          of fLen:
            if args[0].kind != kArray:
              vm.fail(line, "len() needs an array")
              return
            vm.push(GwlValue(vm.arrays[int(args[0].value)].len), kInt)
          of fXor: vm.push(arg0 xor arg1, kInt)
          of fShl:
            if arg1 < 0 or arg1 > 62:
              vm.fail(line, "shl needs a shift of 0..62")
              return
            vm.push(arg0 shl arg1, kInt)
          of fShr:
            if arg1 < 0 or arg1 > 62:
              vm.fail(line, "shr needs a shift of 0..62")
              return
            vm.push(arg0 shr arg1, kInt)
          of fMod:
            if arg1 == 0:
              vm.fail(line, "modulo by zero")
              return
            vm.push((if arg0 == low(int64) and arg1 == -1: GwlValue(0)
                     else: arg0 mod arg1), kInt)
          of fDiv:
            if arg1 == 0:
              vm.fail(line, "division by zero")
              return
            if arg0 == low(int64) and arg1 == -1:
              vm.fail(line, "integer overflow")
              return
            vm.push(arg0 div arg1, kInt)
          of fArray: discard
    of opJump:
      vm.pc = op.a
    of opJumpFalse:
      let value = vm.popValue()
      if value.kind != kBool:
        vm.fail(line, "a condition must be a boolean, not an integer")
        return
      if value.value == 0:
        vm.pc = op.a
    of opEnter:
      let frame = vm.frames[^1]
      while vm.locals.len < frame.base + op.a:
        vm.locals.add(0)
        vm.localKind.add(kInt)
      vm.frames[^1].count = op.a
    of opLeave:
      for _ in 0 ..< op.a:
        discard vm.popValue()
    of opReturn:
      let value = vm.popValue()
      let frame = vm.frames.pop()
      vm.locals.setLen(frame.base)
      vm.localKind.setLen(frame.base)
      vm.pc = frame.returnPc
      vm.push(value.value, value.kind)
    of opAction:
      result.kind = ActionKind(op.a)
      result.line = line
      if result.kind == akMove:
        let dy = vm.popValue()
        let dx = vm.popValue()
        if dx.kind != kInt or dy.kind != kInt:
          vm.fail(line, "move() needs two integers")
          return GwlAction(kind: akNone, line: 0)
        result.dx = dx.value
        result.dy = dy.value
      return
    of opHalt:
      vm.halted = true
      return
  ## The budget ran out before an action: the tick counts as wait() and the
  ## VM stays suspended exactly where it is.
  let stallLine =
    if vm.pc >= 0 and vm.pc < vm.program.ops.len: vm.program.ops[vm.pc].line
    else: 0
  result = GwlAction(kind: akWait, line: stallLine, stalled: true)
