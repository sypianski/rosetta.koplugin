-- Loads and queries a paraligilo-produced anchor file
-- (`<book>.sdr/rosetta-aligned.json`).  See ANCHOR_FORMAT.md for the schema.
--
-- Used by main.lua before falling back to the AI translation pipeline: when an
-- anchor exists for a given source paragraph (matched by content hash), the
-- pre-aligned translation is rendered instead of calling the model.

local rapidjson = require("rapidjson")
local sha2 = require("ffi/sha2")
local logger = require("logger")

local Aligned = {}

-- ---------------------------------------------------------------------------
-- Paragraph normalization — MUST match paraligilo's implementation.  Steps:
--   1. trim leading + trailing whitespace
--   2. collapse runs of any whitespace (NBSP, tab, newline, regular space) to
--      a single ASCII space
--   3. (NFC normalization is left to writer/reader to apply consistently;
--      most prose round-trips identically without it)
-- ---------------------------------------------------------------------------
local function normalize(text)
    if not text then return "" end
    -- collapse NBSP (UTF-8 0xC2 0xA0), tabs, newlines, space into single space
    text = text:gsub("\194\160", " ")
    text = text:gsub("[%s\t\r\n]+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

function Aligned:_pathsFor(book_file)
    -- KOReader writes the sidecar dir under one of two conventions
    -- depending on the document_sidecar_dir setting:
    --   1. "<book_file>.sdr"     (file-name plus literal ".sdr" — newer default)
    --   2. "<book_basename>.sdr" (strip the final extension first — classic layout)
    -- Yield both so callers can probe either.
    if not book_file then return {} end
    local with_ext = book_file .. ".sdr/rosetta-aligned.json"
    local stripped = book_file:gsub("%.[^./]+$", "") .. ".sdr/rosetta-aligned.json"
    if stripped == with_ext then return { with_ext } end
    return { with_ext, stripped }
end

function Aligned:_pathFor(book_file)
    -- back-compat: return the first candidate (used for diagnostics only)
    local paths = self:_pathsFor(book_file)
    return paths[1]
end

function Aligned:_existingPathFor(book_file)
    for _, p in ipairs(self:_pathsFor(book_file)) do
        local f = io.open(p, "r")
        if f then f:close(); return p end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Load anchors for the currently-open book.  Caches the parsed table on the
-- Aligned instance keyed by `book_file`, so reloading is a no-op.
--
-- Returns the parsed object on success, nil on absence / parse failure.
-- ---------------------------------------------------------------------------
function Aligned:loadForBook(book_file)
    if not book_file then return nil end
    self._cache = self._cache or {}
    if self._cache[book_file] ~= nil then return self._cache[book_file] end

    local path = self:_existingPathFor(book_file)
    if not path then
        self._cache[book_file] = false
        return nil
    end
    local f = io.open(path, "rb")
    if not f then
        self._cache[book_file] = false
        return nil
    end
    local body = f:read("*a")
    f:close()
    local ok, parsed = pcall(rapidjson.decode, body, { null = nil })
    if not ok or not parsed or type(parsed) ~= "table" then
        logger.info("rosetta_aligned: parse failed for", path)
        self._cache[book_file] = false
        return nil
    end
    if parsed.rosetta_align_version ~= 1 then
        logger.info("rosetta_aligned: unsupported version", tostring(parsed.rosetta_align_version))
        self._cache[book_file] = false
        return nil
    end
    if not parsed.by_hash then
        logger.info("rosetta_aligned: missing by_hash field")
        self._cache[book_file] = false
        return nil
    end
    logger.info("rosetta_aligned: loaded", path,
        "method=", tostring(parsed.method),
        "anchors=", parsed.stats and parsed.stats.matched or "?")
    self._cache[book_file] = parsed
    return parsed
end

-- ---------------------------------------------------------------------------
-- Look up the translation for a single source paragraph.
--
-- Returns (tgt_text, confidence) or (nil, nil) when no anchor exists / its
-- confidence is below `min_confidence` (default 0.6).
-- ---------------------------------------------------------------------------
function Aligned:lookupParagraph(book_file, src_text, min_confidence)
    min_confidence = min_confidence or 0.6
    local doc = self:loadForBook(book_file)
    if not doc then return nil end
    local norm = normalize(src_text)
    if norm == "" then return nil end
    local ok, hash = pcall(sha2.md5, norm)
    if not ok or not hash then return nil end
    local entry = doc.by_hash[hash]
    if not entry then return nil end
    if (entry.confidence or 1.0) < min_confidence then return nil end
    return entry.tgt, entry.confidence
end

-- ---------------------------------------------------------------------------
-- Translate a chunk of multi-paragraph text by looking up each `\n\n`-split
-- paragraph individually.  Returns (joined_text, hit_count, miss_count).
--
-- For misses, the corresponding paragraph in the output is left untouched
-- (caller may decide to re-translate those paragraphs via the AI pipeline).
-- ---------------------------------------------------------------------------
function Aligned:lookupBlock(book_file, block_text, min_confidence)
    if not block_text or block_text == "" then return nil, 0, 0 end
    local doc = self:loadForBook(book_file)
    if not doc then return nil, 0, 0 end

    local out, hits, misses = {}, 0, 0
    local last_tgt = nil  -- de-dup consecutive identical translations
                          -- (one tgt paragraph mapped from multiple src ones)
    for paragraph in (block_text .. "\n\n"):gmatch("(.-)\n\n") do
        if paragraph ~= "" then
            local tgt = self:lookupParagraph(book_file, paragraph, min_confidence)
            if tgt then
                if tgt ~= last_tgt then
                    table.insert(out, tgt)
                    last_tgt = tgt
                end
                hits = hits + 1
            else
                table.insert(out, paragraph)
                last_tgt = nil
                misses = misses + 1
            end
        end
    end
    return table.concat(out, "\n\n"), hits, misses
end

-- Exposed for tests / paraligilo cross-reference
Aligned._normalize = normalize

return Aligned
