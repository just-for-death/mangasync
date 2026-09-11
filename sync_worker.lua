-- Boundary: MangaSync sync worker.
--
-- Responsibility: make a single chapter-progress API call to the Suwayomi
-- server.  Prefers the suwayomiplus API facade (which handles auth headers,
-- GraphQL encoding, and response parsing) and falls back to a direct HTTP POST
-- when the facade is not available so the plugin remains usable without
-- suwayomiplus installed.
-- Owned state: none.
-- Dependencies: suwayomi/api (optional); socket.http + ltn12 for fallback.
-- External data: credentials and chapter IDs are validated before any network
-- call; all errors are returned as { ok = false, error = "..." } tables.

local SyncWorker = {}

-- ---------------------------------------------------------------------------
-- Primary path: suwayomiplus API facade
-- ---------------------------------------------------------------------------

-- Sync reading progress for a single chapter.
--
-- credentials   : { server_url, username, password, auth_method }
-- chapter_id    : Suwayomi chapter ID (string or number)
-- is_read       : boolean — true when the chapter has been finished
-- last_page_read: 0-based page index of the last viewed page
--
-- Returns { ok = true, chapter = ... } on success or { ok = false, error = "..." }.
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

    -- Try the suwayomiplus API facade first.
    local ok_api, SuwayomiAPI = pcall(require, "suwayomi/api")
    if ok_api and type(SuwayomiAPI) == "table" and SuwayomiAPI.markChapterProgress then
        local result = SuwayomiAPI.markChapterProgress(
            credentials,
            chapter_id,
            is_read == true,
            tonumber(last_page_read) or 0
        )
        -- markChapterProgress already normalises the response; return as-is.
        return result or { ok = false, error = "No response from API." }
    end

    -- Fallback: raw GraphQL HTTP POST (no suwayomiplus dependency).
    return SyncWorker._directGraphQLSync(credentials, cid, is_read, last_page_read)
end

-- ---------------------------------------------------------------------------
-- Fallback path: direct HTTP POST to the GraphQL endpoint
-- ---------------------------------------------------------------------------

function SyncWorker._directGraphQLSync(credentials, chapter_id, is_read, last_page_read)
    local ok_http, http = pcall(require, "socket.http")
    if not ok_http or not http then
        return { ok = false, error = "socket.http unavailable." }
    end
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    if not ok_ltn12 or not ltn12 then
        return { ok = false, error = "ltn12 unavailable." }
    end

    local cid = tonumber(chapter_id) or chapter_id
    local page_num = math.max(0, math.floor(tonumber(last_page_read) or 0))
    local read_str = (is_read == true) and "true" or "false"

    -- Minimal GraphQL mutation — mirrors _buildUpdateChapterProgressMutation in
    -- the suwayomiplus queries module.
    local mutation = string.format(
        [[{"query":"mutation { updateChapter(input: { id: %s, patch: { isRead: %s, lastPageRead: %d } }) { chapters { isRead lastPageRead } } }"}]],
        tostring(cid),
        read_str,
        page_num
    )

    -- Build the endpoint URL; tolerate a trailing slash in the configured URL.
    local base_url = tostring(credentials.server_url or ""):gsub("/*$", "")
    local endpoint = base_url .. "/api/graphql"

    -- Build auth header if credentials are present.
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = tostring(#mutation),
    }
    local username = tostring(credentials.username or "")
    local password = tostring(credentials.password or "")
    if username ~= "" then
        local ok_mime, mime = pcall(require, "mime")
        if ok_mime and mime and mime.b64 then
            local encoded = mime.b64(username .. ":" .. password)
            headers["Authorization"] = "Basic " .. encoded
        end
    end

    local response_chunks = {}
    local request_ok, http_code = pcall(function()
        return http.request{
            url    = endpoint,
            method = "POST",
            headers = headers,
            source = ltn12.source.string(mutation),
            sink   = ltn12.sink.table(response_chunks),
        }
    end)

    if not request_ok then
        -- http_code holds the error string when pcall catches an exception.
        return { ok = false, error = "HTTP request failed: " .. tostring(http_code) }
    end

    local code = tonumber(http_code)
    if code and code >= 200 and code < 300 then
        return { ok = true, body = table.concat(response_chunks) }
    end

    return {
        ok    = false,
        error = "Server returned HTTP " .. tostring(http_code or "unknown"),
    }
end

return SyncWorker
