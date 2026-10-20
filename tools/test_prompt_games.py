"""Complete Grid Wars series through real language and numeric decisions."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = Path(sys.argv[1]).resolve()
ORIGINAL = Path(sys.argv[2]).resolve() if len(sys.argv) == 3 else None
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(binary, variant, seed, wording="canonical", prompt_seed=0, text=False):
    with subprocess.Popen(
        [str(binary), str(ROOT / "coworld_manifest_template.json"), variant] + (["text"] if text else []),
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            line = process.stdout.readline()
            assert line, process.poll()
            return json.loads(line)

        observation = request(
            dict(
                kind="reset",
                players=4,
                seed=str(seed),
                promptVariant=wording,
                promptSeed=prompt_seed,
                split="test",
            )
        )
        trace, systems = [], {}
        while observation["kind"] == "decision":
            view = observation["semantic_view"].copy()
            if binary == BRIDGE:
                metadata = view.pop("prompt_template")
                assert metadata["bank"] == "grid-wars-rules-v2"
                assert metadata["variant"] == (WORDINGS[prompt_seed % 5] if wording == "mixed" else wording)
                for message in observation["messages"]:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
            system = view.pop("system")
            assert system == observation["messages"][0]["content"]
            seat = observation["seat"]
            assert systems.setdefault(seat, system) == system
            encoding = request({"kind": "encode"})
            assert len(encoding["values"]) == 933
            action = json.loads(request({"kind": "teacher"})["response"])
            if text:
                action["notes"] = f"PRIVATE-NOTE-{seat}"
                action["banner"] = f"BANNER-{seat}"
                assert all(f"PRIVATE-NOTE-{other}" not in view["user"] for other in range(4) if other != seat)
            reply = request(
                dict(
                    kind="step",
                    decision_id=observation["decision_id"],
                    response=json.dumps(action),
                )
            )
            assert reply["kind"] == "accepted"
            assert reply["action"] == action
            trace.append((view, encoding, action, reply["action"]))
            observation = reply["observation"]
        assert len(trace) == (20 if variant == "standard" else 12)
        assert abs(sum(observation["scores"].values())) < 1e-6
        process.stdin.close()
        assert process.wait(timeout=10) == 0
        return trace, observation, systems


def main():
    for wording in WORDINGS[-2:]:
        for split in (None, "train", "typo"):
            reset = {"kind": "reset", "players": 4, "seed": "7",
                     "promptVariant": wording}
            if split is not None:
                reset["split"] = split
            rejected = subprocess.run(
                [str(BRIDGE), str(ROOT / "coworld_manifest_template.json"), "standard"],
                input=json.dumps(reset) + "\n", text=True, capture_output=True, timeout=30,
            )
            assert rejected.returncode != 0
            assert "held-out wording requires an explicit evaluation split" in rejected.stderr
    count = 0
    for variant in ("standard", "blitz"):
        for seed in (7,):
            numeric = play(BRIDGE, variant, seed)
            count += 1
            if ORIGINAL:
                assert numeric == play(ORIGINAL, variant, seed)
            for text in (False, True):
                reference = play(BRIDGE, variant, seed, text=text)
                count += 1
                for wording in WORDINGS[1:]:
                    actual = play(BRIDGE, variant, seed, wording, text=text)
                    assert actual[:2] == reference[:2]
                    assert all(actual[2][seat] != reference[2][seat] for seat in range(4))
                    count += 1
                for prompt_seed in (4,):
                    actual = play(BRIDGE, variant, seed, "mixed", prompt_seed, text)
                    assert actual[:2] == reference[:2]
                    count += 1
            print(variant, seed, "numeric and full-program wording games PASS", flush=True)
    print(count, "complete matches; canonical reference comparisons PASS", flush=True)


if __name__ == "__main__":
    main()
