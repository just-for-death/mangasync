-- Boundary: MangaSync KOReader plugin entry point.
--
-- Syncs downloaded Suwayomi+ chapter CBZs back to the Suwayomi server:
--   1) updateChapter (per-chapter isRead / lastPageRead)
--   2) trackProgress (MAL / AniList / Kitsu / MangaUpdates / …) when manga_id known
--
-- Event hooks: onReaderReady, onPageUpdate, onCloseDocument, addToMainMenu.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")

local SyncWorker = require("sync_worker")
local SyncQueue  = require("sync_queue")

local MangaSync = WidgetContainer:extend{
    name        = "mangasync",
    is_doc_only = false,
    _current_doc_path = nil,
    _current_page     = 0,
}

local MAX_SDR_BYTES = 64 * 1024
local MAX_INDEX_BYTES = 256 * 1024

local function loadSuwayomiConfig()
    local ok, Settings = pcall(require, "suwayomi/settings")
    if not ok or type(Settings) ~= "table" then
        return nil, nil
    end

    local creds, dir
    local ok_creds, creds_val = pcall(function()
        return Settings:load()
    end)
    if ok_creds and type(creds_val) == "table" then
        creds = creds_val
    end

    local ok_dir, dir_val = pcall(function()
        return Settings:loadDownloadDirectory()
    end)
    if ok_dir and type(dir_val) == "string" and dir_val ~= "" then
        dir = dir_val
    end

    return creds, dir
end

-- Prefer DocSettings sidecar layout (file.sdr/…); fall back to KOReader default.
local function getSidecarMetadataPath(cbz_path)
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings then
        local dir = DocSettings:getSidecarDir(cbz_path)
        local name = DocSettings.getSidecarFilename
            and DocSettings.getSidecarFilename(cbz_path)
        if dir and name then
            return dir .. "/" .. name
        end
    end
    -- KOReader default: strip last suffix → file.sdr/metadata.cbz.lua
    local base = cbz_path:match("^(.*)%.[^%.]+$") or cbz_path
    return base .. ".sdr/metadata.cbz.lua"
end

local function loadLuaTableFile(path, max_bytes)
    max_bytes = max_bytes or MAX_SDR_BYTES
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local content = f:read(max_bytes + 1) or ""
    f:close()
    if #content > max_bytes then
        return nil
    end
    local loader
    if rawget(_G, "loadstring") then
        loader = loadstring(content)
        if loader and rawget(_G, "setfenv") then
            setfenv(loader, {})
        end
    else
        loader = load(content, "mangasync_lua", "t", {})
    end
    if not loader then
        return nil
    end
    local ok, result = pcall(loader)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

local function readSdrMetadata(cbz_path)
    local preferred = getSidecarMetadataPath(cbz_path)
    local meta = loadLuaTableFile(preferred, MAX_SDR_BYTES)
    if meta then
        return meta
    end
    -- Legacy Suwayomi+ / older MangaSync: file.cbz.sdr/metadata.cbz.lua
    local legacy = cbz_path .. ".sdr/metadata.cbz.lua"
    if legacy ~= preferred then
        return loadLuaTableFile(legacy, MAX_SDR_BYTES)
    end
    return nil
end

-- Fallback when .sdr sidecars lack IDs: sibling .manga_index.lua in the manga folder.
local function lookupChapterIdsFromIndex(cbz_path)
    local manga_dir = cbz_path:match("^(.*)[/\\][^/\\]+$")
    if not manga_dir then
        return nil, nil
    end
    local index = loadLuaTableFile(manga_dir .. "/.manga_index.lua", MAX_INDEX_BYTES)
    if not index or type(index.chapters) ~= "table" then
        return nil, nil
    end

    local manga_id = tostring(index.manga_id or "")
    local basename = cbz_path:match("([^/\\]+)$") or cbz_path

    for _, ch in ipairs(index.chapters) do
        if type(ch) == "table" then
            local path = tostring(ch.path or "")
            local match = path == cbz_path
                or (path ~= "" and path:match("([^/\\]+)$") == basename)
            if match then
                local chapter_id = tostring(ch.id or "")
                if chapter_id ~= "" then
                    return chapter_id, manga_id
                end
            end
        end
    end
    return nil, nil
