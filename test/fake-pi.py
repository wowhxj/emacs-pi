#!/usr/bin/env python3
"""Tiny deterministic Pi RPC peer used by Emacs integration tests."""

import json
import os
import sys
from datetime import datetime, timezone


def send(record):
    sys.stdout.write(json.dumps(record, ensure_ascii=False) + "\n")
    sys.stdout.flush()


messages = []
entries = []
leaf = None
counter = 0
session_file = None
session_id = "fake-session"
if "--session" in sys.argv:
    session_file = sys.argv[sys.argv.index("--session") + 1]
    with open(session_file, encoding="utf-8") as history:
        session_id = json.loads(history.readline())["id"]
elif "--fork" in sys.argv:
    source_file = sys.argv[sys.argv.index("--fork") + 1]
    with open(source_file, encoding="utf-8") as source:
        source_entries = [json.loads(line) for line in source if line.strip()]
    source_header = source_entries[0]
    session_id = "fake-fork-" + source_header["id"]
    session_directory = (sys.argv[sys.argv.index("--session-dir") + 1]
                         if "--session-dir" in sys.argv else os.getcwd())
    os.makedirs(session_directory, exist_ok=True)
    timestamp = datetime.now(timezone.utc).isoformat().replace(":", "-").replace(".", "-")
    session_file = os.path.join(session_directory, f"{timestamp}_{session_id}.jsonl")
    header = {"type": "session", "version": source_header.get("version", 1),
              "id": session_id, "timestamp": datetime.now(timezone.utc).isoformat(),
              "cwd": os.getcwd(), "parentSession": os.path.realpath(source_file)}
    with open(session_file, "w", encoding="utf-8") as fork:
        fork.write(json.dumps(header) + "\n")
        for entry in source_entries:
            if entry.get("type") != "session":
                fork.write(json.dumps(entry) + "\n")

for raw in sys.stdin:
    command = json.loads(raw)
    kind = command.get("type")
    request_id = command.get("id")
    if kind == "get_state":
        data = {
            "sessionId": session_id,
            "sessionFile": session_file,
            "thinkingLevel": "off",
            "isStreaming": False,
            "model": {"provider": "fake", "id": "test"},
        }
    elif kind == "get_entries":
        data = {"entries": entries, "leafId": leaf}
    elif kind == "get_commands":
        data = {"commands": [{"name": "demo", "source": "extension",
                              "description": "Fake extension command"}]}
    elif kind == "get_available_thinking_levels":
        data = {"levels": ["off"]}
    elif kind == "get_session_stats":
        data = {"contextUsage": {"tokens": 1200,
                                  "contextWindow": 10000, "percent": 12}}
    elif kind in ("clear_queue", "abort"):
        data = {"steering": [], "followUp": []} if kind == "clear_queue" else {}
    elif kind == "compact":
        send({"type": "compaction_start"})
        send({"type": "compaction_end"})
        data = {"summary": "Fake compacted context"}
    elif kind == "prompt":
        send({"id": request_id, "type": "response", "command": kind, "success": True})
        text = command.get("message", "")
        images = command.get("images", [])
        content = ([{"type": "text", "text": text}] + images) if images else text
        user = {"role": "user", "content": content, "timestamp": 1000 + counter}
        answer = "收到：" + text
        assistant = {
            "role": "assistant",
            "content": [{"type": "text", "text": answer}],
            "stopReason": "stop",
            "timestamp": 2000 + counter,
        }
        send({"type": "agent_start"})
        send({"type": "message_end", "message": user})
        send({"type": "message_start", "message": {"role": "assistant", "content": []}})
        send({"type": "message_update", "assistantMessageEvent": {
            "type": "text_delta", "contentIndex": 0, "delta": "收到："}})
        send({"type": "message_update", "assistantMessageEvent": {
            "type": "text_delta", "contentIndex": 0, "delta": text}})
        send({"type": "message_end", "message": assistant})
        send({"type": "agent_end", "messages": [assistant], "willRetry": False})
        send({"type": "agent_settled"})
        for message in (user, assistant):
            counter += 1
            new_id = f"entry-{counter}"
            entries.append({
                "id": new_id, "parentId": leaf, "type": "message",
                "message": message, "timestamp": "2026-09-29T00:00:00Z",
            })
            leaf = new_id
        continue
    else:
        send({"id": request_id, "type": "response", "command": kind,
              "success": False, "error": "unsupported fake command"})
        continue
    send({"id": request_id, "type": "response", "command": kind,
          "success": True, "data": data})
