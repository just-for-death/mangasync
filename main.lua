-- Boundary: MangaSync KOReader plugin entry point.
--
-- Responsibility: hook into KOReader's reader lifecycle to detect when a
-- suwayomiplus-downloaded manga CBZ is closed, then sync reading progress
-- back to the Suwayomi server.  Completely optional — the plugin silently does
-- nothing when suwayomiplus is absent or unconfigured.
--
-- Event hooks:
--   onReaderReady        — capture document path; retry any queued syncs
--   onPageUpdate(pageno) — track current page number
--   onCloseDocument      — sync progress to Suwayomi; queue on failure
--   addToMainMenu        — add a "MangaSync" entry in the reader/FM menu
--
-- Dependencies: sync_worker, sync_queue (local); suwayomi/settings (optional).

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")

local SyncWorker = require("sync_worker")
local SyncQueue  = require("sync_queue")

-- ---------------------------------------------------------------------------
-- Plugin class
-- ---------------------------------------------------------------------------

local MangaSync = WidgetContainer:extend{
    name        = "mangasync",
    is_doc_only = false,

    -- Reader state, reset on each document open.
    _current_doc_path = nil,
    _current_page     = 0,
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local MAX_SDR_BYTES = 64 * 1024

-- Lazily load suwayomiplus credentials and download directory.
-- Returns (credentials, download_directory) or (nil, nil) when unavailable.
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

-- Read the sdr sidecar that suwayomiplus/manga_metadata.lua writes alongside
-- each downloaded CBZ.  Returns the parsed Lua table or nil.
local function readSdrMetadata(cbz_path)
    -- Convention: /path/to/Manga/Ch001.cbz → Ch001.cbz.sdr/metadata.cbz.lua
    local sdr_path = cbz_path .. ".sdr/metadata.cbz.lua"
    local f = io.open(sdr_path, "r")
    if not f then
        return nil
    end
    local content = f:read(MAX_SDR_BYTES + 1) or ""
    f:close()
    if #content > MAX_SDR_BYTES then
        return nil
    end
    local loader = loadstring(content)
    if not loader then
        return nil
    end
    setfenv(loader, {})
    local ok, result = pcall(loader)
    if ok and type(result) == "table" then
        return result
    end
    return nil
end

-- Return true when cbz_path is inside the suwayomi download directory.
local function isUnderDownloadDir(cbz_path, download_dir)
    if not cbz_path or not download_dir or download_dir == "" then
        return false
    end
    -- Normalise: strip trailing slashes from the download dir prefix.
    local prefix = download_dir:gsub("/*$", "")
    if #prefix == 0 then
        return false
    end
    -- The path must start with prefix followed by a directory separator.
    local next_char = cbz_path:sub(#prefix + 1, #prefix + 1)
    return cbz_path:sub(1, #prefix) == prefix
        and (next_char == "/" or cbz_path == prefix)
end

-- Resolve the current document path from self.ui with multiple fallbacks so
-- the plugin is resilient to KOReader version differences.
function MangaSync:_resolveDocumentPath()
    local ui = self.ui
    if not ui then
        return self._current_doc_path
    end
    local path = ui.document_path
        or ui.document_pathname
    if not path then
        local doc = ui.document
        if type(doc) == "table" then
            path = doc.file or doc.filename or doc.path
        end
    end
    return path or self._current_doc_path
end

-- Return true when KOReader considers the current document finished (100 % or
-- explicitly marked complete in doc_settings).
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

-- Retry every queued sync that previously failed.  Removes successful entries
-- and re-persists the remainder.  Returns the number of successfully retried
-- entries.
function MangaSync:_retryQueuedSyncs(credentials)
    local entries = SyncQueue.getAll()
    if #entries == 0 then
        return 0
    end

    local remaining = {}
    local count = 0
    for _, entry in ipairs(entries) do
        local result = SyncWorker.syncChapter(
            credentials,
            entry.chapter_id,
            entry.is_read,
            entry.last_page
        )
        if result and result.ok then
            count = count + 1
        else
            table.insert(remaining, entry)
        end
    end
    SyncQueue.replaceAll(remaining)
    return count
end

-- ---------------------------------------------------------------------------
-- KOReader lifecycle hooks
-- ---------------------------------------------------------------------------

function MangaSync:init()
    -- Nothing to initialise eagerly; all work is deferred to events.
end

-- onReaderReady fires after the reader has finished setting up the document.
-- We use it to capture the path and attempt any pending retries.
function MangaSync:onReaderReady()
    self._current_page = 0

    -- Capture path early so onCloseDocument can always find it.
    local path = self:_resolveDocumentPath()
    if path then
        self._current_doc_path = path
    end

    -- Opportunistically retry queued syncs now that we have a network context.
    local credentials, _ = loadSuwayomiConfig()
    if not credentials or not credentials.server_url or credentials.server_url == "" then
        return
    end
    pcall(function()
        self:_retryQueuedSyncs(credentials)
    end)
end

-- Track the current page so we can report it to Suwayomi on close.
function MangaSync:onPageUpdate(page_no)
    self._current_page = tonumber(page_no) or self._current_page
end

-- onCloseDocument fires just before the reader tears down the document.
function MangaSync:onCloseDocument()
    local doc_path = self:_resolveDocumentPath()

    -- Only act on CBZ files.
    if not doc_path or not doc_path:match("%.cbz$") then
        self._current_doc_path = nil
        self._current_page = 0
        return
    end

    local credentials, download_dir = loadSuwayomiConfig()

    -- If suwayomiplus is not configured, or the file is not under the suwayomi
    -- download directory, do nothing.
    if not credentials
        or not download_dir
        or not isUnderDownloadDir(doc_path, download_dir)
    then
        self._current_doc_path = nil
        self._current_page = 0
        return
    end

    -- Read the sdr sidecar that manga_metadata.lua wrote at download time to
    -- recover the Suwayomi chapter ID without a server round-trip.
    local meta = readSdrMetadata(doc_path)
    local chapter_id = meta and tostring(meta.suwayomi_chapter_id or "")
    if not chapter_id or chapter_id == "" then
        -- Chapter was downloaded before the metadata feature; nothing to sync.
        self._current_doc_path = nil
        self._current_page = 0
        return
    end

    local is_read    = self:_isDocumentFinished()
    local last_page  = self._current_page or 0

    -- Sync progress; on any failure, queue for later retry.
    local synced = false
    pcall(function()
        local result = SyncWorker.syncChapter(credentials, chapter_id, is_read, last_page)
        if result and result.ok then
            synced = true
        end
    end)

    if synced then
        -- Brief toast on success (non-blocking).
        pcall(function()
            UIManager:show(InfoMessage:new{
                text    = "Synced to Suwayomi \xe2\x9c\x93",
                timeout = 2,
            })
        end)
    else
        -- Queue for the next time the user opens a chapter.
        pcall(function()
            SyncQueue.enqueue({
                chapter_id = chapter_id,
                last_page  = last_page,
                is_read    = is_read,
                timestamp  = os.time(),
            })
        end)
        logger.warn("MangaSync: sync failed for chapter", chapter_id, "— queued for retry.")
    end

    -- Reset reader state.
    self._current_doc_path = nil
    self._current_page = 0
end

-- ---------------------------------------------------------------------------
-- File manager / reader menu registration
-- ---------------------------------------------------------------------------

function MangaSync:addToMainMenu(menu_items)
    menu_items.mangasync = {
        text = "MangaSync",
        sub_item_table = {
            {
                text = "About MangaSync",
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = table.concat({
                            "MangaSync automatically syncs your reading",
                            "progress back to your Suwayomi server whenever",
                            "you close a downloaded manga chapter.",
                            "",
                            "Requires suwayomiplus to be installed and",
                            "configured with a valid server URL.",
                        }, "\n"),
                    })
                end,
            },
            {
                text = "Retry failed syncs",
                callback = function()
                    local queued = SyncQueue.getCount()
                    if queued == 0 then
                        UIManager:show(InfoMessage:new{
                            text    = "MangaSync: No pending syncs.",
                            timeout = 3,
                        })
                        return
                    end

                    local credentials, _ = loadSuwayomiConfig()
                    if not credentials
                        or not credentials.server_url
                        or credentials.server_url == ""
                    then
                        UIManager:show(InfoMessage:new{
                            text    = "MangaSync: No Suwayomi server configured.",
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
                        msg = string.format("MangaSync: Synced %d chapter(s).", count)
                    elseif count > 0 then
                        msg = string.format(
                            "MangaSync: Synced %d chapter(s); %d still pending.",
                            count, remaining
                        )
                    else
                        msg = string.format(
                            "MangaSync: Could not sync %d chapter(s) — will retry later.",
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
                        text    = string.format("MangaSync: Cleared %d queued sync(s).", count),
                        timeout = 3,
                    })
                end,
            },
        },
    }
end

return MangaSync
