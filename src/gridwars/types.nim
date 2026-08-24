## Shared value types for Grid Wars: the runtime config, the event log
## vocabulary and the per-seat round statistics. No rules live here.

import std/[json, strutils]

type
  GridWarsError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int64          ## int64, not platform int: the wasm viewer reads it too
    rounds*: int          ## script-submission rounds in the series
    ticks*: int           ## ticks in one battle
    bombCost*: int        ## energy a bomb() costs
    episodeTimeoutSeconds*: int ## assumed platform kill time when the env is silent
    sampled*: bool        ## true once the budget cap has been applied
    roundDelayMs*: int
    playerConnectTimeoutSeconds*: float
    model*: string
    maxOutputTokens*: int
    llmTimeoutSeconds*: int

  SeatStat* = object
    ## One seat's outcome for one battle.
    tiles*: int
    peakTiles*: int
    kills*: int
    selfKills*: int
    alive*: bool
    deathTick*: int      ## -1 when it survived
    deathCause*: string  ## "" | "bomb" | "idle" | "fault"
    faultLine*: int
    faultText*: string
    illegal*: int
    blocked*: int
    refused*: int
    stalls*: int
    ticksLived*: int
    raw*: int
    roundScore*: float

  EventKind* = enum
    evStart = "start"
    evRound = "round"
    evSubmit = "submit"
    evBattle = "battle"
    evEnd = "end"

  GameEvent* = object
    ## Flat, JSON-round-trippable. The per-tick history is NOT recorded:
    ## every tick is re-derived from `seed` + `spawn` + the submitted
    ## scripts, and the recorded `digest` proves the re-derivation.
    kind*: EventKind
    round*: int              ## round/submit/battle: the round; end: rounds played
    seat*: int               ## submit: the submitting seat; -1 otherwise
    seed*: int64             ## round: the round's derived seed; -1 otherwise
    spawn*: seq[int]         ## round: seat -> spawn cell index
    ticks*: int              ## round: ticks in this battle; -1 otherwise
    script*: seq[string]     ## submit: the capped source lines
    lines*: int              ## submit: script.len; -1 otherwise
    origin*: string          ## submit: llm | retry | fallback | scripted
    compileError*: string    ## submit: "" when the script compiled
    banner*: string          ## submit: the spectator-only banner
    scripted*: bool          ## submit: the seat is a scripted baseline
    text*: string            ## submit: the seat's notes; end: the reason
    ticksPlayed*: int        ## battle: ticks actually run; -1 otherwise
    reason*: string          ## battle: horizon | lastStanding | wipeout
    stats*: seq[SeatStat]    ## battle: one per seat
    curve*: seq[seq[int]]    ## battle: tile counts sampled every 25 ticks
    digest*: string          ## battle: FNV-1a 64 of the final board, hex

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    seed: 0,
    rounds: 5,
    ticks: 400,
    bombCost: 12,
    episodeTimeoutSeconds: 1200,
    roundDelayMs: 250,
    playerConnectTimeoutSeconds: 180,
    model: "claude-sonnet-5",
    maxOutputTokens: 2400,
    llmTimeoutSeconds: 60
  )

proc update*(config: var GameConfig, configJson: string) =
  ## Applies a runtime JSON config on top of the defaults.
  if configJson.strip().len == 0:
    return
  let node = parseJson(configJson)
  if node.kind != JObject:
    raise newException(GridWarsError, "config must be a JSON object")
  if node.hasKey("tokens"):
    config.tokens = @[]
    for token in node["tokens"]:
      config.tokens.add(token.getStr())
  if node.hasKey("players"):
    config.players = @[]
    for player in node["players"]:
      config.players.add(PlayerConfig(name: player["name"].getStr()))
  if node.hasKey("seed"):
    config.seed = node["seed"].getBiggestInt()
  if node.hasKey("rounds"):
    config.rounds = node["rounds"].getInt()
  if node.hasKey("ticks"):
    config.ticks = node["ticks"].getInt()
  if node.hasKey("bombCost"):
    config.bombCost = node["bombCost"].getInt()
  if node.hasKey("episodeTimeoutSeconds"):
    config.episodeTimeoutSeconds = node["episodeTimeoutSeconds"].getInt()
  if node.hasKey("sampled"):
    config.sampled = node["sampled"].getBool()
  if node.hasKey("roundDelayMs"):
    config.roundDelayMs = node["roundDelayMs"].getInt()
  if node.hasKey("player_connect_timeout_seconds"):
    config.playerConnectTimeoutSeconds =
      node["player_connect_timeout_seconds"].getFloat()
  if node.hasKey("model"):
    config.model = node["model"].getStr()
  if node.hasKey("maxOutputTokens"):
    config.maxOutputTokens = node["maxOutputTokens"].getInt()
  if node.hasKey("llmTimeoutSeconds"):
    config.llmTimeoutSeconds = node["llmTimeoutSeconds"].getInt()

proc statJson*(stat: SeatStat): JsonNode =
  %*{
    "tiles": stat.tiles,
    "peakTiles": stat.peakTiles,
    "kills": stat.kills,
    "selfKills": stat.selfKills,
    "alive": stat.alive,
    "deathTick": stat.deathTick,
    "deathCause": stat.deathCause,
    "faultLine": stat.faultLine,
    "faultText": stat.faultText,
    "illegal": stat.illegal,
    "blocked": stat.blocked,
    "refused": stat.refused,
    "stalls": stat.stalls,
    "ticksLived": stat.ticksLived,
    "raw": stat.raw,
    "roundScore": stat.roundScore
  }

proc statFromJson*(node: JsonNode): SeatStat =
  SeatStat(
    tiles: node{"tiles"}.getInt(),
    peakTiles: node{"peakTiles"}.getInt(),
    kills: node{"kills"}.getInt(),
    selfKills: node{"selfKills"}.getInt(),
    alive: node{"alive"}.getBool(),
    deathTick: node{"deathTick"}.getInt(-1),
    deathCause: node{"deathCause"}.getStr(""),
    faultLine: node{"faultLine"}.getInt(),
    faultText: node{"faultText"}.getStr(""),
    illegal: node{"illegal"}.getInt(),
    blocked: node{"blocked"}.getInt(),
    refused: node{"refused"}.getInt(),
    stalls: node{"stalls"}.getInt(),
    ticksLived: node{"ticksLived"}.getInt(),
    raw: node{"raw"}.getInt(),
    roundScore: node{"roundScore"}.getFloat()
  )
