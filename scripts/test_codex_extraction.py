#!/usr/bin/env python3
"""Verify Codex extraction for legacy and desktop session records."""

from __future__ import annotations

import json
import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVICE = ROOT / "token-top" / "service.luau"


def service_pattern(name: str) -> str:
    source = SERVICE.read_text(encoding="utf-8")
    match = re.search(rf"local {name} = \[\[(.*?)\]\]", source)
    if match is None:
        raise AssertionError(f"could not find {name} in {SERVICE}")
    return match.group(1)


def compact(pattern: str, replacement: str, path: Path) -> list[str]:
    result = subprocess.run(
        [
            "rg",
            "--no-messages",
            "--no-filename",
            "--no-line-number",
            "--color",
            "never",
            "-P",
            "-o",
            "--replace",
            replacement,
            pattern,
            str(path),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip() or f"rg exited {result.returncode}")
    return result.stdout.splitlines()


def token_record(timestamp: str, *, ordinal: int | None) -> dict[str, object]:
    record: dict[str, object] = {"timestamp": timestamp}
    if ordinal is not None:
        record["ordinal"] = ordinal
    record.update(
        {
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {
                    "total_token_usage": {
                        "input_tokens": 60,
                        "cached_input_tokens": 10,
                        "cache_write_input_tokens": 0,
                        "output_tokens": 25,
                        "reasoning_output_tokens": 5,
                        "total_tokens": 100,
                    }
                },
                "private_payload": "MUST_NOT_APPEAR",
            },
        }
    )
    return record


def turn_record(timestamp: str, turn_id: str, *, ordinal: int | None) -> dict[str, object]:
    record: dict[str, object] = {"timestamp": timestamp}
    if ordinal is not None:
        record["ordinal"] = ordinal
    record.update(
        {
            "type": "turn_context",
            "payload": {"turn_id": turn_id, "private_prompt": "MUST_NOT_APPEAR"},
        }
    )
    return record


def main() -> int:
    legacy_timestamp = "2026-09-01T20:05:17.908Z"
    desktop_timestamp = "2026-09-02T16:20:49.732Z"
    records = [
        token_record(legacy_timestamp, ordinal=None),
        token_record(desktop_timestamp, ordinal=17),
        turn_record(legacy_timestamp, "legacy-turn", ordinal=None),
        turn_record(desktop_timestamp, "desktop-turn", ordinal=18),
        {"timestamp": desktop_timestamp, "ordinal": 19, "type": "response_item"},
    ]

    with tempfile.TemporaryDirectory(prefix="token-top-codex-test-") as temp:
        path = Path(temp) / "rollout.jsonl"
        path.write_text(
            "".join(json.dumps(record, separators=(",", ":")) + "\n" for record in records),
            encoding="utf-8",
        )
        tokens = compact(
            service_pattern("tokenPattern"),
            "C|$timestamp|$total|$input|$output|$cached|$reasoning",
            path,
        )
        turns = compact(service_pattern("turnPattern"), "T|$timestamp|$turn", path)

    assert tokens == [
        f"C|{legacy_timestamp}|100|60|25|10|5",
        f"C|{desktop_timestamp}|100|60|25|10|5",
    ]
    assert turns == [
        f"T|{legacy_timestamp}|legacy-turn",
        f"T|{desktop_timestamp}|desktop-turn",
    ]
    assert all("MUST_NOT_APPEAR" not in line for line in tokens + turns)
    print("synthetic Codex extraction: ok (legacy and desktop layouts)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
