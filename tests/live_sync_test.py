#!/usr/bin/env python3
"""Live MangaSync integration tests against local Suwayomi Docker (:4567).

Tests:
  1. GraphQL reachable
  2. Logged-in trackers (MAL / AniList / Kitsu / MangaUpdates)
  3. Per-chapter updateChapter (page progress) works
  4. Old broken `chapters` plural mutation FAILS (documents prior bug)
  5. Fixed `chapter` singular mutation SUCCEEDS
  6. trackProgress on One Piece (manga 120) returns bound tracker records
  7. End-to-end: chapter sync then trackProgress (no new chapter marked read)
"""

from __future__ import annotations

import json
import sys
import urllib.request

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:4567"
ENDPOINT = BASE.rstrip("/") + "/api/graphql"

passed = 0
failed = 0


def gql(query: str) -> dict:
    data = json.dumps({"query": query}).encode()
    req = urllib.request.Request(
        ENDPOINT,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode())


def check(name: str, cond: bool, detail: str = "") -> None:
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS: {name}" + (f" — {detail}" if detail else ""))
    else:
        failed += 1
        print(f"  FAIL: {name}" + (f" — {detail}" if detail else ""))


print(f"== MangaSync live tests vs {BASE} ==\n")

# 1
print("-- connectivity --")
r = gql("{ __typename }")
check("server reachable", r.get("data", {}).get("__typename") == "Query")

# 2
print("\n-- trackers --")
r = gql("{ trackers { nodes { id name isLoggedIn isTokenExpired } } }")
nodes = r["data"]["trackers"]["nodes"]
logged = {t["name"]: t for t in nodes if t["isLoggedIn"]}
for name in ("MyAnimeList", "AniList", "Kitsu", "MangaUpdates"):
    check(f"{name} logged in", name in logged, f"id={logged[name]['id']}" if name in logged else "missing")

# 3 / 4 / 5 — chapter mutation shape
print("\n-- chapter sync mutation --")
CHAPTER_ID = 4460  # Spider-Man #1 (safe toy chapter)

# Restore baseline
gql(
    f"mutation {{ updateChapter(input: {{ id: {CHAPTER_ID}, patch: {{ isRead: false, lastPageRead: 0 }} }}) {{ chapter {{ id }} }} }}"
)

broken = gql(
    f'mutation {{ updateChapter(input: {{ id: {CHAPTER_ID}, patch: {{ isRead: false, lastPageRead: 2 }} }}) {{ chapters {{ isRead lastPageRead }} }} }}'
)
check(
    "old mangasync `chapters` plural is rejected",
    "errors" in broken,
    broken.get("errors", [{}])[0].get("message", "")[:80],
)

fixed = gql(
    f"mutation {{ updateChapter(input: {{ id: {CHAPTER_ID}, patch: {{ isRead: false, lastPageRead: 4 }} }}) {{ chapter {{ id isRead lastPageRead }} }} }}"
)
ch = fixed.get("data", {}).get("updateChapter", {}).get("chapter") or {}
check("fixed `chapter` singular sync works", ch.get("lastPageRead") == 4, str(ch))

# Restore
gql(
    f"mutation {{ updateChapter(input: {{ id: {CHAPTER_ID}, patch: {{ isRead: false, lastPageRead: 0 }} }}) {{ chapter {{ id }} }} }}"
)

# 6 / 7 — trackers on One Piece (already bound)
print("\n-- tracker push (One Piece mangaId=120) --")
# Touch already-read ch 1182 page only (does not advance lastChapterRead past 1183)
TOUCH_ID = 15235
before = gql(
    "{ trackRecords(condition: { mangaId: 120 }) { nodes { id trackerId lastChapterRead } } }"
)
before_map = {
    n["trackerId"]: n["lastChapterRead"]
    for n in before["data"]["trackRecords"]["nodes"]
}

gql(
    f"mutation {{ updateChapter(input: {{ id: {TOUCH_ID}, patch: {{ isRead: true, lastPageRead: 5 }} }}) {{ chapter {{ id isRead lastPageRead }} }} }}"
)
tp = gql(
    "mutation { trackProgress(input: { mangaId: 120 }) { trackRecords { id trackerId lastChapterRead } } }"
)
records = tp.get("data", {}).get("trackProgress", {}).get("trackRecords") or []
check("trackProgress returns bound records", len(records) >= 3, f"got {len(records)}")

names = {1: "MAL", 2: "AniList", 3: "Kitsu", 7: "MangaUpdates"}
for rec in records:
    tid = rec["trackerId"]
    check(
        f"tracker {names.get(tid, tid)} present in trackProgress",
        tid in before_map,
        f"lastChapterRead={rec.get('lastChapterRead')}",
    )

after = gql(
    "{ trackRecords(condition: { mangaId: 120 }) { nodes { trackerId lastChapterRead } } }"
)
after_map = {
    n["trackerId"]: n["lastChapterRead"]
    for n in after["data"]["trackRecords"]["nodes"]
}
# Page-only touch on already-read 1182 should not increase beyond previous max
for tid, before_val in before_map.items():
    after_val = after_map.get(tid, before_val)
    check(
        f"tracker {names.get(tid, tid)} did not regress",
        after_val >= before_val,
        f"{before_val} → {after_val}",
    )

# Restore page field on touch chapter (keep isRead true as it was)
gql(
    f"mutation {{ updateChapter(input: {{ id: {TOUCH_ID}, patch: {{ isRead: true, lastPageRead: 0 }} }}) {{ chapter {{ id }} }} }}"
)

print("\n" + "=" * 50)
print(f"Results: {passed} passed, {failed} failed")
print("=" * 50)
sys.exit(1 if failed else 0)
