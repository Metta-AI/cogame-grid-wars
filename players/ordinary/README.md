# Ordinary Grid Wars player

This player receives its private round prompt through `gridwars.player.v3` and sends a complete warrior program. The game compiles every program, seals all four before battle, and owns board execution, scores, and replay. The default backend submits the packaged `painter` program. `POC_ADAPTER_DIR` loads a Metta post-training adapter that generates program JSON. Existing prompt and scripted players remain fieldable.

Build the local game and player images, then run a mixed roster from a manifest based on the downloaded certified package:

```bash
docker build --platform linux/amd64 -t gridwars-game:local .
docker build --platform linux/amd64 -f Dockerfile.ordinary-player -t gridwars-player:local .
uv run coworld run-episode /path/to/coworld_manifest.json --timeout-seconds 120 -o /tmp/gridwars-ordinary
```

Set `POC_CAPTURE_TRAINING=1` and `POC_SOURCE_REVISION=<policy commit>` to upload accepted submissions through the standard Coworld artifact URL. Capture complete games with different seeds and export them:

```bash
python players/ordinary/export.py /tmp/gridwars-dataset /tmp/gridwars-runs --source-revision <policy-commit>
```

Use the [post-training research package](https://github.com/Metta-AI/posttraining-research/tree/main/packages/metta-posttraining)
for current training and adapter-packaging workflows.

The existing `tools/export_posttrain.nim` also exports complete scripted games without containers. The artifact exporter admits only completed games, accepted programs, a matching source revision, and separate whole-game seed splits.

Package the base and adapter into a separate player image:

```bash
docker build --platform linux/amd64 -f Dockerfile.ordinary-model \
  --build-context base=/path/to/base-model --build-context adapter=/tmp/gridwars-adapter \
  -t gridwars-model:local .
```

The loader checks the base model hash against Metta's training manifest. Evaluate saved policies on held-out games before fielding them.

The game now supplies the system message and episode-stable wording selection.
Deploy game and player together. Capture adds prompt metadata to accepted
decisions; existing stored version-one artifacts remain readable. See
[prompt diversity](../../docs/TRAINING.md).

Ordinary export IDs include the complete capture hash. Matched wording runs may
share a scenario seed and remain in the same split; duplicate captures are rejected.

## Shared live and training messages

The game sends the training renderer's system message and user-prompt parts to
both player implementations. Players insert only their private operator strategy;
all rules, observations and output instructions come from the game. Native inference,
ordinary capture, the text bridge and offline exports therefore use the same
message template, including the empty-operator case. Deploy the game and players
together: updated players require the turn's prompt_parts field. Existing stored
captures retain their original identities and are not rewritten.

The former native and ordinary system builders have been removed. This changes
model-facing prompt wording to the maintained training contract; simulation, GWL,
score, action parsing and episode budgets remain unchanged. The existing player
system check now runs five rounds of 400 ticks with model, canned and scripted
seats and checks full completion, messages, capture and zero fallback.

Ordinary model replies cross the socket as unchanged text. The game applies the
same native JSON extraction and GWL parser as the native model player; fenced
replies therefore have the same meaning. Capture retains exact assistant text
and the acknowledged installed action. New ordinary exports reject raw fields
changed by native normalization; older capture records retain their historical
format and evidence limits. The full system fixture plays two complete five-round,
400-tick games, exercises both model callback paths with fenced responses, exports
separate whole-game splits, and rejects a changed-target control. Its model
callbacks are deterministic local fixtures, not genuine model or teacher traces.
