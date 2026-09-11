# MangaSync for KOReader

Syncs **downloaded** Suwayomi+ chapter CBZs back to [Suwayomi Server](https://github.com/Suwayomi/Suwayomi-Server), including **trackers**.

Companion to [Suwayomi+](https://github.com/just-for-death/suwayomiplus) and [MaxOutUI](https://github.com/just-for-death/maxoutui).

Author: [just-for-death](https://github.com/just-for-death) · Version **1.1.1**

---

## Do you need this?

| How you read | Sync |
|---|---|
| Stream / open via Suwayomi+ | Built into Suwayomi+ already |
| Open downloaded CBZ from file browser / MaxOutUI | **MangaSync** (this plugin) |

Keep MangaSync if you often open CBZs outside Suwayomi+. When Suwayomi+ has a live reader-return context for the CBZ, MangaSync skips close-sync so progress is not dual-posted.

---

## How each chapter is synced

```text
Close CBZ
   │
   ├─1─ updateChapter(chapterId, { isRead, lastPageRead })
   │      → Suwayomi DB (this chapter only)
   │
   └─2─ trackProgress(mangaId)
          → Suwayomi pushes lastChapterRead to every
            bound + logged-in tracker for that manga:
              MyAnimeList, AniList, Kitsu, MangaUpdates, …
```

1. **Per chapter** — one GraphQL `updateChapter` for that CBZ’s `suwayomi_chapter_id` from the KOReader `.sdr` sidecar (or `.manga_index.lua` fallback).
2. **Trackers** — one `trackProgress(mangaId)` using `suwayomi_manga_id`. Suwayomi computes the highest read chapter and updates MAL / AniList / Kitsu / MangaUpdates (and any other bound tracker). MangaSync does **not** talk to AniList/MAL directly.

Network work runs shortly after close returns (deferred), so the reader UI is not blocked. Failed syncs stay queued and retry on the next `ReaderReady` or via the menu.

**Library “Updates”** (new chapters from sources) stay in Suwayomi+ / the server — MangaSync does not fetch source updates.

---

## Book layout (from Suwayomi+)

```text
Books/Manga/<Source>/<Manga Title>/
  Ch. 001 - Name [id-…].cbz
  Ch. 001 - Name [id-…].sdr/metadata.cbz.lua
  .manga_index.lua
```

Sidecar path follows KOReader `DocSettings` (`file.sdr/…`, not `file.cbz.sdr`). Legacy `file.cbz.sdr/metadata.cbz.lua` is still read if present. Sidecar should include `suwayomi_chapter_id` and `suwayomi_manga_id`; if those are missing, MangaSync looks up IDs from the sibling `.manga_index.lua`.

---

## Install

```text
<koreader-root>/plugins/mangasync.koplugin/
```

Uses Suwayomi+ settings (`server_url`, download dir). Restart KOReader.

Menu → **MangaSync**:
- Check trackers on server
- Retry failed syncs
- Clear queue

---

## Live test (against your Docker Suwayomi)

```bash
python3 tests/live_sync_test.py http://127.0.0.1:4567
```

Verifies chapter mutation shape, logged-in trackers, and `trackProgress` for bound manga.
