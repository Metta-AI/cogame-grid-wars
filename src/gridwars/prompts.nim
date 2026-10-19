## Game-owned wording selection. Kept outside simulation/replay configuration.
import std/[json, strutils]
import crunchy

type
  PromptVariant* = enum
    pvCanonical = "canonical"
    pvPlain = "plain"
    pvNumbered = "numbered"
    pvQuestions = "questions"
    pvReordered = "reordered"
    pvHeldoutBriefing = "heldout-briefing"
    pvHeldoutReference = "heldout-reference"
    pvMixed = "mixed"
  PromptSelection* = object
    variant*: PromptVariant
    seed*: int

const
  PromptBankVersion* = "grid-wars-rules-v2"

proc promptSelection*(node: JsonNode): PromptSelection =
  if node.kind != JObject:
    raise newException(ValueError, "prompt configuration must be an object")
  if node.hasKey("promptVariant"):
    if node["promptVariant"].kind != JString:
      raise newException(ValueError, "promptVariant must be a string")
    result.variant = parseEnum[PromptVariant](node["promptVariant"].getStr())
  if node.hasKey("promptSeed"):
    if node["promptSeed"].kind != JInt:
      raise newException(ValueError, "promptSeed must be an integer")
    result.seed = node["promptSeed"].getInt()
  if result.seed < 0:
    raise newException(ValueError, "promptSeed must be nonnegative")
  if result.variant == pvMixed and not node.hasKey("promptSeed"):
    raise newException(ValueError, "mixed wording requires an explicit promptSeed")

proc selectedVariant*(selection: PromptSelection): PromptVariant =
  if selection.variant == pvMixed: PromptVariant(selection.seed mod 5)
  else: selection.variant

proc promptMetadata*(selection: PromptSelection, system, user: string): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed,
    "system_sha256": sha256(system).toHex, "user_sha256": sha256(user).toHex}

proc selectionMetadata*(selection: PromptSelection): JsonNode =
  %*{"bank": PromptBankVersion, "variant": $selection.selectedVariant,
    "selection": $selection.variant, "seed": selection.seed}

proc trainingIntroduction*(selection: PromptSelection, identity: string): string =
  case selection.selectedVariant
  of pvCanonical: "You are " & identity & ", one of four cogs fighting for a 30x30 toroidal grid in Grid Wars."
  of pvPlain: "In Grid Wars, you are " & identity & ", one of four cogs competing for a 30x30 toroidal grid."
  of pvNumbered: "1. You are " & identity & ". 2. Four cogs compete. 3. The arena is a 30x30 toroidal grid in Grid Wars."
  of pvQuestions: "Who are you? " & identity & ". Where do you compete? On a 30x30 toroidal grid in Grid Wars, against three other cogs."
  of pvReordered: "Four cogs fight for a 30x30 toroidal grid in Grid Wars. You are " & identity & "."
  of pvHeldoutBriefing: "Your Grid Wars role is " & identity & ". Compete with three other cogs for a 30x30 toroidal grid."
  of pvHeldoutReference: "Grid Wars arena: 30x30 toroidal grid. Competitors: four cogs. Your identity: " & identity & "."
  of pvMixed: raise newException(ValueError, "mixed must resolve")

proc nativeIntroduction*(selection: PromptSelection): string =
  case selection.selectedVariant
  of pvCanonical: "You write one complete GWL warrior program for Grid Wars."
  of pvPlain: "Your task in Grid Wars is to write one complete GWL warrior program."
  of pvNumbered: "1. Game: Grid Wars. 2. Task: write one complete GWL warrior program."
  of pvQuestions: "What do you write for Grid Wars? One complete GWL warrior program."
  of pvReordered: "For Grid Wars, write one complete warrior program in GWL."
  of pvHeldoutBriefing: "Prepare a complete GWL warrior program to participate in Grid Wars."
  of pvHeldoutReference: "Grid Wars assignment: author one complete GWL warrior program."
  of pvMixed: raise newException(ValueError, "mixed must resolve")

