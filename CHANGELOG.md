# Changelog

All notable changes to MangaSync will be documented in this file.

## [v1.1.2] - 2026-09-11

### Changed
- **Version Bump & Documentation**: Added comprehensive `CHANGELOG.md` and synchronized release packaging across the Kindle manga plugin ecosystem (`MaxOutUI`, `Suwayomi+`, `MangaSync`).
- **Sync Reliability**: Verified sidecar resolution and deferred sync queues under KOReader.

## [v1.1.1] - 2026-09-11

### Fixed
- **DocSettings Sidecars**: Resolved KOReader sidecar paths correctly across storage configurations.
- **Index ID Fallback**: Added fallback to `.manga_index.lua` for resolving manga and chapter IDs when direct sidecars are unavailable.
- **Deferred Sync on Exit**: Moved close-sync operations off the main UI thread to prevent document exit stutter.
- **Retry Queue Hardening**: Ensured `always_track` and `manga_id` are persisted across failed sync retries.
- **Dual-Sync Prevention**: Avoided redundant sync calls when Suwayomi+ handles the reader return event.

## [v1.1.0] - 2026-09-11

### Added
- **Tracker Integration**: Added support for updating external trackers (MyAnimeList, AniList, Kitsu, MangaUpdates) via Suwayomi's `trackProgress` API.
- **Live Test Suite**: Added end-to-end test suite (`tests/live_sync_test.py`) for validating chapter sync against live Suwayomi Docker containers.

### Fixed
- **GraphQL Mutation**: Corrected singular `chapter` GraphQL mutation in the direct HTTP fallback path.
- **Page Number Offset**: Adjusted KOReader 1-based page indices to Suwayomi 0-based page indices.

## [v1.0.0] - 2026-09-11

### Added
- **Initial Release**: Background sync of downloaded manga CBZ reading progress from KOReader to Suwayomi.
- **Event Hooks**: Listens to KOReader `onCloseDocument` and `onPageUpdate` events.
- **Persistent Retry Queue**: Bounded 200-item queue ensuring no read progress is lost when offline or disconnecting.
- **WakeupGuard Integration**: Handles network latency and reconnect delays gracefully on e-ink wake.
- **Zero-Crash Design**: Completely non-blocking and safe when Suwayomi or network connections are unreachable.
