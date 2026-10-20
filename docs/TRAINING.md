# Grid Wars prompt diversity

The `grid-wars-rules-v2` bank explains program execution, territory, energy,
bombs, elimination, visibility, and scoring in five training presentations:
`canonical`, `plain`, `numbered`, `questions`, and `reordered`. Two evaluation
presentations are `heldout-briefing` and `heldout-reference`.

`mixed` requires an independent nonnegative `promptSeed`, selecting seed modulo
five. Selection stays fixed throughout the episode without consuming game
randomness. GWL syntax, reply grammar, operator strategy, and published budgets
stay fixed. Training rejects held-out presentations.

The bridge preserves canonical training messages. Native and ordinary players
now also receive the complete game briefing, including scoring. The game sends
the ordinary system message, so deploy the game and players together.

## Complete training exports

```sh
nim c -d:release --path:src -o:/outside/checkout/export_posttrain tools/export_posttrain.nim
/outside/checkout/export_posttrain /private/new-dataset 10 standard mixed 0
```

The exporter retains its original train.jsonl, validation.jsonl, and manifest
format. Mixed exports cycle wordings independently within training and validation.
Episode IDs include wording to distinguish matched collections. Seed families use
`grid-wars-SEED` across modes and wordings; every fifth game is validation.
Messages carry selection metadata and hashes. Both published variants retain
full round and tick budgets.

Ordinary capture retains accepted decisions in the existing version-one
artifact. New decisions include prompt metadata; the exporter still reads
existing stored artifacts without it. Held-out metadata is rejected for
training. See [ordinary player instructions](../players/ordinary/README.md).

The bridge accepts an optional third argument `text` for complete programs,
notes, and banners. Numeric callers retain their existing interface.

```sh
python3 tools/test_prompt_games.py /absolute/train_bridge
python3 tools/test_training.py /absolute/export_posttrain /absolute/train_bridge
```

These workflows check complete games, unchanged actions/outcomes, private
notes, and message hashes. They do not demonstrate stronger learned play.
Compare canonical-only and mixed training with identical initialization,
optimizer, decision budget, opponents, and scenario families. Freeze training
choices before held-out evaluation. Report score spread, invalid programs,
fallbacks, and incomplete games; inspect paired regressions.

## Numeric reinforcement learning

`tools/train_bridge.nim` exposes hosted prompts and 933 numeric values:
the prior public board and scores, plus the acting seat's own prior
statistics and current warrior. It never reads another seat's program or
notes. Three choices select the published painter, bomber, and sentry
warriors. Zero-sum scores use `score / (abs(score) + 100)` for bounded
(-1, 1) utilities. Post-training above retains arbitrary legal GWL.

```sh
nim c -d:release --path:src -o:/tmp/grid-wars-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/grid-wars-posttrain /tmp/grid-wars-train-bridge
```

From a Metta checkout with the Coworld training stack, pass absolute
bridge and manifest paths to `recipes.external.coworld.train` for native
PufferLib, or `recipes.external.coworld_metta_rl.train` for Metta RL.
Set `players=4` and choose `standard` or `blitz`.

Both variants completed 512 Metta RL timesteps with checkpoints and held-out
evaluation. Native PufferLib trained 4,096 CUDA timesteps per variant in
Slurm job 9066, then reloaded the checkpoints for held-out evaluation on
seeds 101 and 102. Standard scored 0.0/0.0 and blitz scored -1.2/-0.4.
These bounded runs verify execution, not stronger league play.

Held-out bridge wordings require an explicit `evaluation`, `validation`, or `test`
split. Omitted, training, and unrecognized splits reject them.
