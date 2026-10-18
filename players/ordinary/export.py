"""Export complete private candidates; independent review owns training admission."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import zipfile
from pathlib import Path


def export(runs: list[Path], output: Path, revision: str, source: str) -> dict:
    if len(runs) < 10:
        raise ValueError("capture at least ten complete games before candidate export")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    episodes = []
    families = set()
    with os.fdopen(
        os.open(
            output / "trajectories.jsonl", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600
        ),
        "w",
    ) as stream:
        for run in runs:
            config = json.loads((run / "config.json").read_text())
            results = json.loads((run / "results.json").read_text())
            seed = config["seed"]
            family = f"grid-wars-{seed}"
            families.add(family)
            if results["reason"] != "complete":
                raise ValueError(f"incomplete game {run}")
            artifacts = sorted(run.glob("policy_artifact_*.zip"))
            if len(artifacts) != 4:
                raise ValueError(f"capture every seat in {run}")
            rows: list[dict] = []
            for artifact in artifacts:
                slot = int(artifact.stem.removeprefix("policy_artifact_"))
                with zipfile.ZipFile(artifact) as archive:
                    trajectory = json.loads(archive.read("trajectory.json"))
                if (
                    trajectory["schema_version"] != 2
                    or trajectory["game"] != "grid-wars"
                    or trajectory["slot"] != slot
                    or trajectory["source_revision"] != revision
                    or trajectory["complete"] is not True
                    or trajectory["scores"] != results["scores"]
                ):
                    raise ValueError(f"invalid candidate artifact {artifact}")
                decisions = trajectory["decisions"]
                if [row["turn"] for row in decisions] != list(
                    range(1, config["rounds"] + 1)
                ):
                    raise ValueError(f"missing player attempts in {artifact}")
                for row in decisions:
                    if row["source"] != source:
                        raise ValueError(f"unexpected policy source in {artifact}")
                    metadata = row["prompt_template"]
                    if metadata["variant"].startswith("heldout-"):
                        raise ValueError("held-out wording is evaluation-only")
                    for message in row["prompt"]:
                        digest = hashlib.sha256(message["content"].encode()).hexdigest()
                        if metadata[message["role"] + "_sha256"].lower() != digest:
                            raise ValueError(f"prompt hash mismatch in {artifact}")
                    execution = row["execution"]
                    if execution["round"] != row["turn"] or execution[
                        "prompt_selection"
                    ] != {
                        key: metadata[key]
                        for key in ("bank", "variant", "selection", "seed")
                    }:
                        raise ValueError(f"host acknowledgement mismatch in {artifact}")
                    proposal = json.loads(row["raw_response"])
                    accepted = (
                        execution["accepted"]
                        and proposal == execution["executed_action"]
                    )
                    identity = (row["turn"] - 1) * 4 + slot
                    attempt_id = f"{identity}-ordinary"
                    episode = f"{family}-{run.name}"
                    observation = {
                        "user": row["observation"],
                        "prompt_template": metadata,
                    }
                    rows.append(
                        {
                            "schema_version": "1",
                            "event_type": "decision",
                            "episode_id": episode,
                            "decision_id": str(identity),
                            "decision_index": identity,
                            "game": "grid-wars",
                            "game_version": f"source-{revision}",
                            "source_revision": revision,
                            "seat": str(slot),
                            "visibility": "private",
                            "observation": observation,
                            "prompt": row["prompt"] if accepted else None,
                            "attempts": [
                                {
                                    "attempt_id": attempt_id,
                                    "policy": source,
                                    "origin": "teacher"
                                    if source == "canned"
                                    else "model",
                                    "inference_mode": "text_action",
                                    "prompt": row["prompt"],
                                    "response": row["raw_response"],
                                    "parsed_action": proposal,
                                    "accepted": accepted,
                                    "request": None,
                                    "platform_call_id": None,
                                    "behavior_logprobs": None,
                                    "rejection_reason": None
                                    if accepted
                                    else "host-rejected-or-normalized-submission",
                                }
                            ],
                            "selected_attempt_id": attempt_id if accepted else None,
                            "executed_action": execution["executed_action"],
                            "action_status": "accepted" if accepted else "fallback",
                            "fallback_origin": None
                            if accepted
                            else "host-rejected-or-normalized-submission",
                            "terminal": identity == config["rounds"] * 4 - 1,
                        }
                    )
            rows.sort(key=lambda row: row["decision_index"])
            if [row["decision_index"] for row in rows] != list(
                range(config["rounds"] * 4)
            ):
                raise ValueError(f"duplicate or missing seats in {run}")
            for row in rows:
                stream.write(json.dumps(row, ensure_ascii=False) + "\n")
            stream.write(
                json.dumps(
                    {
                        "schema_version": "1",
                        "event_type": "episode",
                        "episode_id": episode,
                        "seed_family": family,
                        "game": "grid-wars",
                        "game_version": f"source-{revision}",
                        "source_revision": revision,
                        "status": "completed",
                        "outcome": results,
                        "participant_outcomes": {
                            str(slot): {"score": score}
                            for slot, score in enumerate(results["scores"])
                        },
                    }
                )
                + "\n"
            )
            episodes.append(
                {"episode_id": episode, "seed_family": family, "decisions": len(rows)}
            )
    if len(families) < 10:
        raise ValueError(
            "candidate evaluation requires at least ten distinct seed families"
        )
    manifest = {
        "schema_version": 1,
        "game": "grid-wars",
        "source_revision": revision,
        "review_required": True,
        "teacher": source,
        "episodes": episodes,
    }
    with os.fdopen(
        os.open(output / "manifest.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600),
        "w",
    ) as stream:
        json.dump(manifest, stream, indent=2)
        stream.write("\n")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("runs", nargs="+", type=Path)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--source", choices=("canned", "trained"), default="canned")
    args = parser.parse_args()
    directories = [
        episode
        for run in args.runs
        for episode in (
            sorted(run.glob("episode-*"))
            if not (run / "results.json").exists()
            else [run]
        )
    ]
    print(export(directories, args.output, args.source_revision, args.source))
