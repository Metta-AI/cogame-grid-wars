"""Grid Wars programs through the game's ordinary player WebSocket."""

from __future__ import annotations

import json
import os
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websocket
from capture import Capture


def choose(turn: dict, generator) -> tuple[dict, str]:
    rules_file = Path(os.environ.get("GRIDWARS_RULES_FILE",
                      Path(__file__).resolve().parents[2] / "docs" / "warrior-language.md"))
    turn["system"] = "Write one complete GWL warrior program. Reply with " \
        "JSON containing script as an array of lines, notes, and banner.\n\n" \
        + rules_file.read_text()
    turn["user"] = turn["observation"] + "\n" + os.environ.get("PLAYER_PROMPT", "")
    warrior_dir = Path(os.environ.get("GRIDWARS_WARRIOR_DIR",
                              Path(__file__).resolve().parents[2] / "data" / "warriors"))
    if generator:
        completion = generator([
            {"role": "system", "content": turn["system"]},
            {"role": "user", "content": turn["user"]},
        ])
        action = json.loads(completion)
        if not isinstance(action, dict):
            raise ValueError("trained Grid Wars submission must be a JSON object")
        return action, "trained"
    return {"script": (warrior_dir / "painter.gwl").read_text().splitlines(),
            "notes": "", "banner": ""}, "canned"


def main() -> None:
    url = os.environ["COWORLD_PLAYER_WS_URL"]
    slot = int(parse_qs(urlsplit(url).query)["slot"][0])
    adapter = os.environ.get("POC_ADAPTER_DIR")
    generator = None
    if adapter:
        from posttrain import TransformersGenerator

        generator = TransformersGenerator(Path(adapter))
    backend = "trained" if adapter else "canned"
    artifact = Capture(slot, backend) if os.environ.get("POC_CAPTURE_TRAINING") == "1" else None
    socket = websocket.create_connection(url, timeout=60)
    socket.settimeout(None)
    pending: dict[int, tuple[dict, dict, str]] = {}
    while True:
        opcode, data = socket.recv_data(control_frame=True)
        if opcode == websocket.ABNF.OPCODE_CLOSE:
            raise RuntimeError("Grid Wars closed before the final frame")
        if opcode != websocket.ABNF.OPCODE_TEXT:
            continue
        frame = json.loads(data)
        kind = frame["type"]
        if kind == "turn":
            action, source = choose(frame, generator)
            pending[frame["round"]] = (frame, action, source)
            socket.send(json.dumps({"type": "submission", "round": frame["round"],
                                    "source": "player", "action": action}))
        elif kind == "submission_result":
            turn, action, source = pending.pop(frame["round"])
            if artifact and frame["accepted"]:
                artifact.record(turn["system"], turn["user"], action, source,
                                frame["round"])
        elif kind == "final":
            if pending:
                raise RuntimeError("Grid Wars ended with unacknowledged decisions")
            if artifact:
                artifact.upload(frame["scores"])
            break
    socket.close()
    print(f"Grid Wars ordinary player finished: slot={slot} backend={backend}",
          flush=True)


if __name__ == "__main__":
    main()
