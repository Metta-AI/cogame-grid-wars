"""Complete native games, raw-response transport, and ordinary capture/export.

Both model paths use deterministic local fixtures, never a real model or teacher.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

GAME, PLAYER = sys.argv[1:3]
ROOT = Path(__file__).resolve().parents[2]
PAINTER = (ROOT / "data/warriors/painter.gwl").read_text().splitlines()
ACTION = {"script": PAINTER, "notes": "ordinary fixture", "banner": "painting"}
RAW = "```json\n" + json.dumps(ACTION) + "\n```"
requests = {"prompt": 0}


class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.path == "/v1/messages"
        assert body["model"] == "anthropic/claude-haiku-4.5"
        assert "anthropic_version" not in body
        assert (
            "Maximize your mean roundScore across the rounds played." in body["system"]
        )
        assert "50 per self-kill" in body["system"]
        user = body["messages"][0]["content"]
        assert "GUIDANCE FROM YOUR OPERATOR" in user
        assert "Paint and survive." in user
        assert user.endswith("characters, banner at most 80 characters.")
        assert self.headers["X-Coworld-Player-Slot"] == "1"
        requests["prompt"] += 1
        response = {
            "content": [{"type": "text", "text": RAW}],
            "stop_reason": "end_turn",
        }
        encoded = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def log_message(self, *_args):
        pass


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


# Exercise the real ordinary model callback without loading model weights.
# This fixture module is confined to its test process, never a runtime patch.
ORDINARY_FIXTURE = """
import runpy, sys, types
from pathlib import Path
module = types.ModuleType("posttrain")
def fixture_generator(_adapter):
    def generate(messages):
        assert "Maximize your mean roundScore" in messages[0]["content"]
        assert messages[1]["content"].endswith("characters, banner at most 80 characters.")
        return sys.argv[2]
    return generate
