#!/usr/bin/env python3
"""Verify token-top's metadata-only Claude transcript extraction contract."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

PATTERN = (
    r'^(?=\{"parentUuid":)'
    r'(?=.*"type":"assistant","uuid":"[^"]+","timestamp":"(?<timestamp>[^"]+)")'
    r'(?=.*"isSidechain":(?<side>true|false))'
    r'(?=.*"message":\{"model":"(?<model>[^"]+)",'
    r'"id":"(?<message>[^"]+)")'
    r'(?=.*,"usage":\{(?=[^\r\n]*?"input_tokens":(?<input>\d+))'
    r'(?=[^\r\n]*?"cache_creation_input_tokens":(?<create>\d+))'
    r'(?=[^\r\n]*?"cache_read_input_tokens":(?<read>\d+))'
    r'(?=[^\r\n]*?"output_tokens":(?<output>\d+)))'
    r'(?=.*,"cwd":"(?:\\.|[^"])*","sessionId":"(?<session>[^"]+)")'
    r'(?:(?=.*\},"requestId":"(?<request>[^"]+)".*"type":"assistant"))?'
)
REPLACEMENT = (
    "$timestamp|$message|$request|$session|$model|"
    "$input|$create|$read|$output|$side"
)


def canonical(record: dict[str, Any]) -> str:
    request_id = str(record.get("request_id") or "")
    return f"{record['message_id']}|{request_id}" if request_id else record["message_id"]


def prefer(current: dict[str, Any] | None, candidate: dict[str, Any]) -> dict[str, Any]:
    if current is None:
        return candidate
    if current["sidechain"] != candidate["sidechain"]:
        return current if candidate["sidechain"] else candidate
    if candidate["total"] > current["total"]:
        return candidate
    if candidate["total"] == current["total"] and candidate["timestamp"] >= current["timestamp"]:
        return candidate
    return current


def summarize(records: Iterable[dict[str, Any]]) -> tuple[int, int, int, int, int]:
    selected: dict[str, dict[str, Any]] = {}
    for record in records:
        key = canonical(record)
        selected[key] = prefer(selected.get(key), record)
    return (
        len(selected),
        sum(record["input"] for record in selected.values()),
        sum(record["cache_create"] for record in selected.values()),
        sum(record["cache_read"] for record in selected.values()),
        sum(record["output"] for record in selected.values()),
    )


def extract_with_rg(root: Path) -> tuple[list[dict[str, Any]], str]:
    command = [
        "rg",
        "--no-messages",
        "--with-filename",
        "--no-line-number",
        "--color",
        "never",
        "-P",
        "-o",
        "--replace",
        REPLACEMENT,
        PATTERN,
        str(root),
    ]
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip() or f"rg exited {result.returncode}")

    records: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        _, compact = line.split(":", 1)
        fields = compact.split("|")
        if len(fields) != 10:
            raise AssertionError(f"unexpected compact field count: {len(fields)}")
        input_tokens, cache_create, cache_read, output_tokens = map(int, fields[5:9])
        records.append(
            {
                "timestamp": fields[0],
                "message_id": fields[1],
                "request_id": fields[2],
                "session_id": fields[3],
                "model": fields[4],
                "input": input_tokens,
                "cache_create": cache_create,
                "cache_read": cache_read,
                "output": output_tokens,
                "total": input_tokens + cache_create + cache_read + output_tokens,
                "sidechain": fields[9] == "true",
            }
        )
    return records, result.stdout


def extract_with_json(root: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for path in root.rglob("*.jsonl"):
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    value = json.loads(line)
                except json.JSONDecodeError:
                    continue
                message = value.get("message")
                usage = message.get("usage") if isinstance(message, dict) else None
                if value.get("type") != "assistant" or not isinstance(usage, dict):
                    continue
                try:
                    input_tokens = int(usage.get("input_tokens", 0))
                    cache_create = int(usage.get("cache_creation_input_tokens", 0))
                    cache_read = int(usage.get("cache_read_input_tokens", 0))
                    output_tokens = int(usage.get("output_tokens", 0))
                except (TypeError, ValueError):
                    continue
                records.append(
                    {
                        "timestamp": str(value.get("timestamp") or ""),
                        "message_id": str(message.get("id") or ""),
                        "request_id": str(value.get("requestId") or ""),
                        "session_id": str(value.get("sessionId") or ""),
                        "model": str(message.get("model") or "Unknown"),
                        "input": input_tokens,
                        "cache_create": cache_create,
                        "cache_read": cache_read,
                        "output": output_tokens,
                        "total": input_tokens + cache_create + cache_read + output_tokens,
                        "sidechain": value.get("isSidechain") is True,
                    }
                )
    return [record for record in records if record["message_id"] and record["session_id"]]


def extract_with_jq(root: Path) -> list[dict[str, Any]]:
    paths = sorted(root.rglob("*.jsonl"))
    if not paths:
        return []
    program = (
        "fromjson? | "
        'select(.type == "assistant" and (.message.usage | type) == "object") | '
        "[.timestamp // \"\", .message.id // \"\", .requestId // \"\", "
        ".sessionId // \"\", .message.model // \"Unknown\", "
        "(.message.usage.input_tokens // 0), "
        "(.message.usage.cache_creation_input_tokens // 0), "
        "(.message.usage.cache_read_input_tokens // 0), "
        "(.message.usage.output_tokens // 0), (.isSidechain == true)] | @tsv"
    )
    result = subprocess.run(
        ["jq", "-Rrc", program, *(str(path) for path in paths)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or f"jq exited {result.returncode}")

    records: list[dict[str, Any]] = []
    for line in result.stdout.splitlines():
        fields = line.split("\t")
        if len(fields) != 10:
            raise AssertionError(f"unexpected jq field count: {len(fields)}")
        input_tokens, cache_create, cache_read, output_tokens = map(int, fields[5:9])
        records.append(
            {
                "timestamp": fields[0],
                "message_id": fields[1],
                "request_id": fields[2],
                "session_id": fields[3],
                "model": fields[4],
                "input": input_tokens,
                "cache_create": cache_create,
                "cache_read": cache_read,
                "output": output_tokens,
                "total": input_tokens + cache_create + cache_read + output_tokens,
                "sidechain": fields[9] == "true",
            }
        )
    return [record for record in records if record["message_id"] and record["session_id"]]


def file_signatures(root: Path) -> dict[Path, tuple[int, int]]:
    return {
        path: (path.stat().st_size, path.stat().st_mtime_ns)
        for path in root.rglob("*.jsonl")
    }


def incremental_changes(
    current: dict[Path, tuple[int, int]],
    previous: dict[Path, tuple[int, int]],
) -> tuple[set[Path], set[Path]]:
    changed = {path for path, signature in current.items() if previous.get(path) != signature}
    removed = set(previous) - set(current)
    return changed, removed


def parse_iso(value: str) -> int:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    return int(datetime.fromisoformat(normalized).timestamp())


def window_mode(now: int, weekly: dict[str, int] | None) -> tuple[str, int, int]:
    if weekly and weekly.get("reset_at", 0) > now and weekly.get("seconds", 0) > 0:
        return "exact", weekly["reset_at"] - weekly["seconds"], weekly["reset_at"]
    return "rolling", now - 7 * 86400, now + 1


def group_model_mix(models: list[tuple[str, int, int]]) -> list[tuple[str, int, int]]:
    ordered = sorted(models, key=lambda model: (-model[1], -model[2], model[0]))
    if len(ordered) <= 3:
        return ordered
    return ordered[:3] + [
        (
            "Other",
            sum(model[1] for model in ordered[3:]),
            sum(model[2] for model in ordered[3:]),
        )
    ]


def assistant_record(
    *,
    timestamp: str,
    message_id: str,
    session_id: str,
    request_id: str | None,
    sidechain: bool,
    input_tokens: int,
    cache_create: int,
    cache_read: int,
    output_tokens: int,
) -> dict[str, Any]:
    value: dict[str, Any] = {
        "parentUuid": None,
        "isSidechain": sidechain,
        "message": {
            "model": "claude-test",
            "id": message_id,
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "PRIVATE_RESPONSE"}],
            "usage": {
                "input_tokens": input_tokens,
                "cache_creation_input_tokens": cache_create,
                "cache_read_input_tokens": cache_read,
                "output_tokens": output_tokens,
            },
        },
    }
    if request_id is not None:
        value["requestId"] = request_id
    value.update(
        {
            "type": "assistant",
            "uuid": f"uuid-{message_id}-{output_tokens}",
            "timestamp": timestamp,
            "userType": "external",
            "cwd": "/tmp/private-project",
            "sessionId": session_id,
            "version": "2.1.220",
        }
    )
    return value


def write_jsonl(path: Path, records: Iterable[dict[str, Any] | str]) -> None:
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(record if isinstance(record, str) else json.dumps(record, separators=(",", ":")))
            handle.write("\n")


def run_synthetic_test() -> None:
    with tempfile.TemporaryDirectory(prefix="token-top-claude-test-") as temp:
        root = Path(temp)
        parent = assistant_record(
            timestamp="2026-07-25T10:30:00.123456+00:00",
            message_id="msg-a",
            session_id="session-parent",
            request_id="request-a",
            sidechain=False,
            input_tokens=10,
            cache_create=20,
            cache_read=30,
            output_tokens=40,
        )
        partial = json.loads(json.dumps(parent))
        partial["message"]["usage"]["output_tokens"] = 4
        partial["uuid"] = "uuid-partial"
        sidechain = json.loads(json.dumps(parent))
        sidechain["isSidechain"] = True
        sidechain["sessionId"] = "session-agent"
        missing_request = assistant_record(
            timestamp="2026-07-25T11:00:00Z",
            message_id="msg-b",
            session_id="session-parent",
            request_id=None,
            sidechain=False,
            input_tokens=2,
            cache_create=3,
            cache_read=5,
            output_tokens=7,
        )
        malformed = '{"parentUuid":null,"prompt":"PRIVATE_PROMPT","padding":"' + ("x" * 70000) + '"}'

        parent_path = root / "project-a" / "parent.jsonl"
        agent_path = root / "project-b" / "agents" / "agent.jsonl"
        parent_path.parent.mkdir(parents=True)
        agent_path.parent.mkdir(parents=True)
        write_jsonl(parent_path, [partial, parent, missing_request, malformed])
        write_jsonl(agent_path, [sidechain])

        rg_records, compact_output = extract_with_rg(root)
        json_records = extract_with_json(root)
        jq_records = extract_with_jq(root)
        expected = (2, 12, 23, 35, 47)
        assert summarize(rg_records) == expected
        assert summarize(json_records) == expected
        assert summarize(jq_records) == expected
        assert "PRIVATE_PROMPT" not in compact_output
        assert "PRIVATE_RESPONSE" not in compact_output
        assert "/tmp/private-project" not in compact_output

        initial = file_signatures(root)
        changed, removed = incremental_changes(initial, {})
        assert changed == {parent_path, agent_path} and not removed
        assert incremental_changes(file_signatures(root), initial) == (set(), set())
        with parent_path.open("a", encoding="utf-8") as handle:
            handle.write("{}\n")
        modified = file_signatures(root)
        changed, removed = incremental_changes(modified, initial)
        assert changed == {parent_path} and not removed
        agent_path.unlink()
        changed, removed = incremental_changes(file_signatures(root), modified)
        assert not changed and removed == {agent_path}

        assert parse_iso("2026-07-25T11:00:00Z") == parse_iso("2026-07-25T11:00:00+00:00")
        now = parse_iso("2026-07-25T11:00:00Z")
        assert window_mode(now, None)[0] == "rolling"
        assert window_mode(now, {"reset_at": now + 3600, "seconds": 7 * 86400}) == (
            "exact",
            now + 3600 - 7 * 86400,
            now + 3600,
        )
        assert group_model_mix(
            [
                ("model-a", 500, 2),
                ("model-b", 400, 3),
                ("model-c", 300, 4),
                ("model-d", 200, 5),
                ("model-e", 100, 6),
            ]
        ) == [
            ("model-a", 500, 2),
            ("model-b", 400, 3),
            ("model-c", 300, 4),
            ("Other", 300, 11),
        ]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--live-root",
        type=Path,
        help="Optionally compare rg metadata extraction with a JSON oracle under this projects directory.",
    )
    args = parser.parse_args()

    run_synthetic_test()
    print("synthetic Claude extraction: ok")

    if args.live_root is not None:
        root = args.live_root.expanduser().resolve()
        rg_records, compact_output = extract_with_rg(root)
        json_records = extract_with_json(root)
        jq_records = extract_with_jq(root)
        rg_summary = summarize(rg_records)
        json_summary = summarize(json_records)
        jq_summary = summarize(jq_records)
        if rg_summary != json_summary or rg_summary != jq_summary:
            raise AssertionError(
                f"live extraction mismatch: rg={rg_summary}, json={json_summary}, jq={jq_summary}"
            )
        if '"content"' in compact_output or '"prompt"' in compact_output:
            raise AssertionError("compact output leaked transcript fields")
        print(f"live Claude extraction: ok ({rg_summary[0]} deduplicated requests)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