proc ordinaryIntroduction*(selection: PromptSelection): string =
  let first = case selection.selectedVariant
    of pvCanonical: "Write one complete GWL warrior program."
    of pvPlain: "Your task is to write one complete GWL warrior program."
    of pvNumbered: "Task 1: write one complete GWL warrior program."
    of pvQuestions: "What must you write? One complete GWL warrior program."
    of pvReordered: "In GWL, write one complete warrior program."
    of pvHeldoutBriefing: "Prepare a complete warrior program using GWL."
    of pvHeldoutReference: "Assignment: author one complete GWL warrior program."
    of pvMixed: raise newException(ValueError, "mixed must resolve")
  first & " Reply with JSON containing script as an array of lines, notes, and banner."

const CanonicalRules = """THE GAME
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
"""

proc rulesBriefing*(selection: PromptSelection): string =
  ## Keep scoring and mechanics complete while varying explanation and order.
  if selection.selectedVariant == pvCanonical:
    return CanonicalRules
  let programming = "Write an entire GWL warrior, then let the engine run it at one action per tick. " &
    "You may replace the program between rounds, but cannot intervene during battle. " &
    "The 30 by 30 board wraps in both directions. Other warriors' source is never revealed, " &
    "even after a round; use the visible board to infer their behavior."
  let territory = "A cell has an owner (0 for unclaimed, otherwise its warrior id), at most one live bomb, " &
    "and a permanent corpse flag. place() overwrites ownership of your current cell. " &
    "Death immediately erases all territory owned by that warrior."
  let bombs = "Energy starts at 12, increases by 1 + tiles div 60 per tick, and cannot exceed 60. " &
    "bomb() spends BOMBCOST. Live bombs block movement. A new bomb has MAXFUSE (5), " &
    "including its planting tick: a bomb placed at t explodes at t+4. Its blast wraps across " &
    "the center and four orthogonal neighbors, clears ownership, kills occupants, leaves " &
    "permanent corpses, and triggers other bombs in a chain."
  let survival = "A fault or 50 ticks without changing cells kills your warrior. " &
    "Survival matters both for the end bonus and for retaining claimed tiles."
  let scoring = "Higher scores win. Raw round points are tiles + (100 if alive at the end) + " &
    "50 per kill - 50 per self-kill. Subtract the mean raw points of all four warriors " &
    "to obtain roundScore; your final score is the mean roundScore over played rounds. " &
    "The four scores sum to zero. A dead warrior has no territory."
  case selection.selectedVariant
  of pvPlain:
    result = programming & "\n\n" & territory & "\n\n" & bombs & "\n\n" & survival & "\n\n" & scoring
  of pvNumbered:
    result = "1. Program and information\n" & programming & "\n2. Claiming cells\n" & territory &
      "\n3. Resources and explosions\n" & bombs & "\n4. Staying alive\n" & survival & "\n5. Payoff\n" & scoring
  of pvQuestions:
    result = "What can you control and observe?\n" & programming & "\nHow do you score?\n" & scoring &
      "\nWhat does claiming do?\n" & territory & "\nHow do bombs work?\n" & bombs & "\nWhat kills you?\n" & survival
  of pvReordered:
    result = "PAYOFF\n" & scoring & "\nSURVIVAL\n" & survival & "\nBOMBS AND ENERGY\n" & bombs &
      "\nOWNERSHIP\n" & territory & "\nPROGRAMMING AND VISIBILITY\n" & programming
  of pvHeldoutBriefing:
    result = "Before submitting your warrior, understand its execution contract:\n" & programming &
      "\nThe battle then applies these resource and hazard rules:\n" & bombs & "\n" & survival &
      "\nTerritory persists subject to these ownership rules:\n" & territory & "\nAfter each battle, accounting is:\n" & scoring
  of pvHeldoutReference:
    result = "Scoring reference: " & scoring & "\nOwnership reference: " & territory &
      "\nExecution reference: " & programming & "\nElimination reference: " & survival & "\nResource reference: " & bombs
  of pvCanonical, pvMixed:
    raise newException(ValueError, "wording must resolve")
  result.add("\n")
