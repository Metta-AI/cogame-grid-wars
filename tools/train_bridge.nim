import gridwars/prompts
## JSONL numeric bridge over native Grid Wars rounds.

import std/[hashes, json, os, strutils]
import gridwars/[sim, llm]

const Kinds = [skPainter, skBomber, skSentry]

var
  game: Sim
  decisionId: int
  manifestPath: string
  variant: string
  textMode: bool
  selection: PromptSelection

proc currentDecision(): JsonNode =
  let seat = game.pendingSeats()[0]
  let system = systemPrompt(game, seat, selection)
  let user = userPrompt(game, seat, "")
  %*{"kind": "decision", "game": "grid-wars",
    "decision_id": decisionId, "seat": seat, "engine_seat": seat,
    "turn": game.round,
    "semantic_view": {"system": system, "user": user, "prompt_template": selection.promptMetadata(system, user)},
    "inbox": [], "messages": [
      {"role": "system", "content": system},
      {"role": "user", "content": user}],
    "speech_messages": [],
    "action_schema": (if textMode: %*{"type": "object", "required": ["script"],
      "properties": {"script": {"type": "array"}, "notes": {"type": "string"}, "banner": {"type": "string"}}}
      else: %*{"type": "object", "properties": {
      "choice": {"type": "integer", "minimum": 0, "maximum": 2}},
      "required": ["choice"]}), "typed_question": newJNull()}

proc reset(command: JsonNode): JsonNode =
  doAssert command["players"].getInt() == Seats
  selection = promptSelection(command)
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference} and
      (not command.hasKey("split") or command["split"].getStr() notin ["evaluation", "validation", "test"]):
    raise newException(ValueError, "held-out wording requires an explicit evaluation split")
  let manifest = parseFile(manifestPath)
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  variantConfig["seed"] = %(hash(command["seed"].getStr()) and 0x7FFFFFFF)
  var config = defaultGameConfig()
  config.update($variantConfig)
  config = config.sampleEpisode()
  game = initSim(config)
  decisionId = 0
  currentDecision()

proc bounded(value: float): float = value / (abs(value) + 100.0)

proc encode(): JsonNode =
  let seat = game.pendingSeats()[0]
  var values = newJArray()
  for name in ["standard", "blitz"]:
    values.add(%(if variant == name: 1 else: 0))
  for player in 0 ..< Seats:
    values.add(%(if seat == player: 1 else: 0))
  values.add(%(float(game.round) / float(game.config.rounds)))
  values.add(%(float(game.config.ticks) / float(MaxTicks)))
  values.add(%(float(game.config.bombCost) / 60.0))
  values.add(%(float(game.roundsPlayed) / float(game.config.rounds)))
  var board: seq[char]
  if game.history.len > 0:
    for line in game.history[^1].ascii.splitLines():
      for glyph in line: board.add(glyph)
    doAssert board.len == Cells
  for slot in 0 ..< Cells:
    values.add(%(if board.len > 0: float(ord(board[slot])) / 126.0
      else: 0.0))
  for player in 0 ..< Seats:
    values.add(%(if game.history.len > 0: bounded(game.score(player))
      else: 0.0))
    values.add(%(if game.history.len > 0:
      float(game.history[^1].stat[player].tiles) / float(Cells)
      else: 0.0))
    values.add(%(if game.history.len > 0 and
      game.history[^1].stat[player].alive: 1 else: 0))
  if game.history.len == 0:
    for unused in 0 ..< 8: values.add(%0.0)
  else:
    let stat = game.history[^1].stat[seat]
    values.add(%(float(stat.ticksLived) / float(game.config.ticks)))
    values.add(%(float(stat.kills) / 4.0))
    values.add(%(float(stat.illegal) / float(game.config.ticks)))
    values.add(%(float(stat.blocked) / float(game.config.ticks)))
    values.add(%(float(stat.refused) / float(game.config.ticks)))
    values.add(%(float(stat.stalls) / float(game.config.ticks)))
    values.add(%(float(stat.faultLine) / float(MaxScriptLines)))
    values.add(%bounded(stat.roundScore))
  for kind in Kinds:
    values.add(%(if game.scripts[seat] == warriorLines(kind): 1 else: 0))
  doAssert values.len == 933
  %*{"decision_id": decisionId, "values": values,
    "actions": [{"choice": 0}, {"choice": 1}, {"choice": 2}]}

proc step(command: JsonNode): JsonNode =
  if command["decision_id"].getInt() != decisionId:
    return %*{"kind": "rejected", "reason": "stale decision"}
  let action = parseJson(command["response"].getStr())
  let seat = game.pendingSeats()[0]
  let submission = if textMode: parseSubmission(action) else:
    let choice = action["choice"].getInt()
    doAssert choice in 0 .. 2
    scriptedSubmission(Kinds[choice])
  game.submit(seat, submission.script, submission.notes, submission.banner,
    submission.origin)
  inc decisionId
  let observation = if game.done:
    var scores = newJObject()
    var utilities = newJObject()
    for player in 0 ..< Seats:
      let score = game.score(player)
      scores[$player] = %score
      utilities[$player] = %bounded(score)
    %*{"kind": "terminal", "scores": scores,
      "utilities": utilities}
  else: currentDecision()
  %*{"kind": "accepted", "action": (if textMode: submissionJson(submission) else: action), "observation": observation}

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 3:
    quit("usage: grid-wars-train-bridge MANIFEST VARIANT [text]", 1)
  manifestPath = absolutePath(args[0])
  variant = args[1]
  textMode = args.len == 3 and args[2] == "text"
  doAssert variant in ["standard", "blitz"]
  for line in stdin.lines:
    let command = parseJson(line)
    let response = case command["kind"].getStr()
      of "reset": reset(command)
      of "encode": encode()
      of "teacher": %*{"response": $(if textMode: submissionJson(scriptedSubmission(skPainter)) else: %*{"choice": 0})}
      of "step": step(command)
      else: raise newException(ValueError, "unknown command")
    stdout.writeLine($response)
    stdout.flushFile()
