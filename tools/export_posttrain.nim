## Complete native series with the hosted prompts and parsed GWL replies.

import std/[json, os, osproc, strutils]
import gridwars/[sim, llm]

const Kinds = [skPainter, skBomber, skSentry]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: grid-wars-posttrain OUTPUT EPISODES VARIANT", 1)
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
    variantConfig["seed"] = %seed
    var config = defaultGameConfig()
    config.update($variantConfig)
    config = config.sampleEpisode()
    var game = initSim(config)
    var rows: seq[string]
    while not game.done:
      for seat in game.pendingSeats():
        let kind = Kinds[(seed + game.round + seat) mod Kinds.len]
        let script = warriorLines(kind)
        let reply = %*{"script": script, "notes": "", "banner": ""}
        let accepted = parseSubmission(reply)
        doAssert accepted.script == script
        rows.add($(%*{
          "episode_id": "grid-wars-" & variant & "-" & $seed,
          "seed": "grid-wars-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(game, seat)},
            {"role": "user", "content": userPrompt(game, seat, "")}
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
