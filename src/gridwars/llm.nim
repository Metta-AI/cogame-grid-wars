## Claude-backed warrior authoring for Grid Wars. Each seat's policy is
## just a prompt: the game server composes the seat's view (its alias, its
## own script with line numbers, its own diagnostics, the series table and
## the previous round's board) plus that seat's prompt, and asks Claude for
## a complete warrior program.
##
## All four seats submit simultaneously by rule, so the four requests go out
## as ONE parallel batch (curly.makeRequests) per round — never
## sequentially. A reply that fails to parse or fails to COMPILE is retried
## once, in a second batch, with the exact parser or compiler message; a
## seat still failing plays the `sentry` fallback so the episode always
## advances.
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With no credentials every seat plays a built-in warrior immediately (no
## retries, no network waits) so offline certification still completes —
## this fallback is load-bearing.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  sim

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"
  WarriorDir = currentSourcePath().parentDir().parentDir().parentDir() /
    "data" / "warriors"
  PainterSource* = staticRead(WarriorDir / "painter.gwl")
  BomberSource* = staticRead(WarriorDir / "bomber.gwl")
  SentrySource* = staticRead(WarriorDir / "sentry.gwl")

type
  ScriptKind* = enum
    skNone = "none"
    skPainter = "painter"
    skBomber = "bomber"
    skSentry = "sentry"

  Submission* = object
    script*: seq[string]
    notes*: string      ## "" when the reply carried none
    banner*: string
    origin*: string     ## "llm" | "retry" | "fallback" | "scripted"
    rejected*: string   ## fallback only: why the seat's own reply was refused

  LlmTransport = enum
    ltNone, ltBedrock, ltAnthropic

  LlmClient* = ref object
    curl: Curly
    transport: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model: string
    maxOutputTokens: int
    timeoutSeconds: int
    disabled*: bool       ## true once credentials are known-unavailable
    batchesUsed*: int     ## batches issued for the last decideAll

proc parseScriptKind*(text: string): ScriptKind =
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "painter": skPainter
  of "bomber": skBomber
  of "sentry": skSentry
  else: skNone

proc warriorLines*(kind: ScriptKind): seq[string] =
  let source =
    case kind
    of skBomber: BomberSource
    of skSentry, skNone: SentrySource
    else: PainterSource
  for line in source.splitLines():
    result.add(line)
  while result.len > 0 and result[^1].strip().len == 0:
    discard result.pop()

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    echo "grid-wars llm: failed to fetch ANTHROPIC_API_KEY_URI: ", error.msg
    result = ""

proc bedrockModelIds(): seq[string] =
  ## Haiku leads: hosted Bedrock capacity is shared account-wide and the
  ## sonnet profiles run out of daily tokens first.
  ## `us.anthropic.claude-sonnet-4-6` is deliberately NOT a candidate — it
  ## times out on every sidecar call, and one throttle then cascades into
  ## scripted fallbacks for the rest of the episode.
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @[
    "us.anthropic.claude-haiku-4-5-20251001-v1:0",
    "us.anthropic.claude-sonnet-4-5-20250929-v1:0",
  ]

proc tryNextBedrockModel(client: LlmClient, why: string): bool =
  if client.transport != ltBedrock or
      client.bedrockModel + 1 >= client.bedrockModels.len:
    return false
  client.bedrockModel.inc
  echo "grid-wars llm: ", client.bedrockModels[client.bedrockModel - 1],
    " unusable (", why, "); falling back to ",
    client.bedrockModels[client.bedrockModel]
  true

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    echo "grid-wars llm: bedrock transport, model ",
      result.bedrockModels[result.bedrockModel], ", url ", result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    echo "grid-wars llm: anthropic transport, model ", result.model
  else:
    result.transport = ltNone
    result.disabled = true
    echo "grid-wars llm: no LLM credentials; using scripted warriors"

# ---- Scripted baselines -----------------------------------------------------

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked, by
  ## the one shared truncation (`cutRunes`, gwl.nim): a byte slice through
  ## a multi-byte character leaves invalid UTF-8 in the replay.
  cutRunes(text.strip(), limit)


proc scriptedSubmission*(kind: ScriptKind): Submission =
  ## A scripted seat submits the SAME fixed warrior every round and never
  ## calls the model.
  Submission(
    script: warriorLines(if kind == skNone: skSentry else: kind),
    origin: "scripted"
  )

proc fallbackSubmission*(compileError: string): Submission =
  Submission(script: warriorLines(skSentry), origin: "fallback",
    rejected: cleanText(compileError, 300))

# ---- Prompts ----------------------------------------------------------------

const GwlReference* = """
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
"""

const TickOrder* = """
TICK RESOLUTION ORDER, every tick:
  1. Priority rotates: seats (0+t) mod 4, (1+t) mod 4, ... — no seat has a
     structural first-mover advantage; all ties resolve in that order.
  2. Decision pass. Every living warrior runs until it reaches an action or
     spends its instruction budget. THE BOARD IS NOT MUTATED IN THIS PASS:
     every check/who in tick t reads the board as it stood at the end of
     tick t-1, for everyone.
  3. Bomb pass, 4. Place pass, 5. Move pass — in priority order. A move is
     BLOCKED (you stay put) by a live bomb, a corpse, or a living warrior,
     including one that moved there earlier in this same pass.
  6. Fuses tick down. 7. Bombs at fuse 0 detonate: the bomb's cell plus its
     four orthogonal neighbours, wrapping. Every blast cell is SCORCHED
     (its owner reset, its bomb consumed) and every warrior in it dies.
     Bombs caught in a blast join the same wave — chain reactions resolve
     to closure.
  8. Idle: 50 ticks without changing cell kills you.
  9. Faults kill.
 10. A dead warrior's tiles all revert to unclaimed, immediately.
     Survivors gain 1 + tiles div 60 energy, capped at 60.
 11. The round ends at the tick horizon, or when one warrior is left, or
     when none is.
"""

proc systemPrompt*(sim: Sim, seat: int): string =
  result.add("You are " & sim.names[seat] & ", warrior id " & $(seat + 1) &
    " (" & ColorNames[seat] & "), one of four cogs fighting for a 30x30 " &
    "toroidal grid in Grid Wars.\n\n")
  result.add("""THE GAME
- You do not move a warrior. You WRITE one: a complete program in GWL, the
  language below. The engine runs it, one action per tick, for the whole
  battle. You get to rewrite it between rounds and nothing else.
- x and y wrap: the board is a torus, 30 by 30.
- Every cell has an owner (0 unclaimed, else a warrior id), at most one
  live bomb, and a permanent corpse flag. place() claims the cell you
  stand on, overwriting whoever owned it.
- You start with 12 energy and gain 1 + tiles div 60 each tick, capped at
  60. bomb() costs BOMBCOST energy. A live bomb is a WALL as well as a
  weapon: nobody can walk into it.
- A bomb is planted with a fuse of MAXFUSE (5) and its fuse drops by 1 in
  the SAME tick it was planted, so a bomb planted on tick t detonates on
  tick t+4 — five ticks of life counting the one it was planted on. The
  blast is a plus of 5 cells that wraps. Every cell in the blast loses its owner; every warrior in it dies
  and leaves a permanent corpse. Bombs caught in a blast chain.
- 50 ticks without changing cell kills you. So does a fault.
- When a warrior dies, EVERY tile it owned reverts to unclaimed at once.

SCORING (zero-sum, higher is better, the four scores sum to zero)
  raw        = tiles + 100 if alive at the end + 50 per kill - 50 per self-kill
  roundScore = raw - (the four raws) / 4
  score      = the mean roundScore over the rounds played
Territory is the score, but survival is worth 100 tiles and a dead warrior
owns nothing.

You never see another warrior's source code, before or after a round. You
see the board, and you can infer.
""")
  result.add("\n" & TickOrder & "\n" & GwlReference & "\n")
  result.add("""
OUTPUT FORMAT: reply with ONLY one JSON object, nothing else — no analysis,
no explanation, no markdown fences, no text before or after the object.
Your reply must begin with the character { and end with }. "script" must be
an ARRAY OF LINES (each element one source line, indentation preserved as
leading spaces), at most 120 lines of at most 100 characters. Your program
must be a complete warrior: if it runs off the end it stops acting and dies
to the idle rule, so wrap your behaviour in `while true:`.

  {"script": ["var dx = 1", "var dy = 0", "while true:", "  place()",
   "  move(dx, dy)"],
   "notes": "private, fed back to you next round",
   "banner": "one line the spectators see"}
""")

proc operatorBlock*(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  result.add(sim.seatObservation(seat))
  result.add(operatorBlock(prompt))
  result.add("Reply with ONLY {\"script\": [\"line\", \"line\", ...], " &
    "\"notes\": \"…\", \"banner\": \"…\"} — script at most " &
    $MaxScriptLines & " lines of at most " & $MaxLineChars &
    " characters, notes at most " & $MaxNotesLen &
    " characters, banner at most " & $MaxBannerLen & " characters.")

# ---- Reply parsing ----------------------------------------------------------

proc stripFences*(text: string): string =
  ## Drops a leading UTF-8 BOM and a wrapping markdown fence, whatever
  ## language tag it carries.
  result = text
  if result.len >= 3 and result[0 .. 2] == "\xEF\xBB\xBF":
    result = result[3 .. ^1]
  result = result.strip()
  if result.startsWith("```"):
    let firstBreak = result.find('\n')
    if firstBreak > 0:
      result = result[firstBreak + 1 .. ^1]
    else:
      result = result[3 .. ^1]
    let closing = result.rfind("```")
    if closing >= 0:
      result = result[0 ..< closing]
  result = result.strip()

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating
  ## fences and trailing prose after the closing brace.
  let cleaned = stripFences(text)
  let start = cleaned.find('{')
  let stop = cleaned.rfind('}')
  if start < 0 or stop <= start:
    let head = cutRunes(cleaned.strip(), 160)
    raise newException(GridWarsError, "no JSON object in response: " &
      head.replace("\n", " "))
  parseJson(cleaned[start .. stop])

proc normaliseScript*(node: JsonNode): seq[string] =
  ## The array-of-lines form is canonical because it removes the single
  ## most common JSON failure — a literal newline inside a JSON string —
  ## but the string form is accepted, and a fence inside the value is
  ## stripped either way.
  if node.isNil or node.kind == JNull:
    raise newException(GridWarsError, "no script in response")
  var raw: seq[string]
  case node.kind
  of JArray:
    for item in node:
      if item.kind == JString:
        for piece in item.getStr().split('\n'):
          raw.add(piece)
      else:
        raise newException(GridWarsError,
          "script must be an array of source lines")
  of JString:
    for piece in stripFences(node.getStr()).split('\n'):
      raw.add(piece)
  else:
    raise newException(GridWarsError,
      "script must be an array of source lines")
  ## A fence may wrap the whole array too.
  while raw.len > 0 and raw[0].strip().startsWith("```"):
    raw.delete(0)
  while raw.len > 0 and raw[^1].strip().startsWith("```"):
    discard raw.pop()
  for line in raw:
    var text = line.replace("\t", "  ").replace("\r", "")
    while text.len > 0 and text[^1] == ' ':
      text.setLen(text.len - 1)
    result.add(text)
  while result.len > 0 and result[^1].strip().len == 0:
    discard result.pop()
  if result.len == 0:
    raise newException(GridWarsError, "the script is empty")

proc parseSubmission*(payload: JsonNode): Submission =
  result.notes = cleanText(payload{"notes"}.getStr(), MaxNotesLen)
  result.banner = cleanText(payload{"banner"}.getStr().replace("\n", " "),
    MaxBannerLen)
  result.script = capScript(normaliseScript(payload{"script"}))
  result.origin = "llm"
  ## Compile here so the retry can carry the compiler's own message —
  ## the single most valuable feedback in the game, and it is specific.
  discard compile(result.script)

# ---- Transport --------------------------------------------------------------

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## Only the Claude 5 / Opus tiers accept an effort setting; Haiku 4.5
    ## rejects the whole request with a 400 if it is present.
    if "haiku" notin client.model and "4-5" notin client.model:
      body["output_config"] = %*{"effort": "low"}
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string): string =
  if error.len > 0:
    raise newException(GridWarsError, "llm transport: " & error)
  if response.code == 401 or response.code == 403:
    let detail = cutRunes(response.body, 400)
    if "Model access is denied" in response.body and
        client.tryNextBedrockModel("no model access"):
      raise newException(GridWarsError, "bedrock model access denied: " & detail)
    client.disabled = true
    raise newException(GridWarsError,
      "llm auth failed (" & $response.code & ") at " & url & ": " & detail)
  if response.code == 429:
    let detail = cutRunes(response.body, 300)
    discard client.tryNextBedrockModel("throttled")
    raise newException(GridWarsError, "llm throttled (429): " & detail)
  if response.code < 200 or response.code >= 300:
    raise newException(GridWarsError, "anthropic error " & $response.code &
      ": " & cutRunes(response.body, 300))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(GridWarsError, "anthropic refusal")
  for contentBlock in payload["content"]:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(GridWarsError, "reply cut off at max_tokens before " &
      "any JSON: " & cutRunes(result, 160).replace("\n", " "))

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Submission] =
  ## One submission per seat in `seats`, in order. Never raises: any
  ## failure ends at the `sentry` fallback so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  result = newSeq[Submission](seats.len)
  client.batchesUsed = 0
  var open: seq[int]        ## indexes into `seats` still undecided
  var why = newSeq[string](seats.len)
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone:
      result[index] = scriptedSubmission(kind)
    elif client.disabled:
      result[index] = scriptedSubmission(skSentry)
    else:
      open.add(index)
  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    inc client.batchesUsed
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\n\nYour previous reply was rejected: " &
          cleanText(why[index], 300) &
          ". Reply with ONLY the JSON object.")
      let request = client.requestFor(systemPrompt(sim, seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    let responses = client.curl.makeRequests(batch, client.timeoutSeconds)
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        var submission = parseSubmission(extractJsonObject(text))
        submission.origin = (if attempt == 0: "llm" else: "retry")
        result[index] = submission
      except GwlCompileError as error:
        why[index] = error.msg
        echo "grid-wars llm: seat ", seat, " attempt ", attempt,
          " did not compile: ", error.msg
        stillOpen.add(index)
      except CatchableError as error:
        why[index] = error.msg
        echo "grid-wars llm: seat ", seat, " attempt ", attempt, " failed: ",
          error.msg
        stillOpen.add(index)
    open = stillOpen
  for index in open:
    let seat = seats[index]
    echo "grid-wars llm: seat ", seat, " falling back to the sentry warrior"
    result[index] = fallbackSubmission(why[index])
