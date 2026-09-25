# Ordinary Grid Wars player

This player receives its private round prompt through `gridwars.player.v3` and sends a complete warrior program. The game compiles every program, seals all four before battle, and owns board execution, scores, and replay. The player packages its own `painter`, `bomber`, and `sentry` candidate programs. The default backend submits `painter`. `POC_JEV=1` asks Jev System One to choose among those complete programs. `POC_ADAPTER_DIR` loads a Metta post-training adapter that generates program JSON. Existing prompt and scripted players remain fieldable.

Build the local game and player images, then run a mixed roster from a manifest based on the downloaded certified package:

```bash
docker build --platform linux/amd64 -t gridwars-game:local .
docker build --platform linux/amd64 -f Dockerfile.ordinary-player -t gridwars-player:local .
uv run coworld run-episode /path/to/coworld_manifest.json --timeout-seconds 120 -o /tmp/gridwars-ordinary
```

For local Jev verification, set `POC_JEV=1` and `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` on the ordinary player. That endpoint uses pinned `typesafe/jev-1.13`. A local mock can return a System One choice response; no production model call is needed for protocol testing.

Set `POC_CAPTURE_TRAINING=1` and `POC_SOURCE_REVISION=<policy commit>` to upload accepted submissions through the standard Coworld artifact URL. Capture complete games with different seeds and export them:

```bash
python players/ordinary/export.py /tmp/gridwars-dataset /tmp/gridwars-runs --source-revision <policy-commit>
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/gridwars-dataset --output /tmp/gridwars-adapter --model /path/to/base-model \
  --device cpu --max-steps 100 --max-length 4096 --max-eval-examples 128
```

The existing `tools/export_posttrain.nim` also exports complete scripted games without containers. The artifact exporter admits only completed games, accepted programs, a matching source revision, and separate whole-game seed splits. Review Jev programs before using `--source jev` as training data.

Package the base and adapter into a separate player image:

```bash
docker build --platform linux/amd64 -f Dockerfile.ordinary-model \
  --build-context base=/path/to/base-model --build-context adapter=/tmp/gridwars-adapter \
  -t gridwars-model:local .
```

The loader checks the base model hash against Metta's training manifest. Evaluate saved policies on held-out games before fielding them.
