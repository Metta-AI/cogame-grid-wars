# Grid Wars training

The exporter plays ten complete native series per certified variant. It
records each seat's exact hosted system and user prompts, plus a complete
Grid Warrior Language (GWL) program accepted by the production parser.
All four seats submit before the native battle resolves. Train and
validation sets split complete series by seed.

```sh
nim c -d:release --path:src -o:/tmp/grid-wars-posttrain tools/export_posttrain.nim
/tmp/grid-wars-posttrain /tmp/grid-wars-data 10 standard
```

The other certified variant is `blitz`. The output has `train.jsonl`,
`validation.jsonl`, and a manifest with source revision, seeds, complete
rounds, scores, and row counts. Ten series yielded 160/40 standard and
96/24 blitz train/validation decisions.

From a Metta checkout with the post-training package installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/grid-wars-data --output /tmp/grid-wars-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

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
