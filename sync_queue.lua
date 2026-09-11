-- Boundary: MangaSync persistent sync queue.
--
-- Responsibility: store failed chapter-progress sync attempts across sessions
-- so they can be retried on the next successful server connection.
-- Owned state: the queue file on disk; in-memory state is never cached between
-- calls so that concurrent writes (if any) always see the latest queue.
-- Dependencies: KOReader DataStorage for the settings directory path.
-- External data: queue entries are validated and bounds-checked on every read.

local DataStorage = require("datastorage")

local SyncQueue = {}

local QUEUE_FILE = DataStorage:getSettingsDir() .. "/mangasync_queue.lua"
local MAX_QUEUE_SIZE = 200      -- oldest entries dropped when limit is exceeded
local MAX_FILE_BYTES = 64 * 1024

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function readQueue()
    local f = io.open(QUEUE_FILE, "r")
    if not f then
        return {}
    end
    local content = f:read(MAX_FILE_BYTES + 1) or ""
    f:close()
    if #content > MAX_FILE_BYTES then
        -- File is suspiciously large; discard to avoid loading bad state.
        return {}
    end
    local loader = loadstring(content)
    if not loader then
        return {}
    end
    setfenv(loader, {})
    local ok, result = pcall(loader)
    if ok and type(result) == "table" then
        return result
    end
    return {}
end

local function writeQueue(queue)
    local lines = { "return {" }
    for _, entry in ipairs(queue) do
        local chapter_id = tostring(entry.chapter_id or "")
        if chapter_id ~= "" then
            lines[#lines + 1] = string.format(
                "  { chapter_id = %q, last_page = %d, is_read = %s, timestamp = %d },",
                chapter_id,
                math.floor(tonumber(entry.last_page) or 0),
                entry.is_read == true and "true" or "false",
                math.floor(tonumber(entry.timestamp) or 0)
            )
        end
    end
    lines[#lines + 1] = "}"

    -- Atomic write via a temp file + rename so a crash never leaves a partial queue.
    local tmp_path = QUEUE_FILE .. ".tmp"
    local f = io.open(tmp_path, "w")
    if not f then
        return false
    end
    f:write(table.concat(lines, "\n"))
    f:write("\n")
    f:close()
    return os.rename(tmp_path, QUEUE_FILE) ~= nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Add or update an entry for chapter_id.  If an entry for the same chapter
-- already exists it is replaced (progress update), otherwise it is appended.
-- Oldest entries are dropped when the queue exceeds MAX_QUEUE_SIZE.
--
-- entry : { chapter_id, last_page, is_read, timestamp }
-- Returns true if the queue was persisted successfully.
function SyncQueue.enqueue(entry)
    if type(entry) ~= "table" then
        return false
    end
    local chapter_id = tostring(entry.chapter_id or "")
    if chapter_id == "" then
        return false
    end

    local queue = readQueue()

    -- Replace an existing entry for the same chapter (idempotent upsert).
    for i, existing in ipairs(queue) do
        if tostring(existing.chapter_id or "") == chapter_id then
            queue[i] = entry
            return writeQueue(queue)
        end
    end

    -- Drop oldest when the cap is reached to bound disk usage.
    if #queue >= MAX_QUEUE_SIZE then
        table.remove(queue, 1)
    end

    table.insert(queue, entry)
    return writeQueue(queue)
end

-- Return all queued entries.  Callers should treat the returned table as
-- read-only and use replaceAll() to commit any changes.
function SyncQueue.getAll()
    return readQueue()
end

-- Overwrite the queue with a new list (e.g. after removing retried entries).
function SyncQueue.replaceAll(queue)
    return writeQueue(type(queue) == "table" and queue or {})
end

-- Return the number of queued entries without loading the full table.
function SyncQueue.getCount()
    return #readQueue()
end

-- Remove all entries (e.g. on a full successful flush).
function SyncQueue.clear()
    return writeQueue({})
end

return SyncQueue
