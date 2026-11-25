#!/usr/bin/env python3
"""Pack DiscordBotClient runtime web assets into flat DiscordBotClient/WebBundle.json."""

import base64
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_WEB_SRC = os.path.join(os.path.dirname(ROOT), "discord-bot-client-web")
OUT_PATH = os.path.join(ROOT, "DiscordBotClient", "WebBundle.json")

MIME_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".htm": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".mjs": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".woff": "font/woff",
    ".woff2": "font/woff2",
    ".ttf": "font/ttf",
    ".txt": "text/plain; charset=utf-8",
}

EDITOR_ALLOW_FILES = {
    "index.html",
    "manifest.json",
    "favicon.ico",
    "emoji.json",
    "robots.txt",
    "apple-touch-icon.png",
    "apple-touch-icon-precomposed.png",
    "i18n/en.json",
}

EDITOR_ALLOW_DIRS = (
    "fonts/",
    "logos/",
    "discord-avatars/",
)


def mime_for(path: str) -> str:
    _, ext = os.path.splitext(path.lower())
    return MIME_TYPES.get(ext, "application/octet-stream")


def add_file(files_map: dict, key: str, src_path: str) -> None:
    with open(src_path, "rb") as f:
        raw = f.read()
    files_map[key] = {
        "mime": mime_for(src_path),
        "b64": base64.b64encode(raw).decode("ascii"),
    }


def main() -> int:
    web_src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_WEB_SRC
    if not os.path.isdir(web_src):
        raise SystemExit(f"Web source directory not found: {web_src}")

    files_map: dict[str, dict[str, str]] = {}

    # 1. snapshot/*
    snap_dir = os.path.join(web_src, "assets", "snapshot")
    for name in sorted(os.listdir(snap_dir)):
        fp = os.path.join(snap_dir, name)
        if os.path.isfile(fp):
            add_file(files_map, f"snapshot/{name}", fp)

    # 2. vencord-ext/* (exclude vendor/monaco bloat)
    vencord_dir = os.path.join(web_src, "VencordExtension")
    for root, dirs, files in os.walk(vencord_dir):
        dirs[:] = sorted(d for d in dirs if d != "monaco")
        for f in sorted(files):
            fp = os.path.join(root, f)
            rel = os.path.relpath(fp, vencord_dir).replace("\\", "/")
            if rel.startswith("vendor/monaco"):
                continue
            add_file(files_map, f"vencord-ext/{rel}", fp)

    # 3. dbc-assets/*
    assets_dir = os.path.join(web_src, "assets")
    for name in ("dbc-mobile.css", "dbc-web-bridge.js", "icon.png", "pwa-manifest.json"):
        fp = os.path.join(assets_dir, name)
        if os.path.isfile(fp):
            add_file(files_map, f"dbc-assets/{name}", fp)

    # 4. core dbc-editor/* (skip unused hljs language chunks & help images/videos)
    editor_dir = os.path.join(assets_dir, "editor")
    for root, dirs, files in os.walk(editor_dir):
        dirs.sort()
        for f in sorted(files):
            fp = os.path.join(root, f)
            rel = os.path.relpath(fp, editor_dir).replace("\\", "/")
            keep = (
                rel in EDITOR_ALLOW_FILES
                or any(rel.startswith(p) for p in EDITOR_ALLOW_DIRS)
                or (rel.startswith("assets/index-") and (rel.endswith(".js") or rel.endswith(".css")))
            )
            if keep:
                add_file(files_map, f"dbc-editor/{rel}", fp)

    # Guard against accidental secret-scanner false positive
    for k, entry in files_map.items():
        if k.endswith(".js"):
            decoded = base64.b64decode(entry["b64"]).decode("utf-8", errors="ignore")
            assert not re.search(r"AIza[0-9A-Za-z_-]{35}", decoded), f"Raw AIza literal in {k}"

    payload = {"files": files_map}
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    with open(OUT_PATH, "w", encoding="utf-8", newline="\n") as out:
        json.dump(payload, out, separators=(",", ":"))

    total_raw = sum(len(base64.b64decode(v["b64"])) for v in files_map.values())
    print(f"Wrote {OUT_PATH}: entries={len(files_map)} raw_bytes={total_raw} json_bytes={os.path.getsize(OUT_PATH)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
