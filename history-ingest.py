#!/usr/bin/env python3
"""
Discord history ingest: incrementally reads Claude session JSONL files,
extracts Discord messages, embeds them with OpenAI, stores in sqlite-vec.
"""

import json
import glob
import os
import re
import sys
import sqlite3
from datetime import datetime

import sqlite_vec
from openai import OpenAI

from common import DB_PATH, EMBED_MODEL, EMBED_DIMS, get_openai_key

JSONL_GLOB = "/home/clungus/.claude/projects/-mnt-data/*.jsonl"
BATCH_SIZE = 100

_UPSERT_STATE = (
    "INSERT INTO ingest_state (filepath, byte_offset, last_size) VALUES (?, ?, ?) "
    "ON CONFLICT(filepath) DO UPDATE SET byte_offset=excluded.byte_offset, last_size=excluded.last_size"
)


def open_db() -> sqlite3.Connection:
    conn = sqlite3.connect(DB_PATH)
    conn.enable_load_extension(True)
    sqlite_vec.load(conn)
    conn.enable_load_extension(False)

    conn.executescript(f"""
        CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            message_id TEXT UNIQUE,
            author TEXT,
            channel_id TEXT,
            ts TEXT,
            content TEXT
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS messages_vec USING vec0(
            embedding float[{EMBED_DIMS}]
        );

        CREATE TABLE IF NOT EXISTS ingest_state (
            filepath TEXT PRIMARY KEY,
            byte_offset INTEGER,
            last_size INTEGER
        );
    """)
    conn.commit()
    return conn


# ---- Parsers ----------------------------------------------------------------

_CHANNEL_RE = re.compile(
    r'<channel\s+source="plugin:discord:discord"\s+'
    r'chat_id="([^"]+)"\s+'
    r'message_id="([^"]+)"\s+'
    r'user="([^"]+)"[^>]*?ts="([^"]+)"[^>]*?>(.*?)</channel>',
    re.DOTALL,
)

_FETCH_LINE_RE = re.compile(
    r'^\[([^\]]+)\]\s+([^:]+):\s+(.*?)\s+\(id:\s+(\d+)\)\s*$'
)


def extract_from_channel_tag(text: str) -> list[dict]:
    """Extract Discord messages from <channel ...> XML tags in user messages."""
    messages = []
    for m in _CHANNEL_RE.finditer(text):
        chat_id, message_id, user, ts, body = m.groups()
        content = body.strip()
        # Strip out <thread_context> blocks
        content = re.sub(r'<thread_context>.*?</thread_context>', '', content, flags=re.DOTALL).strip()
        if content and not content.startswith('['):
            messages.append({
                "message_id": message_id,
                "author": user,
                "channel_id": chat_id,
                "ts": ts,
                "content": content,
            })
    return messages


def extract_from_fetch_result(text: str) -> list[dict]:
    """Extract Discord messages from fetch_messages tool results."""
    messages = []
    for line in text.splitlines():
        line = line.strip()
        m = _FETCH_LINE_RE.match(line)
        if m:
            ts_str, author, content, msg_id = m.groups()
            # Normalize author: 'me' means the bot
            if author.strip() == "me":
                author = "BigClungus"
            messages.append({
                "message_id": msg_id,
                "author": author.strip(),
                "channel_id": "",  # fetch results don't carry channel_id inline
                "ts": ts_str,
                "content": content.strip(),
            })
    return messages


def extract_messages_from_jsonl(filepath: str, start_offset: int) -> tuple[list[dict], int]:
    """
    Read a JSONL file from start_offset, extract all Discord messages.
    Returns (messages, new_byte_offset).
    """
    messages = []
    new_offset = start_offset

    try:
        with open(filepath, "rb") as f:
            f.seek(start_offset)
            while True:
                line = f.readline()
                if not line:
                    break
                new_offset = f.tell()
                try:
                    obj = json.loads(line.decode("utf-8", errors="replace"))
                except json.JSONDecodeError:
                    continue

                msg = obj.get("message", {})
                content = msg.get("content", [])

                # Case 1: user message with <channel> XML tag (inbound Discord messages)
                if isinstance(content, str) and "<channel source=" in content:
                    messages.extend(extract_from_channel_tag(content))

                elif isinstance(content, list):
                    for item in content:
                        if not isinstance(item, dict):
                            continue

                        # Case 2: user message content block with <channel> XML
                        item_text = item.get("text", "") or item.get("content", "")
                        if isinstance(item_text, str) and "<channel source=" in item_text:
                            messages.extend(extract_from_channel_tag(item_text))

                        # Case 3: tool_result from fetch_messages
                        elif item.get("type") == "tool_result":
                            sub = item.get("content", [])
                            if isinstance(sub, list):
                                for s in sub:
                                    if isinstance(s, dict):
                                        t = s.get("text", "")
                                        if t and _FETCH_LINE_RE.search(t):
                                            messages.extend(extract_from_fetch_result(t))
                            elif isinstance(sub, str) and _FETCH_LINE_RE.search(sub):
                                messages.extend(extract_from_fetch_result(sub))

    except OSError as e:
        print(f"  WARNING: could not read {filepath}: {e}", file=sys.stderr)

    return messages, new_offset


