## Re-derive complete recorded matches through the production replay engine.
import std/[json, os]
import gridwars/sim

when isMainModule:
  doAssert paramCount() == 1, "usage: verify_replay REPLAY"
  let replay = parseFile(paramStr(1))
  var config = defaultGameConfig()
  config.update($replay["config"])
  var events: seq[GameEvent]
  var battles = 0
  for node in replay["events"]:
    let event = eventFromJson(node)
    events.add(event)
    if event.kind == evBattle: inc battles
  doAssert replay["results"]["reason"].getStr() == "complete"
  doAssert battles == config.rounds
  let frames = replayMatch(config, events)
  doAssert frames.len > 0
  echo $(%*{"rounds": battles, "frames": frames.len, "replay_verified": true})
