-- Boundary: MangaSync persistent sync queue.
--
-- Responsibility: store failed chapter/tracker sync attempts across sessions.
-- Owned state: the queue file on disk.
-- Dependencies: KOReader DataStorage for the settings directory path.

local DataStorage = require("datastorage")

local SyncQueue = {}

local QUEUE_FILE = DataStorage:getSettingsDir() .. "/mangasync_queue.lua"
local MAX_QUEUE_SIZE = 200
local MAX_FILE_BYTES = 64 * 1024

local function loadSandbox(content)
    -- LuaJIT (KOReader): loadstring + setfenv
    -- Lua 5.2+: load(..., env)
    local loader
    if rawget(_G, "loadstring") then
        loader = loadstring(content)
        if loader and rawget(_G, "setfenv") then
            setfenv(loader, {})
        end
    else
        loader = load(content, "mangasync_queue", "t", {})
    end
    return loader
end

local function readQueue()
    local f = io.open(QUEUE_FILE, "r")
    if not f then
        return {}
    end
    local content = f:read(MAX_FILE_BYTES + 1) or ""
    f:close()
    if #content > MAX_FILE_BYTES then
        return {}
    end
    local loader = loadSandbox(content)
    if not loader then
        return {}
    end
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
                "  { chapter_id = %q, manga_id = %q, last_page = %d, is_read = %s, sync_trackers_always = %s, stage = %q, timestamp = %d },",
                chapter_id,
                tostring(entry.manga_id or ""),
                math.floor(tonumber(entry.last_page) or 0),
                entry.is_read == true and "true" or "false",
                entry.sync_trackers_always == true and "true" or "false",
                tostring(entry.stage or "chapter"),
                math.floor(tonumber(entry.timestamp) or 0)
            )
        end
    end
    lines[#lines + 1] = "}"

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

-- entry : { chapter_id, manga_id?, last_page, is_read, sync_trackers_always?, stage?, timestamp }
function SyncQueue.enqueue(entry)
    if type(entry) ~= "table" then
        return false
    end
    local chapter_id = tostring(entry.chapter_id or "")
    if chapter_id == "" then
        return false
    end

    -- Normalize so retry always sees an explicit boolean.
    entry.sync_trackers_always = entry.sync_trackers_always == true

    local queue = readQueue()
    for i, existing in ipairs(queue) do
        if tostring(existing.chapter_id or "") == chapter_id then
            queue[i] = entry
            return writeQueue(queue)
        end
    end

    if #queue >= MAX_QUEUE_SIZE then
        table.remove(queue, 1)
    end

    table.insert(queue, entry)
    return writeQueue(queue)
end

function SyncQueue.getAll()
    return readQueue()
end

function SyncQueue.replaceAll(queue)
    return writeQueue(type(queue) == "table" and queue or {})
end

function SyncQueue.getCount()
    return #readQueue()
end

function SyncQueue.clear()
    return writeQueue({})
end

return SyncQueue
