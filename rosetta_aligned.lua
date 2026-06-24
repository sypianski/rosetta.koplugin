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
-- UTF-8 quote / dash / NBSP foldings — must mirror QUOTE_FOLD in
-- paraligilo/emit_rosetta.py (otherwise hashes diverge).
local QUOTE_FOLD = {
    ["\194\160"]   = " ",      -- NBSP        U+00A0
    ["\194\173"]   = "",       -- soft hyphen U+00AD
    ["\239\187\191"] = "",     -- BOM / ZWNBSP U+FEFF
    ["\226\128\139"] = "",     -- zero-width space U+200B
    ["\226\128\140"] = "",     -- ZWNJ        U+200C
    ["\226\128\141"] = "",     -- ZWJ         U+200D
    ["\226\128\158"] = '"',    -- „           U+201E
    ["\226\128\157"] = '"',    -- ”           U+201D
    ["\226\128\156"] = '"',    -- “           U+201C
    ["\194\171"]   = '"',      -- «           U+00AB
    ["\194\187"]   = '"',      -- »           U+00BB
    ["\226\128\154"] = "'",    -- ‚           U+201A
    ["\226\128\153"] = "'",    -- ’           U+2019
    ["\226\128\152"] = "'",    -- ‘           U+2018
    ["\226\128\185"] = "'",    -- ‹           U+2039
    ["\226\128\186"] = "'",    -- ›           U+203A
    ["\226\128\147"] = "-",    -- –           U+2013
    ["\226\128\148"] = "-",    -- —           U+2014
    ["\226\136\146"] = "-",    -- −           U+2212
    ["\226\128\166"] = "...",  -- …           U+2026
}

local function normalize(text)
    if not text then return "" end
    for k, v in pairs(QUOTE_FOLD) do
        text = text:gsub(k, v)
    end
    -- Strip markdown emphasis markers KOReader's Extract:toTitledPlainText
    -- adds for <em>/<i>/<strong>/<b> spans. paraligilo extract.py strips
    -- the tags but keeps the text, so the markers desync the hashes.
    text = text:gsub("%*+", "")
    -- Strip stray footnote-suffix digits glued onto a word: 'Graniczna3' or
    -- 'ingrediencję2' becomes 'Graniczna' / 'ingrediencję'. crengine renders
    -- <sup>N</sup> as inline digits without a separating space, while we
    -- already dropped the <sup> in extract.py. Restore parity by stripping
    -- both forms here.
    text = text:gsub("(%a)%d+", "%1")
    -- Strip stray inline footnote markers: "word N word" -> "word word".
    for _ = 1, 2 do
        text = text:gsub("(%a)%s+%d%d?%d?%s+(%a)", "%1 %2")
    end
    text = text:gsub("[%s\t\r\n]+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text:lower()
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
-- Lookup every paragraph in `block_text`. Returns (joined, hits, misses).
-- `miss_marker` controls what to insert when a paragraph has no alignment:
--   nil (default) -> insert the source paragraph verbatim (AI-fallback flow:
--                    something visible that the AI step can translate later)
--   ""            -> drop the paragraph entirely (pure aligned-only flow)
--   any string    -> insert that string in place of the missing paragraph
function Aligned:lookupBlock(book_file, block_text, min_confidence, miss_marker)
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
                if miss_marker == nil then
                    table.insert(out, paragraph)
                elseif miss_marker ~= "" then
                    table.insert(out, miss_marker)
                end
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
