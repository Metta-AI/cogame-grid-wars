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
  PromptBankVersion* = "grid-wars-rules-v3"

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
    result = """1. Submit a complete GWL warrior. During battle the engine executes one action each tick; you can rewrite the program only between rounds. The 30x30 grid wraps along both axes. You see the board, but rival source code is hidden before and after each round, so infer behavior from the board.
2. Each cell records an owner (0 means unclaimed; other values identify warriors), at most one live bomb, and a permanent corpse flag. place() changes your current cell's owner to you. A warrior's death immediately clears all its owned cells.
3. Start with 12 energy. Each tick adds 1 + tiles div 60, up to a cap of 60. Planting with bomb() costs BOMBCOST. Live bombs are impassable. MAXFUSE is 5 and includes the planting tick: a bomb planted at t detonates at t+4. Its wrapping five-cell plus blast removes ownership, kills occupants and leaves permanent corpses; hit bombs chain.
4. A fault kills the warrior, as does remaining in the same cell for 50 ticks. Staying alive also keeps your territory and earns the end bonus.
5. Raw round points equal tiles + (100 if alive at the end) + 50 per kill - 50 per self-kill. Subtract the average raw points of the four warriors to obtain roundScore. Final score averages roundScore over played rounds. Higher wins; the four scores sum to zero. Dead warriors own no tiles."""
  of pvQuestions:
    result = """What do you control? A complete GWL warrior program, executed one action per tick throughout battle. Rewrite it between rounds; there is no intervention during battle. Where does it run? On a 30x30 grid wrapping in x and y. What can you learn about rivals? Their source stays hidden before and after rounds; infer from the visible board.
What belongs to a cell? An owner, with 0 for unclaimed and warrior ids otherwise, at most one live bomb, and a permanent corpse flag. How do you claim it? place() overwrites ownership beneath you. What happens on death? Every cell owned by that warrior becomes unclaimed immediately.
How is energy supplied? You begin at 12 and gain 1 + tiles div 60 per tick, never exceeding 60. What does bomb() spend? BOMBCOST. Can you enter a live bomb's cell? No. When does it explode? MAXFUSE is 5, counting the planting tick, so planting at t means explosion at t+4. What does the blast do? Its wrapping center and four cardinal neighbors lose ownership; occupants die and leave permanent corpses, and other bombs chain.
What else kills a warrior? A fault or 50 ticks without changing cells. Why survive? To retain territory and receive the end bonus.
How are points computed? Raw = tiles + (100 if alive at the end) + 50 per kill - 50 per self-kill. roundScore subtracts the four-warrior mean raw score. Final score is the mean roundScore across played rounds. Higher is better, the four scores total zero, and a dead warrior has no territory."""
  of pvReordered:
    result = """Maximize your mean roundScore across the rounds played. For a round, calculate raw points as tiles + (100 if alive at the end) + 50 per kill - 50 per self-kill, then subtract the mean raw points of all four warriors. Their scores sum to zero. Death removes all of that warrior's territory immediately, so survival preserves tiles as well as its 100-point end bonus.
A fault or 50 ticks without moving to a different cell causes death. Energy begins at 12, grows by 1 + tiles div 60 each tick and caps at 60. bomb() consumes BOMBCOST. A live bomb blocks entry. Its MAXFUSE of 5 counts the planting tick; a bomb placed at t goes off at t+4. The blast wraps over the center and four orthogonal neighbors, clears their owners, kills occupants leaving permanent corpses, and chains into other bombs.
Cells contain an owner (0 unclaimed, otherwise a warrior id), no more than one live bomb, and a permanent corpse flag. place() takes ownership of the cell beneath you, replacing its previous owner.
The arena is a 30x30 torus, wrapping in both coordinates. Submit a complete GWL program: the engine runs one action per tick for the battle, and you may replace it only between rounds. Rival source code is never shown, even after a round. Use the visible board to infer what rival warriors do."""
  of pvHeldoutBriefing:
    result = """Prepare a complete GWL program before battle. Once battle starts, the engine advances it at one action per tick; your next opportunity to rewrite is between rounds. The arena spans 30 by 30 cells with both coordinates wrapping. Opponents' programs remain secret before and after play, leaving the visible board as evidence of their behavior.
Claim the cell you occupy with place(), replacing any previous owner. A cell stores owner 0 when unclaimed or a warrior id when claimed, plus at most one live bomb and a permanent corpse flag. If a warrior dies, all of its territory is immediately unclaimed.
Your energy reserve starts at 12. The per-tick refill is 1 + tiles div 60 and capacity is 60. A bomb costs BOMBCOST to plant and blocks passage while live. MAXFUSE is 5 including the planting tick, giving detonation at t+4 for planting at t. Its blast covers a wrapping plus of five cells. Those cells lose ownership, warriors caught there die leaving permanent corpses, and bombs caught there detonate in a chain.
Avoid faults and spending 50 ticks in one cell: either kills your warrior. Survival retains territory and contributes an end-of-round bonus. Raw points are tiles + 100 if still alive at the end + 50 for each kill - 50 for each self-kill. The roundScore is your raw points minus the four warriors' mean raw points. Average roundScore over played rounds for the final score; higher wins and the four scores sum to zero. A dead warrior has no territory."""
  of pvHeldoutReference:
    result = """Execution: one complete GWL warrior program; one action per tick; changes allowed between rounds only. Arena: 30x30, wrapping along x and y. Information: board visible; other warriors' source never visible, including after a round; behavior can be inferred from the board.
Cell record: owner 0 for unclaimed or a warrior id, zero or one live bomb, permanent corpse flag. Claim operation: place() replaces the owner of the occupied cell. Death consequence: all cells owned by the dead warrior immediately become unclaimed.
Energy: initial 12; tick income 1 + tiles div 60; maximum 60. Planting cost: BOMBCOST via bomb(). Live-bomb cells: impassable. Fuse: MAXFUSE=5, with planting tick included, hence t+4 detonation for a t planting. Blast: wrapping center plus four orthogonal neighbors; ownership cleared, occupants killed with permanent corpses, other bombs triggered in chains.
Other death conditions: fault, or 50 ticks without changing cell. Survival benefits: retained territory and end bonus.
Raw points: tiles + (100 if alive at round end) + 50 per kill - 50 per self-kill. roundScore: raw minus the mean raw of four warriors. Final score: mean roundScore over played rounds, higher preferred. Sum of four scores: zero. Territory after death: none."""
  of pvCanonical, pvMixed:
    raise newException(ValueError, "wording must resolve")
