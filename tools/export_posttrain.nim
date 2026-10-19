## Complete native series with the hosted prompts and parsed GWL replies.

import std/[json, os, osproc, strutils]
import gridwars/[sim, llm, prompts]

const Kinds = [skPainter, skBomber, skSentry]

when isMainModule:
  let args = commandLineParams()
  if args.len < 3 or args.len > 5:
    quit("usage: grid-wars-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  var promptConfig = newJObject()
  if args.len >= 4: promptConfig["promptVariant"] = %args[3]
  if args.len >= 5: promptConfig["promptSeed"] = %parseInt(args[4])
  let configured = promptSelection(promptConfig)
  if configured.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    quit("held-out wording cannot be exported for training", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    var selection = configured
    if selection.variant == pvMixed: selection.seed += seed - 1
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = config.sampleEpisode()
    var game = initSim(config)
    var rows: seq[string]
    while not game.done:
      let snapshot = game
      for seat in game.pendingSeats():
        let kind = Kinds[(seed + game.round + seat) mod Kinds.len]
        let script = warriorLines(kind)
        let reply = submissionJson(scriptedSubmission(kind))
        let accepted = parseSubmission(reply)
        doAssert accepted.script == script
        rows.add($(%*{
          "episode_id": "grid-wars-" & variant & "-" & $seed,
          "seed": "grid-wars-" & $seed,
          "prompt_template": selection.promptMetadata(systemPrompt(snapshot, seat, selection), userPrompt(snapshot, seat, "")),
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(snapshot, seat, selection)},
            {"role": "user", "content": userPrompt(snapshot, seat, "")}
          ],
          "completion": [{"role": "assistant", "content": $reply}],
          "game": "grid-wars",
          "action_schema_revision": "grid-wars-gwl-v1"
        }))
        game.submit(seat, accepted.script, accepted.notes, accepted.banner,
          "scripted")
    let results = game.resultsJson()
    doAssert game.roundsPlayed == config.rounds
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    runs.add(%*{"seed": seed, "rounds": game.roundsPlayed,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "grid-wars", "variant": variant,
    "source_revision": revision, "teacher": "painter-bomber-sentry",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
