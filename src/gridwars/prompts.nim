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
  PromptBankVersion* = "grid-wars-rules-v1"

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