module.TransformersGenerator = fixture_generator
sys.modules["posttrain"] = module
sys.path.insert(0, str(Path(sys.argv[1]).parent))
runpy.run_path(sys.argv[1], run_name="__main__")
"""

model = ThreadingHTTPServer(("127.0.0.1", free_port()), Stub)
threading.Thread(target=model.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="gridwars-raw-policy-") as scratch:
        runs = []
        for index, seed in enumerate([7, 10]):
            root = Path(scratch) / str(seed)
            root.mkdir()
            port = free_port()
            config = {
                "tokens": [f"token-{seat}" for seat in range(4)],
                "players": [{"name": f"Policy {seat}"} for seat in range(4)],
                "seed": seed,
                "promptVariant": "mixed",
                "promptSeed": 4,
                "rounds": 5,
                "ticks": 400,
                "sampled": True,
                "roundDelayMs": 0,
                "actionTimeoutSeconds": 8,
                "player_connect_timeout_seconds": 8,
            }
            (root / "config.json").write_text(json.dumps(config))
            game_env = os.environ | {
                "COGAME_HOST": "127.0.0.1",
                "COGAME_PORT": str(port),
                "COGAME_CONFIG_URI": (root / "config.json").as_uri(),
                "COGAME_RESULTS_URI": (root / "results.json").as_uri(),
                "COGAME_SAVE_REPLAY_URI": (root / "replay.json").as_uri(),
            }
            game = subprocess.Popen(
                [GAME],
                env=game_env,
                stdout=(root / "game.log").open("w"),
                stderr=subprocess.STDOUT,
            )
            players = []
            try:
                for _ in range(100):
                    if game.poll() is not None:
                        raise AssertionError((root / "game.log").read_text())
                    with socket.socket() as probe:
                        if probe.connect_ex(("127.0.0.1", port)) == 0:
                            break
                    threading.Event().wait(0.05)
                else:
                    raise AssertionError("game socket unavailable")
                settings = [
                    {
                        "POC_CAPTURE_TRAINING": "1",
                        "POC_SOURCE_REVISION": "fixture",
                        "POC_ADAPTER_DIR": "deterministic-local-test-fixture",
                        "COWORLD_PLAYER_ARTIFACT_UPLOAD_URL": (
                            root / "policy_artifact_0.zip"
                        ).as_uri(),
                    },
                    {"PLAYER_PROMPT": "Paint and survive."},
                    {"PLAYER_SCRIPTED": "painter"},
                    {"PLAYER_SCRIPTED": "bomber"},
                ]
                for slot, selected in enumerate(settings):
                    env = os.environ.copy()
                    # Prevent the caller's model/operator settings changing this fixture.
                    for key in [
                        "PLAYER_PROMPT",
                        "PLAYER_SCRIPTED",
                        "POC_ADAPTER_DIR",
                        "POC_CAPTURE_TRAINING",
                    ]:
                        env.pop(key, None)
                    env.update(selected)
                    env.update(
                        {
                            "COWORLD_PLAYER_WS_URL": f"ws://127.0.0.1:{port}/player?slot={slot}&token=token-{slot}",
                            "COWORLD_LLM_ENDPOINT": f"http://127.0.0.1:{model.server_port}",
                        }
                    )
                    command = (
                        [
                            sys.executable,
                            "-c",
                            ORDINARY_FIXTURE,
                            str(ROOT / "players/ordinary/player.py"),
                            RAW,
                        ]
                        if slot == 0
                        else [PLAYER]
                    )
                    players.append(
                        subprocess.Popen(
                            command,
                            env=env,
                            cwd=ROOT,
                            stdout=(root / f"player-{slot}.log").open("w"),
                            stderr=subprocess.STDOUT,
                        )
                    )
                assert game.wait(timeout=65) == 0, (root / "game.log").read_text()
                for slot, player in enumerate(players):
                    assert player.wait(timeout=5) == 0, (
                        root / f"player-{slot}.log"
                    ).read_text()
                results = json.loads((root / "results.json").read_text())
                replay = json.loads((root / "replay.json").read_text())
                assert requests == {"prompt": (index + 1) * 5}, requests
                assert (
                    results["reason"] == "complete"
                    and results["rounds"] == 5
                    and results["ticks"] == 400
                )
                submissions = [
                    event for event in replay["events"] if event["kind"] == "submit"
                ]
                assert len(submissions) == 20
                assert [event["origin"] for event in submissions] == [
                    "player",
                    "player",
                    "scripted",
                    "scripted",
                ] * 5
                with zipfile.ZipFile(root / "policy_artifact_0.zip") as archive:
                    trajectory = json.loads(archive.read("trajectory.json"))
                assert len(trajectory["decisions"]) == 5
                for decision in trajectory["decisions"]:
                    assert decision["prompt_template"]["variant"] == "reordered"
                    assert (
                        "Maximize your mean roundScore"
                        in decision["prompt"][0]["content"]
                    )
                    assert decision["prompt"][1]["content"].endswith(
                        "characters, banner at most 80 characters."
                    )
                    assert (
                        "GUIDANCE FROM YOUR OPERATOR"
                        not in decision["prompt"][1]["content"]
                    )
                    assert decision["completion"] == [
                        {"role": "assistant", "content": RAW}
                    ]
                    assert decision["native_action"] == ACTION
                runs.append(root)
            finally:
                for process in [*players, game]:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)
        sys.path.insert(0, str(ROOT / "players/ordinary"))
        from export import export

        output = Path(scratch) / "exported"
        manifest = export(runs, output, "fixture", "trained")
        for split in ["train", "validation"]:
            rows = [
                json.loads(line)
                for line in (output / f"{split}.jsonl").read_text().splitlines()
            ]
            assert len(rows) == 5
            assert all(
                row["completion"] == [{"role": "assistant", "content": RAW}]
                for row in rows
            )
        corrupt = Path(scratch) / "corrupt"
        corrupt.mkdir()
        for name in ["config.json", "results.json"]:
            shutil.copyfile(runs[0] / name, corrupt / name)
        with zipfile.ZipFile(runs[0] / "policy_artifact_0.zip") as archive:
            damaged = json.loads(archive.read("trajectory.json"))
        damaged["decisions"][0]["native_action"]["notes"] = "FORGED INSTALLED NOTES"
        with zipfile.ZipFile(corrupt / "policy_artifact_0.zip", "w") as archive:
            archive.writestr("trajectory.json", json.dumps(damaged))
        try:
            export([corrupt], Path(scratch) / "corrupt-output", "fixture", "trained")
        except ValueError as error:
            assert "raw target changed" in str(error)
        else:
            raise AssertionError("native-normalized raw target was admitted")
        print(
            "Grid Wars system check: two complete 5x400 games; both fixture model paths accept fenced text; "
            "10 exact raw captures/exported targets; changed native action rejected; zero fallback"
        )
finally:
    model.shutdown()
