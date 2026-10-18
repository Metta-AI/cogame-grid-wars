"""Published Grid Wars series with real native or ordinary player processes."""

import argparse
import hashlib
import json
import os
import socket
import subprocess
import sys
import time
import zipfile
from pathlib import Path

WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
    "mixed",
)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("game", type=Path)
    parser.add_argument("player", type=Path)
    parser.add_argument("verifier", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--ordinary", action="store_true")
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / "coworld_manifest_template.json").read_text())
    variants = {v["id"]: v["game_config"] for v in manifest["variants"]}
    cases = [(name, "canonical", 7) for name in variants]
    if args.ordinary:
        cases = [("standard", WORDINGS[(seed - 1) % 5], seed) for seed in range(1, 11)]
    elif not args.smoke:
        cases += [("standard", wording, 7) for wording in WORDINGS[1:]]
    args.output.mkdir(mode=0o700, parents=True, exist_ok=False)
    for variant, wording, seed in cases:
        work = args.output / f"{variant}-{wording}-{seed}"
        work.mkdir(mode=0o700)
        config = dict(variants[variant])
        config.update(
            seed=seed,
            promptVariant=wording,
            promptSeed=4,
            tokens=[f"t{seat}" for seat in range(4)],
        )
        (work / "config.json").write_text(json.dumps(config))
        closed = socket.socket()
        closed.bind(("127.0.0.1", 0))
        port = free_port()
        env = os.environ.copy()
        for key in (
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_API_KEY_URI",
            "AWS_BEARER_TOKEN_BEDROCK",
            "AWS_ENDPOINT_URL_BEDROCK_RUNTIME",
            "PLAYER_SCRIPTED",
            "POC_ADAPTER_DIR",
        ):
            env.pop(key, None)
        env.update(
            COGAME_HOST="127.0.0.1",
            COGAME_PORT=str(port),
            COGAME_CONFIG_URI=(work / "config.json").as_uri(),
            COGAME_RESULTS_URI=(work / "results.json").as_uri(),
            COGAME_SAVE_REPLAY_URI=(work / "replay.json").as_uri(),
            COWORLD_LLM_ENDPOINT=f"http://127.0.0.1:{closed.getsockname()[1]}",
            GRID_WARS_HOST_TRACE_PATH=str(work / "host.jsonl"),
            GRID_WARS_ATTEMPT_TRACE_DIR=str(work / "attempts"),
            GRID_WARS_SOURCE_REVISION="uncommitted-grid-wars-validation",
            POC_SOURCE_REVISION="uncommitted-grid-wars-validation",
            POC_CAPTURE_TRAINING="1",
        )
        processes, logs = [], []
        try:
            log = (work / "game.log").open("w")
            logs.append(log)
            game = subprocess.Popen(
                [str(args.game)],
                cwd=root,
                env=env,
                stdout=log,
                stderr=subprocess.STDOUT,
            )
            processes.append(game)
            for _ in range(200):
                assert game.poll() is None, work
                with socket.socket() as probe:
                    ready = probe.connect_ex(("127.0.0.1", port)) == 0
                if ready:
                    break
                time.sleep(0.05)
            else:
                raise RuntimeError(f"host did not start: {work}")
            for seat in range(4):
                player_env = dict(
                    env,
                    COWORLD_PLAYER_WS_URL=f"ws://127.0.0.1:{port}/player?slot={seat}&token=t{seat}",
                    PLAYER_PROMPT=f"PRIVATE-STRATEGY-{seat}: Write a legal warrior.",
                    COWORLD_PLAYER_ARTIFACT_UPLOAD_URL=(
                        work / f"policy_artifact_{seat}.zip"
                    ).as_uri(),
                )
                command = (
                    [sys.executable, "-B", str(root / "players/ordinary/player.py")]
                    if args.ordinary
                    else [str(args.player)]
                )
                log = (work / f"player-{seat}.log").open("w")
                logs.append(log)
                processes.append(
                    subprocess.Popen(
                        command,
                        cwd=root,
                        env=player_env,
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )
                )
            assert game.wait(timeout=manifest["episode_timeout_minutes"] * 60 + 30) == 0
            for player in processes[1:]:
                assert player.wait(timeout=20) == 0
            results = json.loads((work / "results.json").read_text())
            replay = json.loads((work / "replay.json").read_text())
            assert (
                results["reason"] == "complete"
                and results["rounds"] == config["rounds"]
            )
            assert replay["results"] == results
            records = [
                json.loads(line)
                for line in (work / "host.jsonl").read_text().splitlines()
            ]
            assert (
                records[0]["event_type"] == "host_started"
                and records[-1]["results"] == results
            )
            assert (work / "host.jsonl").stat().st_mode & 0o777 == 0o600
            decisions = {
                (row["round"], row["seat"]): row
                for row in records
                if row["event_type"] == "host_decision"
            }
            submissions = {
                (row["round"], row["seat"]): row
                for row in replay["events"]
                if row["kind"] == "submit"
            }
            assert len(decisions) == len(submissions) == config["rounds"] * 4
            for key, row in decisions.items():
                round_number, seat = key
                event = submissions[key]
                assert row["executed_action"] == dict(
                    script=event["script"],
                    notes=event["text"] if "text" in event else "",
                    banner=event["banner"],
                )
                assert (
                    row["origin"] == event["origin"]
                    and row["compile_error"] == event["compileError"]
                )
                assert row["accepted"] == args.ordinary
                assert row["prompt_selection"]["variant"] == (
                    "reordered" if wording == "mixed" else wording
                )
                assert all(
                    f"PRIVATE-STRATEGY-{other}" not in row["observation"]
                    for other in range(4)
                )
                if args.ordinary:
                    with zipfile.ZipFile(
                        work / f"policy_artifact_{seat}.zip"
                    ) as archive:
                        capture = json.loads(archive.read("trajectory.json"))
                    assert (
                        capture["schema_version"] == 2
                        and capture["complete"]
                        and capture["scores"] == results["scores"]
                    )
                    attempt = capture["decisions"][round_number - 1]
                    assert (
                        attempt["execution"]["executed_action"]
                        == row["executed_action"]
                    )
                    assert attempt["execution"]["accepted"]
                    assert json.loads(attempt["raw_response"]) == row["executed_action"]
                    prompt, metadata = attempt["prompt"], attempt["prompt_template"]
                else:
                    path = work / "attempts" / f"{round_number}-{seat}.jsonl"
                    assert path.stat().st_mode & 0o777 == 0o600
                    start, finish = [
                        json.loads(line) for line in path.read_text().splitlines()
                    ]
                    assert (
                        not finish["completed"]
                        and finish["parsed_action"] is None
                        and finish["normalized_action"] is None
                    )
                    assert (
                        finish["platform_call_id"] is None
                        and finish["behavior_logprobs"] is None
                    )
                    prompt, metadata = start["prompt"], start["prompt_template"]
                    assert start["request"]["body"]["system"] == prompt[0]["content"]
                    assert start["request"]["body"]["messages"] == prompt[1:]
                    assert (
                        start["request"]["model"] == start["request"]["body"]["model"]
                    )
                assert f"PRIVATE-STRATEGY-{seat}" in prompt[1]["content"]
                assert all(
                    f"PRIVATE-STRATEGY-{other}" not in prompt[1]["content"]
                    for other in range(4)
                    if other != seat
                )
                assert metadata["bank"] == "grid-wars-rules-v1"
                for message in prompt:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
            for row in records:
                if row["event_type"] == "round_execution":
                    assert row["events"] and all(
                        event in replay["events"] for event in row["events"]
                    )
            assert "PRIVATE-STRATEGY-" not in json.dumps(
                replay
            ) and "prompt_template" not in json.dumps(replay)
            result = subprocess.check_output(
                [str(args.verifier), str(work / "replay.json")],
                cwd=root,
                text=True,
                timeout=120,
            )
            assert json.loads(result)["replay_verified"]
            print(
                variant,
                wording,
                seed,
                "ordinary" if args.ordinary else "native",
                len(decisions),
                "request/execution/replay joins PASS",
                flush=True,
            )
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=15)
            for log in logs:
                log.close()
            closed.close()


if __name__ == "__main__":
    main()