end

-- True when Suwayomi+ has a live reader-return context for this path
-- (opened via Suwayomi+; readsync will sync on close — skip dual sync).
local function hasSuwayomiReaderReturnContext(doc_path)
    if not doc_path or doc_path == "" then
        return false
    end
    local ok, Settings = pcall(require, "suwayomi/settings")
    if not ok or type(Settings) ~= "table" or not Settings.loadReaderReturnContexts then
        return false
    end
    local ok_ctx, contexts = pcall(function()
        return Settings:loadReaderReturnContexts()
    end)
    if not ok_ctx or type(contexts) ~= "table" then
        return false
    end
    local ctx = contexts[doc_path]
    return type(ctx) == "table" and tostring(ctx.chapter_id or "") ~= ""
end

local function isUnderDownloadDir(cbz_path, download_dir)
    if not cbz_path or not download_dir or download_dir == "" then
        return false
    end
    local prefix = download_dir:gsub("/*$", "")
    if #prefix == 0 then
        return false
    end
    local next_char = cbz_path:sub(#prefix + 1, #prefix + 1)
    return cbz_path:sub(1, #prefix) == prefix
        and (next_char == "/" or cbz_path == prefix)
end

-- KOReader pages are 1-based; Suwayomi lastPageRead is 0-based.
local function toServerPage(page)
    page = math.floor(tonumber(page) or 1)
    if page < 1 then
        page = 1
    end
    return math.max(0, page - 1)
end

function MangaSync:_resolveDocumentPath()
    local ui = self.ui
    if not ui then
        return self._current_doc_path
    end
    local path = ui.document_path or ui.document_pathname
    if not path then
        local doc = ui.document
        if type(doc) == "table" then
            path = doc.file or doc.filename or doc.path
        end
    end
    return path or self._current_doc_path
end

function MangaSync:_isDocumentFinished()
    local ui = self.ui
    if not ui then
        return false
    end
    local doc_settings = ui.doc_settings
    if not doc_settings or not doc_settings.readSetting then
        return false
    end
    local summary = doc_settings:readSetting("summary")
    local status  = type(summary) == "table" and summary.status or nil
    if status == "finished" or status == "complete" or status == "completed" then
        return true
    end
    local percent = tonumber(doc_settings:readSetting("percent_finished"))
    return percent ~= nil and percent >= 1
end

function MangaSync:_formatTrackerSummary(records)
    records = records or {}
    if #records == 0 then
        return "no bound trackers updated"
    end
    local parts = {}
    for _, rec in ipairs(records) do
        local name = SyncWorker.trackerName(rec.trackerId or rec.tracker_id)
        local ch = rec.lastChapterRead or rec.last_chapter_read or "?"
        parts[#parts + 1] = string.format("%s→%s", name, tostring(ch))
    end
    return table.concat(parts, ", ")
end

function MangaSync:_retryQueuedSyncs(credentials)
    local entries = SyncQueue.getAll()
    if #entries == 0 then
        return 0
    end

    local remaining = {}
    local count = 0
    for _, entry in ipairs(entries) do
        local result
        if entry.stage == "trackers" and entry.manga_id and entry.manga_id ~= "" then
            result = SyncWorker.syncTrackers(credentials, entry.manga_id)
            if result and result.ok then
                count = count + 1
            else
                table.insert(remaining, entry)
            end
        else
            local always_track = entry.sync_trackers_always == true
                or entry.is_read == true
            result = SyncWorker.syncChapterAndTrackers(credentials, {
                chapter_id = entry.chapter_id,
                manga_id = entry.manga_id,
                is_read = entry.is_read == true,
                last_page_read = entry.last_page,
                force_trackers = always_track,
                sync_trackers_always = entry.sync_trackers_always == true,
            })
            if result and result.ok then
                count = count + 1
            else
                entry.stage = result and result.stage or "chapter"
                table.insert(remaining, entry)
            end
        end
    end
    SyncQueue.replaceAll(remaining)
    return count
end

function MangaSync:init()
end

function MangaSync:onReaderReady()
    self._current_page = 0
    local path = self:_resolveDocumentPath()
    if path then
        self._current_doc_path = path
    end

    local credentials = loadSuwayomiConfig()
    if not credentials or not credentials.server_url or credentials.server_url == "" then
        return
    end
    pcall(function()
        self:_retryQueuedSyncs(credentials)
    end)
end

function MangaSync:onPageUpdate(page_no)
    self._current_page = tonumber(page_no) or self._current_page
end

function MangaSync:onCloseDocument()
    local doc_path = self:_resolveDocumentPath()
    if not doc_path or not doc_path:match("%.cbz$") then
        self._current_doc_path = nil
        self._current_page = 0
        return
    end

    -- Suwayomi+ reader-return / readsync owns sync for this path.
    if hasSuwayomiReaderReturnContext(doc_path) then
        self._current_doc_path = nil
        self._current_page = 0
        return
    end

    local credentials, download_dir = loadSuwayomiConfig()
    if not credentials or not credentials.server_url or credentials.server_url == "" then
        self._current_doc_path = nil
        self._current_page = 0
        return
    end

    -- Prefer download-dir gate when known; still allow sidecar-only if dir missing.
    if download_dir and not isUnderDownloadDir(doc_path, download_dir) then
        self._current_doc_path = nil
        self._current_page = 0
        return
    end

    local meta = readSdrMetadata(doc_path)
    local chapter_id = meta and tostring(meta.suwayomi_chapter_id or "") or ""
    local manga_id = meta and tostring(meta.suwayomi_manga_id or "") or ""
    if chapter_id == "" then
        local idx_chapter, idx_manga = lookupChapterIdsFromIndex(doc_path)
        if idx_chapter and idx_chapter ~= "" then
            chapter_id = idx_chapter
            if manga_id == "" and idx_manga and idx_manga ~= "" then
                manga_id = idx_manga
            end
        end
    elseif manga_id == "" then
        local _, idx_manga = lookupChapterIdsFromIndex(doc_path)
        if idx_manga and idx_manga ~= "" then
            manga_id = idx_manga
        end
    end
    if chapter_id == "" then
        self._current_doc_path = nil
        self._current_page = 0
        return
    end

    local is_read = self:_isDocumentFinished()
    local last_page = toServerPage(self._current_page or 1)
    local sync_trackers_always = manga_id ~= ""

    -- Capture fields now; run network off the close hot path.
    self._current_doc_path = nil
    self._current_page = 0

    UIManager:scheduleIn(0.01, function()
        local synced = false
        local tracker_summary = nil
        local fail_stage = "chapter"
        pcall(function()
            local result = SyncWorker.syncChapterAndTrackers(credentials, {
                chapter_id = chapter_id,
                manga_id = manga_id,
                is_read = is_read,
                last_page_read = last_page,
                -- Always attempt trackers when we know the manga; Suwayomi no-ops
                -- if nothing is bound. Helps keep MU/MAL/AL/Kitsu aligned after
                -- partial progress too.
                sync_trackers_always = sync_trackers_always,
            })
            if result and result.ok then
                synced = true
                if result.records then
                    tracker_summary = self:_formatTrackerSummary(result.records)
                elseif result.trackers_skipped then
                    tracker_summary = "trackers skipped"
                end
            else
                fail_stage = result and result.stage or "chapter"
            end
        end)

        if synced then
            pcall(function()
                local text = "Synced chapter to Suwayomi"
                if tracker_summary and tracker_summary ~= "trackers skipped" then
                    text = text .. "\nTrackers: " .. tracker_summary
                end
                UIManager:show(InfoMessage:new{
                    text = text,
                    timeout = 3,
                })
            end)
        else
            pcall(function()
                SyncQueue.enqueue({
                    chapter_id = chapter_id,
                    manga_id = manga_id,
                    last_page = last_page,
                    is_read = is_read,
                    sync_trackers_always = sync_trackers_always,
                    stage = fail_stage,
                    timestamp = os.time(),
                })
            end)
            logger.warn("MangaSync: sync failed for chapter", chapter_id, "stage", fail_stage)
        end
    end)
end

function MangaSync:addToMainMenu(menu_items)
    menu_items.mangasync = {
        text = "MangaSync",
        sub_item_table = {
            {
                text = "About MangaSync",
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = table.concat({
                            "MangaSync syncs downloaded chapter CBZs:",
                            "",
                            "1. Per chapter → Suwayomi updateChapter",
                            "   (isRead + lastPageRead)",
                            "2. Then trackProgress(mangaId) so bound",
                            "   MAL / AniList / Kitsu / MangaUpdates",
                            "   get the latest chapter number.",
                            "",
                            "Needs Suwayomi+ metadata sidecars on CBZs",
                            "(or .manga_index.lua in the manga folder).",
                            "Library 'Updates' fetching stays in Suwayomi+.",
                        }, "\n"),
                    })
                end,
            },
            {
                text = "Check trackers on server",
                callback = function()
                    local credentials = loadSuwayomiConfig()
                    if not credentials or not credentials.server_url or credentials.server_url == "" then
                        UIManager:show(InfoMessage:new{
                            text = "MangaSync: No Suwayomi server configured.",
                            timeout = 3,
                        })
                        return
                    end
                    local result = SyncWorker.fetchLoggedInTrackers(credentials)
                    if not result or not result.ok then
                        UIManager:show(InfoMessage:new{
                            text = "MangaSync: Could not reach trackers — "
                                .. tostring(result and result.error or "error"),
                            timeout = 4,
                        })
                        return
                    end
                    local lines = { "Logged-in trackers:" }
                    if #(result.trackers or {}) == 0 then
                        lines[#lines + 1] = "(none)"
                    else
                        for _, t in ipairs(result.trackers) do
                            local expired = t.isTokenExpired and " [token expired]" or ""
                            lines[#lines + 1] = string.format("• %s%s", t.name or "?", expired)
                        end
                    end
                    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
                end,
            },
            {
                text = "Retry failed syncs",
                callback = function()
                    local queued = SyncQueue.getCount()
                    if queued == 0 then
                        UIManager:show(InfoMessage:new{
                            text = "MangaSync: No pending syncs.",
                            timeout = 3,
                        })
                        return
                    end

                    local credentials = loadSuwayomiConfig()
                    if not credentials or not credentials.server_url or credentials.server_url == "" then
                        UIManager:show(InfoMessage:new{
                            text = "MangaSync: No Suwayomi server configured.",
                            timeout = 3,
                        })
                        return
                    end

                    local count = 0
                    pcall(function()
                        count = self:_retryQueuedSyncs(credentials)
                    end)

                    local remaining = SyncQueue.getCount()
                    local msg
                    if count > 0 and remaining == 0 then
                        msg = string.format("MangaSync: Synced %d item(s).", count)
                    elseif count > 0 then
                        msg = string.format(
                            "MangaSync: Synced %d; %d still pending.",
                            count, remaining
                        )
                    else
                        msg = string.format(
                            "MangaSync: Could not sync %d item(s).",
                            remaining
                        )
                    end
                    UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
                end,
            },
            {
                text = "Clear sync queue",
                callback = function()
                    local count = SyncQueue.getCount()
                    SyncQueue.clear()
                    UIManager:show(InfoMessage:new{
                        text = string.format("MangaSync: Cleared %d queued sync(s).", count),
                        timeout = 3,
                    })
                end,
            },
        },
    }
end

return MangaSync
