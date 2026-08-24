## Grid Wars entrypoint: reads the Coworld runtime contract and starts the
## live episode server. A recorded episode is NOT played by this container:
## the manifest declares the static wasm replay viewer bundle, which reads
## the `.replay` file from S3 and re-derives every frame in the browser.

import
  std/[json, sysrand],
  bitworld/runtime,
  gridwars/server,
  gridwars/sim

proc randomSeed(): int =
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(GridWarsError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc seedPinned(configJson: string): bool =
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed")
  except CatchableError:
    false

when isMainModule:
  let runtimeConfig = readRuntimeConfig()

  if runtimeConfig.replayMode:
    ## No pod plays replays. The static bundle does, from S3.
    quit("grid-wars: replay mode is not served by this container; the " &
      "static replay viewer bundle plays recorded episodes", 1)
  else:
    var config = defaultGameConfig()
    config.update(runtimeConfig.config)
    if not seedPinned(runtimeConfig.config):
      ## An unpinned seed is randomized so the spawn permutation, the
      ## per-warrior rand streams and the aliases are not precomputable.
      config.seed = randomSeed()
      echo "grid-wars: seed not pinned; randomized"
    ## Fit the caps AFTER the seed is settled, so a pinned seed reproduces
    ## the episode exactly.
    config = sampleEpisode(config)
    echo "grid-wars: seats=", config.players.len,
      " rounds=", config.rounds,
      " ticks=", config.ticks,
      " bombCost=", config.bombCost
    runGameServer(config, runtimeConfig)
