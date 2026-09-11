-- Boundary: MangaSync sync worker.
--
-- Responsibility: sync one chapter's read progress to Suwayomi, then push
-- tracker progress (MAL / AniList / Kitsu / MangaUpdates) for that manga.
-- Prefers suwayomiplus API when available; otherwise uses direct GraphQL.
-- Owned state: none.

local SyncWorker = {}

local TRACKER_NAMES = {
    [1] = "MyAnimeList",
    [2] = "AniList",
    [3] = "Kitsu",
    [4] = "Shikimori",
    [5] = "Bangumi",
    [7] = "MangaUpdates",
}

function SyncWorker.trackerName(tracker_id)
    return TRACKER_NAMES[tonumber(tracker_id)] or ("Tracker " .. tostring(tracker_id))
end

local function encodeBasicAuth(username, password)
    username = tostring(username or "")
    password = tostring(password or "")
    if username == "" then
        return nil
    end
    local ok_mime, mime = pcall(require, "mime")
    if ok_mime and mime and mime.b64 then
        return "Basic " .. mime.b64(username .. ":" .. password)
    end
    -- Pure-Lua base64 fallback (minimal alphabet).
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local data = username .. ":" .. password
    return "Basic " .. ((data:gsub(".", function(x)
        local r, byte = "", x:byte()
        for i = 8, 1, -1 do
            r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0")
        end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do
            c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
        end
        return b:sub(c + 1, c + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

function SyncWorker._postGraphQL(credentials, body)
    local ok_http, http = pcall(require, "socket.http")
    if not ok_http or not http then
        return { ok = false, error = "socket.http unavailable." }
    end
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not ok_ltn12 or not ltn12 then
        return { ok = false, error = "ltn12 unavailable." }
    end

    local base_url = tostring(credentials.server_url or ""):gsub("/*$", "")
    if base_url == "" then
        return { ok = false, error = "No Suwayomi server URL configured." }
    end
    local endpoint = base_url .. "/api/graphql"
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#body),
    }
    local auth = encodeBasicAuth(credentials.username, credentials.password)
    if auth then
        headers["Authorization"] = auth
    end

    local response_chunks = {}
    local request_ok, http_code_or_err = pcall(function()
        return http.request{
            url = endpoint,
            method = "POST",
            headers = headers,
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(response_chunks),
        }
    end)
    if not request_ok then
        return { ok = false, error = "HTTP request failed: " .. tostring(http_code_or_err) }
    end

    local code = tonumber(http_code_or_err)
    local body_text = table.concat(response_chunks)
    if not (code and code >= 200 and code < 300) then
        return {
            ok = false,
            error = "Server returned HTTP " .. tostring(http_code_or_err or "unknown"),
            body = body_text,
        }
    end

    local ok_json, json = pcall(require, "dkjson")
    if ok_json and json and json.decode then
        local parsed = json.decode(body_text)
        if type(parsed) == "table" and parsed.errors then
            local msg = parsed.errors[1] and parsed.errors[1].message or "GraphQL error"
            return { ok = false, error = tostring(msg), body = body_text }
        end
        return { ok = true, data = parsed and parsed.data, body = body_text }
    end
    return { ok = true, body = body_text }
end

-- Sync one chapter to Suwayomi (updateChapter).
-- last_page_read must already be 0-based (Suwayomi indexing).
function SyncWorker.syncChapter(credentials, chapter_id, is_read, last_page_read)
    if type(credentials) ~= "table" then
        return { ok = false, error = "Missing credentials." }
    end
    local cid = tostring(chapter_id or "")
    if cid == "" then
        return { ok = false, error = "Missing chapter_id." }
    end
    if not credentials.server_url or credentials.server_url == "" then
        return { ok = false, error = "No Suwayomi server URL configured." }
    end

    local ok_api, SuwayomiAPI = pcall(require, "suwayomi/api")
    if ok_api and type(SuwayomiAPI) == "table" and SuwayomiAPI.markChapterProgress then
        return SuwayomiAPI.markChapterProgress(
            credentials,
            chapter_id,
            is_read == true,
            tonumber(last_page_read) or 0
        ) or { ok = false, error = "No response from API." }
    end

    local page_num = math.max(0, math.floor(tonumber(last_page_read) or 0))
    local read_str = (is_read == true) and "true" or "false"
    local id_literal = tonumber(cid) or string.format("%q", cid)
    -- IMPORTANT: field is singular `chapter` (Suwayomi GraphQL). Older builds
    -- that used `chapters` fail validation and never sync.
    local mutation = string.format(
        [[{"query":"mutation { updateChapter(input: { id: %s, patch: { isRead: %s, lastPageRead: %d } }) { chapter { id isRead lastPageRead lastReadAt } } }"}]],
        tostring(id_literal),
        read_str,
        page_num
    )
    local result = SyncWorker._postGraphQL(credentials, mutation)
    if not result.ok then
        return result
    end
    local chapter = result.data and result.data.updateChapter and result.data.updateChapter.chapter
    return {
        ok = true,
        chapter = chapter,
        body = result.body,
    }
end

-- Push progress to all bound trackers for a manga (MAL/AniList/Kitsu/MU/…).
-- Suwayomi computes lastChapterRead from server chapter read state, then
-- updates each logged-in tracker that has a trackRecord for this manga.
function SyncWorker.syncTrackers(credentials, manga_id)
    if type(credentials) ~= "table" then
        return { ok = false, error = "Missing credentials." }
    end
    local mid = tostring(manga_id or "")
    if mid == "" then
        return { ok = false, error = "Missing manga_id." }
    end

    local ok_api, SuwayomiAPI = pcall(require, "suwayomi/api")
    if ok_api and type(SuwayomiAPI) == "table" and SuwayomiAPI.trackProgress then
        local result = SuwayomiAPI.trackProgress(credentials, manga_id)
        if result and result.ok then
            return {
                ok = true,
                records = result.records or {},
            }
        end
        return result or { ok = false, error = "No response from trackProgress." }
    end

    local id_literal = tonumber(mid) or string.format("%q", mid)
    local mutation = string.format(
        [[{"query":"mutation { trackProgress(input: { mangaId: %s }) { trackRecords { id trackerId lastChapterRead } } }"}]],
        tostring(id_literal)
    )
    local result = SyncWorker._postGraphQL(credentials, mutation)
    if not result.ok then
        return result
    end
    local records = result.data
        and result.data.trackProgress
        and result.data.trackProgress.trackRecords
        or {}
    return {
        ok = true,
        records = records,
        body = result.body,
    }
end

-- Full sync path for one finished/updated chapter:
-- 1) updateChapter on Suwayomi
-- 2) if manga_id known and chapter marked read (or always_track), trackProgress
function SyncWorker.syncChapterAndTrackers(credentials, options)
    options = options or {}
    local chapter_result = SyncWorker.syncChapter(
        credentials,
        options.chapter_id,
        options.is_read == true,
        options.last_page_read
    )
    if not chapter_result or not chapter_result.ok then
        return {
            ok = false,
            stage = "chapter",
            error = chapter_result and chapter_result.error or "Chapter sync failed.",
            chapter_result = chapter_result,
        }
    end

    local manga_id = options.manga_id
    local should_track = options.force_trackers == true
        or options.is_read == true
        or options.sync_trackers_always == true
    if not manga_id or tostring(manga_id) == "" or not should_track then
        return {
            ok = true,
            stage = "chapter",
            chapter_result = chapter_result,
            tracker_result = nil,
            trackers_skipped = true,
        }
    end

    local tracker_result = SyncWorker.syncTrackers(credentials, manga_id)
    if not tracker_result or not tracker_result.ok then
        -- Chapter already synced; queue can retry trackers separately.
        return {
            ok = false,
            stage = "trackers",
            error = tracker_result and tracker_result.error or "Tracker sync failed.",
            chapter_result = chapter_result,
            tracker_result = tracker_result,
        }
    end

    return {
        ok = true,
        stage = "trackers",
        chapter_result = chapter_result,
        tracker_result = tracker_result,
        records = tracker_result.records or {},
    }
end

function SyncWorker.fetchLoggedInTrackers(credentials)
    local query = [[{"query":"{ trackers { nodes { id name isLoggedIn isTokenExpired } } }"}]]
    local result = SyncWorker._postGraphQL(credentials, query)
    if not result.ok then
        return result
    end
    local nodes = result.data and result.data.trackers and result.data.trackers.nodes or {}
    local logged_in = {}
    for _, t in ipairs(nodes) do
        if t.isLoggedIn == true then
            logged_in[#logged_in + 1] = t
        end
    end
    return { ok = true, trackers = logged_in, all = nodes }
end

return SyncWorker
