# MangaSync for KOReader

Sync reading progress from **downloaded** Suwayomi+ chapter CBZs back to your [Suwayomi Server](https://github.com/Suwayomi/Suwayomi-Server).

Companion to [Suwayomi+](https://github.com/just-for-death/suwayomiplus) and [MaxOutUI](https://github.com/just-for-death/maxoutui).

Author: [just-for-death](https://github.com/just-for-death)

---

## Why this exists

Suwayomi+ already syncs **online stream** progress. When you download chapters as CBZs and open them in KOReader’s native reader, MangaSync closes the gap:

1. You finish / leave a chapter CBZ
2. MangaSync reads `suwayomi_chapter_id` from the `.sdr` sidecar Suwayomi+ wrote
3. It calls Suwayomi `updateChapter` (progress / read)
4. Failures go into a persistent retry queue (Tailscale / sleep friendly)

---

## Book model (must match Suwayomi+)

```text
Books/Manga/<Source>/<Manga Title>/
  Ch. 001 - Name [id-…].cbz
  Ch. 001 - Name [id-…].cbz.sdr/metadata.cbz.lua   ← MangaSync reads this
```

Sidecar fields used:

- `suwayomi_chapter_id`
- `suwayomi_manga_id`
- `doc_props.series` / `title` / `series_index` (display only)

Only files under the Suwayomi+ download directory are synced.

---

## Install

```text
<koreader-root>/plugins/mangasync.koplugin/
```

Needs Suwayomi+ configured (same server credentials / download dir). Restart KOReader.

Menu: **MangaSync** → About / Retry queued / Clear queue.

---

## Behavior

| Event | Action |
|---|---|
| `onReaderReady` | Remember path; retry queue |
| `onPageUpdate` | Track page |
| `onCloseDocument` | Sync or enqueue |

Silent no-op if Suwayomi+ / credentials / sidecar are missing. Never crashes the reader.
