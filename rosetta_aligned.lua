-- Loads and queries a paraligilo-produced anchor file
-- (`<book>.sdr/parallel-aligned.json`).  See ANCHOR_FORMAT.md for the schema.
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
    -- 'ingrediencję2' becomes 'Graniczna' / 'ingrediencję'. Lua's %a is
    -- ASCII-only, so use a byte-class that matches anything that isn't
    -- whitespace/digit/punct (catches UTF-8 trailing bytes of letters like ę).
    text = text:gsub("([^%s%d%p])%d+", "%1")
    -- Strip stray inline footnote markers: "word N word" -> "word word".
    for _ = 1, 2 do
        text = text:gsub("([^%s%d%p])%s+%d%d?%d?%s+([^%s%d%p])", "%1 %2")
    end
    text = text:gsub("[%s\t\r\n]+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    -- Drop whitespace adjacent to punctuation. paraligilo's HTML extract
    -- inserts " " between adjacent inline elements (e.g. „<em>X</em>!" -> '„ X !'),
    -- while crengine renders them flush ('„X!'). Normalize to flush on both
    -- sides so the hashes line up.
    text = text:gsub("%s+([%!%?%.,;:%)%]%}\"'])", "%1")
    text = text:gsub("([%(%[%{\"'])%s+", "%1")
    return text:lower()
end

function Aligned:_pathsFor(book_file)
    -- KOReader writes the sidecar dir under one of two conventions
    -- depending on the document_sidecar_dir setting:
    --   1. "<book_file>.sdr"     (file-name plus literal ".sdr" — newer default)
    --   2. "<book_basename>.sdr" (strip the final extension first — classic layout)
    -- Yield both so callers can probe either.
    if not book_file then return {} end
    local with_ext = book_file .. ".sdr/parallel-aligned.json"
    local stripped = book_file:gsub("%.[^./]+$", "") .. ".sdr/parallel-aligned.json"
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
    if parsed.epa_version ~= 1 and parsed.epa_version ~= 2 then
        logger.info("rosetta_aligned: unsupported version", tostring(parsed.epa_version))
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

-- ---------------------------------------------------------------------------
-- For AI fallback: given the positions of the few paragraphs we did manage
-- to hash-match on the current page, return a window of nearby paragraph
-- entries from the ordered list. Each entry has src + tgt so the AI can use
-- it as a bilingual corpus for the misses on the page.
-- ---------------------------------------------------------------------------
function Aligned:nearbyContext(book_file, hit_positions, window)
    local doc = self:loadForBook(book_file)
    if not doc or not doc.paragraphs then return nil end
    window = window or 8
    local lo, hi
    if hit_positions and #hit_positions > 0 then
        lo = hit_positions[1]; hi = hit_positions[1]
        for _, p in ipairs(hit_positions) do
            if p < lo then lo = p end
            if p > hi then hi = p end
        end
        lo = math.max(1, lo - window)
        hi = math.min(#doc.paragraphs, hi + window)
    else
        -- no hits — caller has no position; bail
        return nil
    end
    local out = {}
    for i = lo, hi do
        local p = doc.paragraphs[i]
        if p then table.insert(out, { src = p.src, tgt = p.tgt }) end
    end
    return out
end

function Aligned:posForParagraph(book_file, src_text)
    local doc = self:loadForBook(book_file)
    if not doc then return nil end
    local norm = normalize(src_text)
    if norm == "" then return nil end
    local ok, hash = pcall(sha2.md5, norm)
    if not ok or not hash then return nil end
    local entry = doc.by_hash[hash]
    if not entry then return nil end
    return entry.pos
end

-- Stricter substring fallback: returns the position of a JSON src that the
-- page text is largely contained in (or contains). Guards against picking a
-- semantically-near entry when the page is genuinely untranslated content.
function Aligned:posByContainment(book_file, page_text, sample_len)
    local doc = self:loadForBook(book_file)
    if not doc or not doc.paragraphs then return nil end
    sample_len = sample_len or 80
    local n_page = normalize(page_text)
    if #n_page < 20 then return nil end
    local page_head = n_page:sub(1, sample_len)
    for i, p in ipairs(doc.paragraphs) do
        local n_src = normalize(p.src or "")
        if #n_src >= 20 then
            local src_head = n_src:sub(1, sample_len)
            -- bidirectional containment of leading sample_len chars
            if n_src:find(page_head, 1, true) or n_page:find(src_head, 1, true) then
                return i
            end
        end
    end
    return nil
end

-- Fallback positioning for pages whose paragraphs are mid-paragraph
-- continuations of a JSON entry (page boundary cuts inside a long paragraph,
-- so the hash never matches). We scan the ordered paragraphs list for any
-- entry whose normalized src CONTAINS a normalized chunk of the page text,
-- or vice versa. Returns the position of the first match, or nil.
function Aligned:posBySubstring(book_file, page_text, sample_len)
    local doc = self:loadForBook(book_file)
    if not doc or not doc.paragraphs then return nil end
    sample_len = sample_len or 60
    local n_page = normalize(page_text)
    if #n_page == 0 then return nil end
    -- Try the first sample_len chars of the page as needle.
    local head = n_page:sub(1, sample_len)
    -- And the last sample_len chars as a second needle.
    local tail = n_page:sub(-sample_len)
    for i, p in ipairs(doc.paragraphs) do
        local n_src = normalize(p.src or "")
        if #n_src > 0 then
            if n_src:find(head, 1, true) or n_src:find(tail, 1, true)
               or n_page:find(n_src:sub(1, sample_len), 1, true) then
                return i
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Per-doc cache of normalized paragraph src strings.  slicePage() needs to
-- scan all paragraphs when probing partial-anchor candidates; normalizing on
-- every call would be O(N·M).  Cached on the parsed doc table itself so it
-- gets discarded when the book is closed / cache cleared.
-- ---------------------------------------------------------------------------
local function ensure_norm_cache(doc)
    if doc._norm_cache then return doc._norm_cache end
    local cache = {}
    for i, p in ipairs(doc.paragraphs or {}) do
        cache[i] = normalize(p.src or "")
    end
    doc._norm_cache = cache
    return cache
end

-- Snap a byte index to a word boundary in `text`.  Char-safe because we only
-- move past ASCII whitespace / punctuation; UTF-8 continuation bytes are
-- never touched.  `direction` is "end" (move forward past current word) or
-- "start" (move backward to start of current word).
local function snap_word(text, idx, direction)
    local n = #text
    if idx <= 0 then return 0 end
    if idx >= n then return n end
    if direction == "end" then
        while idx <= n do
            local b = text:byte(idx)
            if not b then break end
            -- stop at whitespace / common end-punct
            if b == 32 or b == 9 or b == 10 or b == 13
                    or b == 46 or b == 44 or b == 59 or b == 58
                    or b == 33 or b == 63 or b == 41 or b == 93
                    or b == 125 or b == 34 or b == 39 then
                return idx - 1
            end
            idx = idx + 1
        end
        return n
    else
        while idx > 0 do
            local b = text:byte(idx)
            if b == 32 or b == 9 or b == 10 or b == 13 then
                return idx
            end
            idx = idx - 1
        end
        return 0
    end
end

-- Find the longest suffix of `prev` that matches a prefix of `nxt`.
-- Returns byte length (0 when no overlap >= min_chars).
local function max_overlap(prev, nxt, min_chars)
    min_chars = min_chars or 40
    local pn, nn = #prev, #nxt
    local a_start = math.max(1, pn - 600 + 1)
    local b_end = math.min(nn, 600)
    local a = prev:sub(a_start, pn)
    local b = nxt:sub(1, b_end)
    local max_n = math.min(#a, #b)
    for n = max_n, min_chars, -1 do
        if a:sub(-n) == b:sub(1, n) then return n end
    end
    return 0
end

-- Scan doc paragraphs near `near_idx` (then globally) for one whose normalized
-- src has `page_norm` as a SUFFIX (role="first") or PREFIX (role="last").
-- Returns (doc_idx, match_kind) or nil.
local function find_partial_anchor(page_norm, doc, near_idx, role)
    if not page_norm or page_norm == "" then return nil end
    local cache = ensure_norm_cache(doc)
    local total = #cache
    if total == 0 then return nil end

    -- Build ordered candidate list: window first, then rest.
    local order = {}
    if near_idx then
        local lo = math.max(1, near_idx - 30)
        local hi = math.min(total, near_idx + 30)
        for i = lo, hi do order[#order + 1] = i end
        for i = 1, total do
            if i < lo or i > hi then order[#order + 1] = i end
        end
    else
        for i = 1, total do order[i] = i end
    end

    -- Heuristic probe to reduce false matches on tiny suffixes/prefixes.
    local probe
    if #page_norm >= 80 then
        probe = (role == "last") and page_norm:sub(1, 80) or page_norm:sub(-80)
    elseif #page_norm >= 30 then
        probe = page_norm
    end

    for _, i in ipairs(order) do
        local d = cache[i]
        if d and #d > 0 then
            if role == "first" then
                if d:sub(-#page_norm) == page_norm then return i, "suffix" end
                if probe and d:sub(-#probe) == probe then return i, "suffix" end
            else
                if d:sub(1, #page_norm) == page_norm then return i, "prefix" end
                if probe and d:sub(1, #probe) == probe then return i, "prefix" end
            end
        end
    end

    -- Containment fallback (mid-paragraph cut on both ends, rare).
    for _, i in ipairs(order) do
        local d = cache[i]
        if d and #d > 0 then
            if d:find(page_norm, 1, true) then return i, "contains" end
            if probe and d:find(probe, 1, true) then return i, "contains" end
        end
    end
    return nil
end

-- Slice the tgt of `doc_para` proportionally to how much of its src is
-- represented by `page_norm_len` bytes (normalized length).  Returns the
-- tgt slice with word-boundary snapping.
local function slice_partial_tgt(doc_para, page_norm_len, role)
    local src_full = doc_para.src or ""
    local tgt_full = doc_para.tgt or ""
    local src_len = math.max(1, #normalize(src_full))
    local tgt_len = #tgt_full
    local frac = math.min(1.0, page_norm_len / src_len)

    if role == "first" then
        local start_char = math.floor(tgt_len * (1.0 - frac) + 0.5)
        start_char = snap_word(tgt_full, start_char, "start")
        return tgt_full:sub(start_char + 1)
    else
        local end_char = math.floor(tgt_len * frac + 0.5)
        end_char = snap_word(tgt_full, end_char, "end")
        return tgt_full:sub(1, end_char)
    end
end

-- ---------------------------------------------------------------------------
-- Slice a KOReader page into its tgt translation using:
--   1. hash lookup for full middle paragraphs
--   2. suffix/prefix partial-anchor for the first/last paragraph
--   3. proportional char slice (word-snapped) of the tgt
--   4. overlap-dedup when adjacent JSON entries share leading/trailing tgt
--
-- Returns (tgt_text, info) where info = {
--   pieces = { { kind, doc_idx, tgt_slice, note } ... },
--   continuation = true if first paragraph is mid-paragraph,
--   missed = list of source paragraphs we couldn't place,
-- }
-- Mirrors paraligilo/experiments/slice_proportional.py:slice_page().
-- ---------------------------------------------------------------------------
function Aligned:slicePage(book_file, page_text)
    local doc = self:loadForBook(book_file)
    if not doc or not doc.paragraphs then return nil end
    if not page_text or page_text == "" then return "" end

    -- Split page on blank lines.
    local paragraphs = {}
    for p in (page_text .. "\n\n"):gmatch("(.-)\n\n") do
        if p ~= "" then paragraphs[#paragraphs + 1] = p end
    end
    local n = #paragraphs
    if n == 0 then return "" end

    local pieces = {}
    local missed = {}
    local last_doc_idx = nil
    local continuation = false

    for i, raw in ipairs(paragraphs) do
        local norm = normalize(raw)
        if norm ~= "" then
            local ok, hash = pcall(sha2.md5, norm)
            local entry = (ok and hash) and doc.by_hash[hash] or nil
            if entry then
                last_doc_idx = entry.pos or last_doc_idx
                pieces[#pieces + 1] = {
                    kind = "full",
                    doc_idx = entry.pos,
                    tgt_slice = entry.tgt or "",
                    note = "hash",
                }
            elseif i == 1 or i == n then
                local role = (i == 1) and "first" or "last"
                local idx, match_kind = find_partial_anchor(norm, doc, last_doc_idx, role)
                if idx then
                    local dp = doc.paragraphs[idx]
                    local tgt_slice = slice_partial_tgt(dp, #norm, role)
                    last_doc_idx = idx
                    if role == "first" then continuation = true end
                    pieces[#pieces + 1] = {
                        kind = "partial_" .. role,
                        doc_idx = idx,
                        tgt_slice = tgt_slice,
                        note = "match=" .. match_kind,
                    }
                else
                    missed[#missed + 1] = raw
                    pieces[#pieces + 1] = {
                        kind = "partial_" .. role,
                        doc_idx = nil, tgt_slice = "",
                        note = "no anchor",
                    }
                end
            else
                missed[#missed + 1] = raw
                pieces[#pieces + 1] = {
                    kind = "middle_miss",
                    doc_idx = nil, tgt_slice = "",
                    note = "hash miss in middle",
                }
            end
        end
    end

    -- Stitch with overlap-dedup.
    local rendered = {}
    for _, p in ipairs(pieces) do
        if p.tgt_slice and p.tgt_slice ~= "" then
            if #rendered > 0 then
                local overlap = max_overlap(rendered[#rendered], p.tgt_slice, 40)
                if overlap > 0 then
                    rendered[#rendered + 1] = p.tgt_slice:sub(overlap + 1)
                else
                    rendered[#rendered + 1] = p.tgt_slice
                end
            else
                rendered[#rendered + 1] = p.tgt_slice
            end
        end
    end

    local out = table.concat(rendered, "\n\n")
    return out, {
        pieces = pieces,
        continuation = continuation,
        missed = missed,
    }
end

-- Exposed for tests / paraligilo cross-reference
Aligned._normalize = normalize
Aligned._find_partial_anchor = find_partial_anchor
Aligned._slice_partial_tgt = slice_partial_tgt
Aligned._max_overlap = max_overlap
Aligned._snap_word = snap_word

return Aligned
