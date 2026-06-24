local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local sha2 = require("ffi/sha2")
local logger = require("logger")

local Cache = {}

local function root()
    return DataStorage:getSettingsDir() .. "/rosetta_cache"
end

local function slug(s)
    if not s then return "_" end
    return (s:gsub("[^%w%-%.]", "_"))
end

local function ensure_dir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local parts, acc = {}, ""
    for part in path:gmatch("[^/]+") do table.insert(parts, part) end
    for _, p in ipairs(parts) do
        acc = acc .. "/" .. p
        if lfs.attributes(acc, "mode") ~= "directory" then
            local ok = lfs.mkdir(acc)
            if not ok and lfs.attributes(acc, "mode") ~= "directory" then
                return false
            end
        end
    end
    return true
end

-- Cache key is now derived from the actual page content (md5 of the page text),
-- not the page number — because pagination can shift between sessions when the
-- bottom margin or font changes, and a stale "p00042" file would otherwise be
-- served on a page whose content has moved.  Content-derived keys are stable
-- across reflows.
function Cache:keyFor(text)
    if not text or #text == 0 then return nil end
    local ok, h = pcall(function() return sha2.md5(text) end)
    if not ok or not h then return nil end
    return h
end

function Cache:pathFor(book_key, content_hash, lang, model)
    local dir = root() .. "/" .. slug(book_key)
    local fname = string.format("%s.%s.%s.txt", content_hash, slug(lang or "x"), slug(model or "x"))
    return dir, dir .. "/" .. fname
end

function Cache:get(book_key, content_hash, lang, model)
    if not book_key or not content_hash then return nil end
    local _, p = self:pathFor(book_key, content_hash, lang, model)
    local f = io.open(p, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    if s and #s > 0 then return s end
    return nil
end

function Cache:put(book_key, content_hash, lang, model, text)
    if not book_key or not content_hash or not text or #text == 0 then return false end
    local dir, p = self:pathFor(book_key, content_hash, lang, model)
    if not ensure_dir(dir) then
        logger.info("rosetta cache: mkdir failed:", dir)
        return false
    end
    local f = io.open(p, "wb")
    if not f then return false end
    f:write(text)
    f:close()
    logger.info("rosetta cache: wrote", p, "len", #text)
    return true
end

-- Diagnostic helper: nuke the entire cache root.  Used during testing so
-- each KOReader start runs against a clean slate.
function Cache:clearAll()
    local r = root()
    if lfs.attributes(r, "mode") ~= "directory" then return end
    local function rm_dir(d)
        for entry in lfs.dir(d) do
            if entry ~= "." and entry ~= ".." then
                local p = d .. "/" .. entry
                local attr = lfs.attributes(p, "mode")
                if attr == "directory" then
                    rm_dir(p); pcall(lfs.rmdir, p)
                else
                    pcall(os.remove, p)
                end
            end
        end
    end
    rm_dir(r)
    logger.info("rosetta cache: cleared", r)
end

return Cache
