# Grid Wars prompt diversity and candidates

`promptVariant` selects one introduction for the complete episode. Training
wordings are `canonical`, `plain`, `numbered`, `questions`, and `reordered`.
Evaluation also accepts `heldout-briefing` and `heldout-reference`. `mixed`
requires an independent nonnegative `promptSeed` and selects seed modulo five.
Selection never consumes simulation randomness or changes between rounds.

The `grid-wars-rules-v1` bank preserves each canonical surface: native player,
ordinary Python player, and training rules. GWL semantics, tick resolution,
scoring, operator strategy, private views, and published budgets remain fixed.
The host delivers wording configuration privately; capture hashes the actual
rendered messages. Other seats' programs and notes remain sealed.

## Private evidence

`GRID_WARS_ATTEMPT_TRACE_DIR` records actual native requests without credentials,
raw responses, parse results, and failures. `GRID_WARS_HOST_TRACE_PATH` records
private observations, proposals, installed programs, completed round events,
and final results. Set `GRID_WARS_SOURCE_REVISION` to the deployed source SHA.
Evidence files use mode 0600 and are not published to spectators.

Ordinary capture (`POC_CAPTURE_TRAINING=1`) journals attempts before generation,
raw completions before parsing, and host execution acknowledgements. Its
artifact retains unsuccessful submissions instead of turning them into labels.
Incomplete attempts remain incomplete evidence.

## Complete candidate export

Build and run from a clean, committed checkout:

```sh
nim c -d:release --path:src -o:/outside/checkout/export_posttrain tools/export_posttrain.nim
/outside/checkout/export_posttrain /private/new-candidates 10 standard plain 0
```

Both `standard` and `blitz` retain their published round and tick limits.
Exports stream `trajectories.jsonl`, paired execution events, seeded replays,
and a manifest. The shared Coworld importer owns independent review and labels.
There are no automatic training/validation files. The `grid-wars-SEED` family
keeps mode and wording replicas together. Held-out training export is rejected.

The ordinary exporter also emits private candidates and requires at least ten
complete captured games, all four seats, and matching source revisions. See
[ordinary player instructions](../players/ordinary/README.md).

The bridge accepts an optional third argument `text` for complete program,
notes, and banner actions. Numeric callers retain their existing interface.

```sh
python3 tools/test_prompt_games.py /absolute/train_bridge
python3 tools/test_training.py /absolute/export_posttrain /absolute/train_bridge
```

These complete workflows check message hashes, private notes, canonical numeric
behavior, and wording-invariant actions and outcomes. They do not establish
stronger model play. Compare canonical-only and five-wording training with the
same initialization, decision budget, optimizer, seeds, and opponents. Freeze
training choices before evaluating held-out wordings. Report score and wording
spread, invalid programs, fallbacks, and incomplete games separately. Inspect
paired regressions and private-information exposure. Production inference and
matched learning comparisons remain unrun.

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
