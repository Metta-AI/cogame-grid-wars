## Stream complete private candidates; the shared importer owns review and splits.
import std/[json, os, osproc, strutils]
import gridwars/[sim, llm, prompts, evidence]

const Kinds = [skPainter, skBomber, skSentry]

when isMainModule:
  let args = commandLineParams()
  if args.len notin [3, 5]:
    quit("usage: grid-wars-posttrain OUTPUT EPISODES VARIANT [PROMPT_VARIANT PROMPT_SEED]", 1)
  let output = absolutePath(args[0])
  let episodes = parseInt(args[1])
  let variant = args[2]
  let selection = promptSelection(if args.len == 5:
    %*{"promptVariant": args[3], "promptSeed": parseInt(args[4])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert episodes >= 10
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  writePrivate(output / "execution.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let execution = open(output / "execution.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in 1 .. episodes:
      variantConfig["seed"] = %seed
      var config = defaultGameConfig()
      config.update($variantConfig)
      config = config.sampleEpisode()
      var game = initSim(config)
      let family = "grid-wars-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var count = 0
      while not game.done:
        let round = game.round
        let eventStart = game.events.len
        let seats = game.pendingSeats()
        var submissions: seq[Submission]
        var records: seq[JsonNode]
        for seat in seats:
          let kind = Kinds[(seed + round + seat) mod Kinds.len]
          let proposal = submissionJson(scriptedSubmission(kind))
          let submission = parseSubmission(proposal)
          submissions.add(submission)
          let system = systemPrompt(game, seat, selection)
          let user = userPrompt(game, seat, "")
          let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
          let attemptId = $count & "-teacher"
          records.add(%*{"schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $count, "decision_index": count, "game": "grid-wars",
            "game_version": "source-" & revision, "source_revision": revision, "seat": $seat,
            "visibility": "private", "observation": {"user": user,
              "prompt_template": selection.promptMetadata(system, user)},
            "prompt": messages, "attempts": [{"attempt_id": attemptId,
              "policy": "scripted-painter-bomber-sentry", "origin": "teacher", "inference_mode": "text_action",
              "prompt": messages, "response": $proposal, "parsed_action": proposal,
              "accepted": true, "rejection_reason": newJNull(), "request": newJNull(),
              "platform_call_id": newJNull(), "behavior_logprobs": newJNull()}],
            "selected_attempt_id": attemptId, "executed_action": proposal, "action_status": "accepted",
            "fallback_origin": newJNull(), "terminal": false})
          inc count
        for index, seat in seats:
          let submission = submissions[index]
          game.submit(seat, submission.script, submission.notes, submission.banner, "scripted")
        var events = newJArray()
        for index in eventStart ..< game.events.len: events.add(game.events[index].eventToJson())
        execution.writeLine($(%*{"event_type": "round_execution", "visibility": "private",
          "episode_id": episode, "round": round, "first_decision_id": count - seats.len,
          "events": events, "state": game.liveStateJson(), "terminal": game.done}))
        for index, seat in seats:
          let installed = %*{"script": game.history[^1].scripts[seat], "notes": game.history[^1].notes[seat], "banner": game.history[^1].banner[seat]}
          let proposed = records[index]["executed_action"]
          doAssert installed == proposed and game.history[^1].compileError[seat].len == 0,
            "Teacher candidate must match the actual accepted program"
          records[index]["terminal"] = %(game.done and index == seats.high)
          stream.writeLine($records[index])
      let results = game.resultsJson()
      doAssert game.roundsPlayed == config.rounds and results["reason"].getStr() == "complete"
      var participants = newJObject()
      for seat in 0 ..< Seats: participants[$seat] = %*{"score": results["scores"][seat]}
      stream.writeLine($(%*{"schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "grid-wars", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed", "outcome": results, "participant_outcomes": participants}))
      writePrivate(output / (episode & ".replay.json"), $game.replayJson() & "\n")
      runs.add(%*{"seed": seed, "rounds": game.roundsPlayed, "decisions": count,
        "scores": results["scores"], "reason": results["reason"], "replay": episode & ".replay.json"})
  finally:
    stream.close()
    execution.close()
  writePrivate(output / "manifest.json", pretty(%*{"schema_version": 1,
    "game": "grid-wars", "variant": variant, "source_revision": revision,
    "teacher": "scripted-painter-bomber-sentry", "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "execution_evidence": "execution.jsonl", "runs": runs}) & "\n")
  echo "complete games=", episodes
