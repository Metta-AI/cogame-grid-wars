# Grid Wars

**Core Wars on a 30×30 toroidal grid**, for the Softmax Coworld platform,
forked from [cogame-bullwhip](https://github.com/Metta-AI/cogame-bullwhip).
Four cogs fight for 900 tiles — and none of them moves a warrior. Each one
**writes** one.

Every round, all four seats simultaneously submit a complete program in
**GWL**, a small, integer-only, Nim-like DSL (`check(dx,dy)`, `who(dx,dy)`,
`move`, `place`, `bomb`, `wait`, `while`/`if`/`for`/`proc`). The four
scripts are sealed and compiled, and the engine fights them for up to 400
ticks on an empty board:

- `place()` claims the cell you stand on, overwriting whoever owned it.
- `bomb()` costs energy. A live bomb is a **wall** for five ticks, then
  scorches a plus of five cells — resetting their owners — and chains into
  any bomb it touches. Corpses are permanent walls.
- Fifty ticks without changing cell kills you. So does a **fault**: a
  divide by zero, an index out of range, an undefined name. The line number
  comes back to you before the next round, so a series is five rounds of
  debugging under fire.
- When a warrior dies, **every tile it owned reverts to unclaimed**, at
  once. Elimination is decisive and the board visibly un-paints.

Scoring is symmetric zero-sum: `raw = tiles + 100 if alive + 50 per kill −
50 per self-kill`, and a seat's score is its mean deviation from the
four-seat average, so **the four scores sum to exactly zero**. Territory is
the score, but a dead warrior owns nothing.

**The game is LLM-driven and a policy is just a prompt.** Every round the
game server sends each seat's policy prompt, its alias, its own current
script with line numbers, its own diagnostics (fault line, death cause,
tiles curve, `illegal`/`blocked`/`refused`/`stalls`), the series table and
the previous round's ASCII board to Claude — the four seats as **one
parallel batch**, since their submissions are simultaneous — and Claude
answers with a new warrior program, private notes and a spectator banner.
Player containers exist only to deliver their prompt over the websocket.
A reply that does not parse or does not **compile** is retried once with
the exact compiler message; a seat still failing plays the built-in
`sentry` warrior for that round.

Three built-in **scripted warriors** — `painter` (claim ground, turn away
from walls, bomb a rival that leans in), `bomber` (mine the ground you
leave and fence yourself in) and `sentry` (the always-legal fallback) —
play any seat that registers as scripted, and every seat when no LLM
credentials are available, so episodes and offline certification always
complete.

Seats play under **anonymous cog names** (Sprocket, Gizmo, …): policy
display names never reach the agents' prompts, so nobody can meta-game
"that seat is the champion", and **no seat ever sees another seat's source
code**, before, during or after a round. The spectator and replay viewers
map the aliases back to policy names; results are reported under policy
names.

## Field your own policy

```bash
coworld upload-policy <grid-wars-image> --name my-grid-wars \
  --run /bin/gridwars-player \
  --secret-env PLAYER_PROMPT="<your warrior-writing strategy>"
```

`docs`/`warrior-language.md` in the manifest is the complete GWL reference
your prompt has to write against, plus the three shipped warriors.

## Layout

- `src/gridwars.nim` — entrypoint (Coworld runtime contract, live vs replay mode)
- `src/gridwars/gwl.nim` — the warrior language: lexer, parser, compiler to
  a flat op array, and the resumable VM. Pure, integer-only, no IO — the
  only file that knows about syntax
- `src/gridwars/sim.nim` — the arena rules and the episode state machine.
  Pure, no IO; the server, the tests and the wasm viewer all drive this
  module and nothing else
- `src/gridwars/llm.nim` — Claude client (one parallel batch per round),
  prompts, tolerant reply parsing, and the three scripted warriors
- `src/gridwars/server.nim` — mummy HTTP/WS server (player, global, replay)
- `src/gridwars_player.nim` — the prompt-delivery player (`PLAYER_PROMPT` /
  `PLAYER_SCRIPTED` env)
- `client/` — the inherited bullwhip broadcast chrome plus one appended
  Grid Wars block: the arena, the territory bar and the code pane
- `replay-viewer/` — the static wasm replay viewer (`?replay=<url>`), which
  **re-derives every tick** from the recorded events and checks its own
  work against the recorded per-round digest
- `data/warriors/*.gwl` — the three shipped warriors, compiled into the
  binary with `staticRead`
- `tools/build_replay_viewer.sh` — the `coworld build` replay-viewer hook
- `docs/plans/` — the design note this game was built from

## Determinism

A battle is a pure function of (scripts, round seed, config). Integer-only
VM, no hash-table iteration order, no wall clock, priority derived from the
tick index, and every warrior's `rand` stream seeded from the logged round
seed. That is what lets the browser re-run the whole game from a ~7 KB
replay file and refuse to draw a different one: `replayMatch` recomputes
each round's FNV-1a digest and raises on a mismatch, which the shell
reports as `data-replay-error`.

## Building

The repo builds in CI (`.github/workflows/ci.yml`): native Nim tests in
debug and release, a raw-Docker episode smoke on the production image, and
a headless-Chromium load test of the static replay viewer bundle. Locally:

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
# regenerate nim.cfg for this machine's package tree, then:
nim r --path:src tests/test_sim.nim
```

## License

MIT. Cog sprites, arena floor and font from
[coworld-ctf](https://github.com/Metta-AI/coworld-ctf) by way of
cogame-bullwhip (MIT); see `data/FONT_LICENSE.txt`.
