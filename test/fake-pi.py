#!/usr/bin/env python3
"""Tiny deterministic Pi RPC peer used by Emacs integration tests."""

import json
import sys


def send(record):
    sys.stdout.write(json.dumps(record, ensure_ascii=False) + "\n")
    sys.stdout.flush()


messages = []
entries = []
leaf = None
counter = 0

for raw in sys.stdin:
    command = json.loads(raw)
    kind = command.get("type")
    request_id = command.get("id")
    if kind == "get_state":
        data = {
            "sessionId": "fake-session",
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
    elif kind in ("clear_queue", "abort"):
        data = {"steering": [], "followUp": []} if kind == "clear_queue" else {}
    elif kind == "prompt":
        send({"id": request_id, "type": "response", "command": kind, "success": True})
        text = command.get("message", "")
        user = {"role": "user", "content": text, "timestamp": 1000 + counter}
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
