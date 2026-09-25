#!/usr/bin/env python3
"""Exercise Grid Wars game, prompt, Jev, and scripted players on one native build."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

GAME, PLAYER = sys.argv[1:3]
ROOT = Path(__file__).resolve().parents[2]
PAINTER = (ROOT / "data/warriors/painter.gwl").read_text().splitlines()
requests = {"jev": 0, "prompt": 0}


class Stub(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path.endswith("/v1/systemone"):
            requests["jev"] += 1
            assert self.headers["X-Coworld-Player-Slot"] == "0"
            criteria = body["questions"]["action"]["criteria"]
            assert len(criteria) == 3
            response = {"answers": {"action": {"type": "choice", "probabilities":
                {name: 1.0 if name == "1" else 0.0 for name in criteria}}}}
        else:
            requests["prompt"] += 1
            assert self.headers["X-Coworld-Player-Slot"] == "1"
            response = {"content": [{"type": "text", "text": json.dumps(
                {"script": PAINTER, "notes": "stub", "banner": "painting"})}],
                "stop_reason": "end_turn"}
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


model = ThreadingHTTPServer(("127.0.0.1", free_port()), Stub)
threading.Thread(target=model.serve_forever, daemon=True).start()
port = free_port()
with tempfile.TemporaryDirectory(prefix="gridwars-policy-") as scratch:
    root = Path(scratch)
    config = {"tokens": [f"token-{seat}" for seat in range(4)],
              "players": [{"name": f"Policy {seat}"} for seat in range(4)],
              "seed": 7, "rounds": 2, "ticks": 30, "sampled": True,
              "roundDelayMs": 0, "actionTimeoutSeconds": 8,
              "player_connect_timeout_seconds": 8}
    (root / "config.json").write_text(json.dumps(config))
    game_env = os.environ.copy()
    game_env.update({"COGAME_HOST": "127.0.0.1", "COGAME_PORT": str(port),
                     "COGAME_CONFIG_URI": (root / "config.json").as_uri(),
                     "COGAME_RESULTS_URI": (root / "results.json").as_uri(),
                     "COGAME_SAVE_REPLAY_URI": (root / "replay.json").as_uri()})
    game = subprocess.Popen([GAME], env=game_env,
                            stdout=(root / "game.log").open("w"), stderr=subprocess.STDOUT)
    players = []
    try:
        for _ in range(100):
            if game.poll() is not None:
                raise AssertionError((root / "game.log").read_text())
            with socket.socket() as probe:
                if probe.connect_ex(("127.0.0.1", port)) == 0:
                    break
            time.sleep(0.05)
        else:
            raise AssertionError("game socket unavailable")
        for slot, settings in enumerate((
            {"POC_JEV": "1"},
            {"PLAYER_PROMPT": "Paint and survive."},
            {"PLAYER_SCRIPTED": "painter"},
            {"PLAYER_SCRIPTED": "bomber"},
        )):
            env = os.environ.copy()
            env.update(settings)
            env.update({"COWORLD_PLAYER_WS_URL":
                        f"ws://127.0.0.1:{port}/player?slot={slot}&token=token-{slot}",
                        "AWS_ENDPOINT_URL_BEDROCK_RUNTIME":
                        f"http://127.0.0.1:{model.server_port}"})
            command = [sys.executable, str(ROOT / "players/ordinary/player.py")] if slot == 0 else [PLAYER]
            players.append(subprocess.Popen(command, env=env, cwd=ROOT,
                           stdout=(root / f"player-{slot}.log").open("w"),
                           stderr=subprocess.STDOUT))
        assert game.wait(timeout=65) == 0, (root / "game.log").read_text()
        for slot, player in enumerate(players):
            assert player.wait(timeout=5) == 0, (root / f"player-{slot}.log").read_text()
        results = json.loads((root / "results.json").read_text())
        replay = json.loads((root / "replay.json").read_text())
        assert requests == {"jev": 2, "prompt": 2}, requests
        assert results["reason"] == "complete", results
        submissions = [event for event in replay["events"] if event["kind"] == "submit"]
        assert len(submissions) == 8, len(submissions)
        assert [event["origin"] for event in submissions] == [
            "player", "player", "scripted", "scripted"] * 2, submissions
        print("Grid Wars player smoke: 2 Jev, 2 prompt, 4 scripted programs, zero fallback")
    finally:
        for process in [*players, game]:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)
        model.shutdown()
