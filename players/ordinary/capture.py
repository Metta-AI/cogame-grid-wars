"""Retain all player attempts and host execution acknowledgements in the standard Coworld artifact."""

from __future__ import annotations

import hashlib
import io
import json
import os
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path
from urllib.parse import unquote, urlsplit


class Capture:
    def __init__(self, slot: int, backend: str) -> None:
        self.slot = slot
        self.backend = backend
        self.revision = os.environ["POC_SOURCE_REVISION"]
        self.upload_url = os.environ["COWORLD_PLAYER_ARTIFACT_UPLOAD_URL"]
        self.rows: dict[int, dict] = {}
        self.directory = Path(tempfile.mkdtemp(prefix="grid-wars-player-evidence-"))
        self.journal = self.directory / "attempts.jsonl"
        self.journal.touch(mode=0o600, exist_ok=False)
        print(f"Private Grid Wars attempt evidence: {self.journal}", flush=True)

    def persist(self, record: dict) -> None:
        with self.journal.open("a") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")

    def begin(self, turn: dict, source: str) -> None:
        prompt = [
            {"role": "system", "content": turn["system"]},
            {"role": "user", "content": turn["user"]},
        ]
        metadata = dict(turn["prompt_selection"])
        for message in prompt:
            metadata[message["role"] + "_sha256"] = hashlib.sha256(
                message["content"].encode()
            ).hexdigest()
        self.rows[turn["round"]] = {
            "decision_id": turn["round"],
            "turn": turn["round"],
            "source": source,
            "prompt": prompt,
            "prompt_template": metadata,
            "observation": turn["observation"],
            "started_ns": time.time_ns(),
            "raw_response": None,
            "platform_call_id": None,
            "behavior_logprobs": None,
        }
        self.persist({"event_type": "attempt_started", **self.rows[turn["round"]]})

    def response(self, turn: int, response: str) -> None:
        self.rows[turn]["raw_response"] = response
        self.persist(
            {"event_type": "attempt_response", "turn": turn, "raw_response": response}
        )

    def acknowledge(self, result: dict) -> None:
        self.rows[result["round"]]["execution"] = result
        self.persist({"event_type": "execution", **result})

    def upload(self, scores: list[float]) -> None:
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as output:
            output.writestr(
                "trajectory.json",
                json.dumps(
                    {
                        "schema_version": 2,
                        "game": "grid-wars",
                        "slot": self.slot,
                        "backend": self.backend,
                        "source_revision": self.revision,
                        "complete": True,
                        "scores": scores,
                        "decisions": list(self.rows.values()),
                    }
                ),
            )
        data = archive.getvalue()
        url = urlsplit(self.upload_url)
        if url.scheme == "file":
            target = Path(unquote(url.path))
            pending = target.with_name(target.name + ".tmp")
            with pending.open("xb") as stream:
                os.chmod(pending, 0o600)
                stream.write(data)
            os.replace(pending, target)
        else:
            request = urllib.request.Request(
                self.upload_url,
                data=data,
                method="PUT",
                headers={"Content-Type": "application/zip"},
            )
            with urllib.request.urlopen(request, timeout=10) as response:
                response.read()