# ---- Embeddings -------------------------------------------------------------

def embed_batch(client: OpenAI, texts: list[str]) -> list[list[float]]:
    response = client.embeddings.create(
        model=EMBED_MODEL,
        input=texts,
    )
    return [item.embedding for item in response.data]


# ---- Main ingest loop -------------------------------------------------------

def run_ingest():
    api_key = get_openai_key()
    client = OpenAI(api_key=api_key)
    conn = open_db()

    jsonl_files = sorted(glob.glob(JSONL_GLOB))
    print(f"Found {len(jsonl_files)} JSONL files")

    total_new = 0

    for filepath in jsonl_files:
        current_size = os.path.getsize(filepath)

        row = conn.execute(
            "SELECT byte_offset, last_size FROM ingest_state WHERE filepath = ?",
            (filepath,)
        ).fetchone()

        if row:
            stored_offset, stored_size = row
            if current_size == stored_size:
                # No change
                continue
            start_offset = stored_offset
        else:
            start_offset = 0

        messages, new_offset = extract_messages_from_jsonl(filepath, start_offset)

        if not messages:
            # Update state even if no messages found (file grew but had no Discord content)
            conn.execute(
                _UPSERT_STATE,
                (filepath, new_offset, current_size)
            )
            conn.commit()
            continue

        seen_ids: set[str] = set()
        candidates = []
        for m in messages:
            mid = m["message_id"]
            if mid in seen_ids:
                continue
            seen_ids.add(mid)
            if not m.get("content", "").strip():
                continue
            candidates.append(m)

        if candidates:
            batch_ids = [m["message_id"] for m in candidates]
            existing_ids = set(
                row[0] for row in conn.execute(
                    f"SELECT message_id FROM messages WHERE message_id IN ({','.join('?' * len(batch_ids))})",
                    batch_ids
                ).fetchall()
            )
            new_messages = [m for m in candidates if m["message_id"] not in existing_ids]
        else:
            new_messages = []

        if not new_messages:
            conn.execute(
                _UPSERT_STATE,
                (filepath, new_offset, current_size)
            )
            conn.commit()
            continue

        print(f"  {os.path.basename(filepath)}: {len(new_messages)} new messages")

        for i in range(0, len(new_messages), BATCH_SIZE):
            batch = new_messages[i:i + BATCH_SIZE]
            texts = [m["content"] for m in batch]
            try:
                embeddings = embed_batch(client, texts)
            except Exception as e:
                print(f"  ERROR embedding batch: {e}", file=sys.stderr)
                raise  # No silent failures

            for msg, emb in zip(batch, embeddings):
                cursor = conn.execute(
                    "INSERT OR IGNORE INTO messages (message_id, author, channel_id, ts, content) "
                    "VALUES (?, ?, ?, ?, ?) RETURNING id",
                    (msg["message_id"], msg["author"], msg["channel_id"], msg["ts"], msg["content"])
                )
                row = cursor.fetchone()
                if row is None:
                    row = conn.execute(
                        "SELECT id FROM messages WHERE message_id = ?", (msg["message_id"],)
                    ).fetchone()
                if row:
                    emb_bytes = sqlite_vec.serialize_float32(emb)
                    conn.execute(
                        "INSERT OR IGNORE INTO messages_vec (rowid, embedding) VALUES (?, ?)",
                        (row[0], emb_bytes)
                    )

            conn.commit()
            total_new += len(batch)

        conn.execute(_UPSERT_STATE, (filepath, new_offset, current_size))
        conn.commit()

    total_messages = conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0]
    conn.close()
    print(f"Ingest complete. New messages this run: {total_new}. Total in DB: {total_messages}.")


if __name__ == "__main__":
    run_ingest()
