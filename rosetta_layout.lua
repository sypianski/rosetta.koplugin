-- Minimal mixed-style line layout for the translation panel.
--
-- TextBoxWidget renders a single face; to get inline italic / bold with
-- justified line-wrap we'd otherwise need crengine, which is only reachable
-- via CreDocument-from-file (heavy + fragile).  This module does a small
-- word-level greedy layout pass in pure Lua and paints each word with the
-- face matching its emphasis.
--
-- Input: text containing markdown `*italic*` and `**bold**` markers, plus
-- newline-separated paragraphs.  Output: paints into Screen.bb at
-- (left_x, top_y) within a width × height box.
--
-- We measure with RenderText:sizeUtf8Text (the same primitive TextWidget
-- uses), so widths match KOReader's normal rendering.

local RenderText = require("ui/rendertext")
local Font = require("ui/font")
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("logger")

local Layout = {}

-- ---------------------------------------------------------------------------
-- 1. Parse markdown emphasis into a flat list of style-runs.
--    Recognises **bold**, *italic*; **double** wins over *single* (greedy
--    longest-marker).  Unmatched markers are kept as literal chars.
-- ---------------------------------------------------------------------------
local function parse_runs(text)
    local runs = {}
    local i, n = 1, #text
    local bold, italic = false, false
    local buf = {}
    local function flush()
        if #buf > 0 then
            local style = bold and italic and "bi"
                or bold and "b"
                or italic and "i"
                or "n"
            table.insert(runs, { text = table.concat(buf), style = style })
            buf = {}
        end
    end
    while i <= n do
        local c = text:sub(i, i)
        local c2 = text:sub(i, i + 1)
        if c2 == "**" then
            flush(); bold = not bold; i = i + 2
        elseif c == "*" then
            flush(); italic = not italic; i = i + 1
        else
            table.insert(buf, c); i = i + 1
        end
    end
    flush()
    return runs
end

-- ---------------------------------------------------------------------------
-- 2. Face cache.  One face per (style, px) combination.
-- ---------------------------------------------------------------------------
local function get_face(face_name, px, bold, italic)
    local file, idx
    if face_name then
        local cre_ok, cre = pcall(require, "libs/libkoreader-cre")
        if cre_ok and cre and cre.getFontFaceFilenameAndFaceIndex then
            local fok, fn, fi = pcall(cre.getFontFaceFilenameAndFaceIndex, face_name, bold or false, italic or false)
            if fok and fn then file, idx = fn, fi end
            logger.dbg("rosetta layout: face=", face_name,
                "bold=", tostring(bold), "italic=", tostring(italic),
                "→ file=", tostring(fn), "idx=", tostring(fi))
        end
    end
    if file then
        local f = Font:getFace(file, px, idx)
        if f then
            logger.dbg("rosetta layout: Font:getFace(", file, ",", px, ",", idx, ") OK")
            return f
        else
            logger.dbg("rosetta layout: Font:getFace(", file, ") returned nil — falling back")
        end
    end
    if face_name then
        local f = Font:getFace(face_name, px)
        if f then
            logger.dbg("rosetta layout: fallback Font:getFace(", face_name, ") OK")
            return f
        end
    end
    return Font:getFace("cfont", px)
end

local function make_face_resolver(face_name, px)
    local cache = {}
    return function(style)
        if cache[style] then return cache[style] end
        local bold = style == "b" or style == "bi"
        local italic = style == "i" or style == "bi"
        cache[style] = get_face(face_name, px, bold, italic)
        return cache[style]
    end
end

-- ---------------------------------------------------------------------------
-- 3. Tokenise runs into a flat list of tokens. Each token is a word, a
--    visible-space, or a newline. Words carry their measured width.
-- ---------------------------------------------------------------------------
local function tokens_from_runs(runs, resolve_face)
    -- Tokens: {kind="word", text, style, w} / {kind="space", w} / {kind="par"}
    local tokens = {}
    local space_w_per_style = {}
    local function space_w(style)
        if space_w_per_style[style] then return space_w_per_style[style] end
        local sz = RenderText:sizeUtf8Text(0, math.huge, resolve_face(style), " ")
        space_w_per_style[style] = sz and sz.x or 0
        return space_w_per_style[style]
    end
    for _, run in ipairs(runs) do
        local text = run.text
        local pos = 1
        while pos <= #text do
            local c = text:sub(pos, pos)
            if c == "\n" then
                -- paragraph break if followed by another \n (greedy gather)
                local newlines = 1
                local p2 = pos + 1
                while text:sub(p2, p2) == "\n" do
                    newlines = newlines + 1; p2 = p2 + 1
                end
                if newlines >= 2 then
                    table.insert(tokens, { kind = "par" })
                else
                    table.insert(tokens, { kind = "space", w = space_w(run.style) })
                end
                pos = p2
            elseif c == " " or c == "\t" then
                table.insert(tokens, { kind = "space", w = space_w(run.style) })
                pos = pos + 1
                while text:sub(pos, pos) == " " or text:sub(pos, pos) == "\t" do
                    pos = pos + 1
                end
            else
                -- word: collect non-whitespace
                local start = pos
                while pos <= #text do
                    local cc = text:sub(pos, pos)
                    if cc == " " or cc == "\t" or cc == "\n" then break end
                    pos = pos + 1
                end
                local word = text:sub(start, pos - 1)
                if #word > 0 then
                    -- Convert leading NBSPs (0xC2 0xA0, used as paragraph
                    -- indent) to regular spaces inside the word.  NBSP can
                    -- render zero-width in some fonts; a regular space inside
                    -- a word is not treated as a token boundary by our
                    -- tokenizer (we already passed that branch) and renders
                    -- reliably.
                    local nbsp_prefix_count = 0
                    while word:sub(1, 2) == "\194\160" do
                        nbsp_prefix_count = nbsp_prefix_count + 1
                        word = word:sub(3)
                    end
                    if nbsp_prefix_count > 0 then
                        word = string.rep(" ", nbsp_prefix_count) .. word
                    end
                    local clean = word:gsub("\194\173", "")
                    local breakpoints = {}
                    if word ~= clean then
                        local clean_pos = 0
                        local i2 = 1
                        while i2 <= #word do
                            local b1 = word:byte(i2)
                            if b1 == 0xC2 and word:byte(i2 + 1) == 0xAD then
                                table.insert(breakpoints, clean_pos)
                                i2 = i2 + 2
                            else
                                -- advance by 1 byte of clean text; UTF-8
                                -- continuation bytes (0x80-0xBF) accumulate
                                -- into the same codepoint width.
                                clean_pos = clean_pos + 1
                                i2 = i2 + 1
                            end
                        end
                    end
                    local sz = RenderText:sizeUtf8Text(0, math.huge, resolve_face(run.style), clean)
                    table.insert(tokens, {
                        kind = "word",
                        text = clean,
                        style = run.style,
                        w = sz and sz.x or 0,
                        breakpoints = breakpoints,
                    })
                end
            end
        end
    end
    return tokens
end

-- ---------------------------------------------------------------------------
-- 4. Greedy line-fill.  Returns a list of lines; each line is a list of
--    word/space tokens (no newlines / paragraph markers), plus a `last_in_par`
--    flag so the justifier knows not to stretch the last line of a paragraph.
-- ---------------------------------------------------------------------------
-- Try to split a word at one of its soft-hyphen breakpoints so the prefix
-- (plus a visible "-") fits in `avail` pixels.  Returns (prefix_text,
-- prefix_w, suffix_text, suffix_w) or nil if no breakpoint fits.
local function hyph_split(word_token, resolve_face, avail)
    local bp = word_token.breakpoints
    if not bp or #bp == 0 then return nil end
    local face = resolve_face(word_token.style)
    local hyphen_w = (RenderText:sizeUtf8Text(0, math.huge, face, "-") or {x = 0}).x
    local best
    for _, pos in ipairs(bp) do
        if pos > 0 and pos < #word_token.text then
            local prefix = word_token.text:sub(1, pos) .. "-"
            local pw = (RenderText:sizeUtf8Text(0, math.huge, face, prefix) or {x = 0}).x
            if pw <= avail then
                best = { prefix = prefix, pw = pw, cut = pos }
            else
                break
            end
        end
    end
    if not best then return nil end
    local suffix = word_token.text:sub(best.cut + 1)
    local sw = (RenderText:sizeUtf8Text(0, math.huge, resolve_face(word_token.style), suffix) or {x = 0}).x
    return best.prefix, best.pw, suffix, sw
end

local function break_lines(tokens, max_w, resolve_face)
    local lines = {}
    local cur = { width = 0, items = {} }
    local function commit(last_in_par)
        if #cur.items > 0 then
            while #cur.items > 0 and cur.items[#cur.items].kind == "space" do
                cur.width = cur.width - cur.items[#cur.items].w
                cur.items[#cur.items] = nil
            end
            cur.last_in_par = last_in_par
            table.insert(lines, cur)
        elseif last_in_par then
            table.insert(lines, { width = 0, items = {}, last_in_par = true, blank = true })
        end
        cur = { width = 0, items = {} }
    end
    for _, t in ipairs(tokens) do
        if t.kind == "par" then
            commit(true)
        elseif t.kind == "space" then
            if #cur.items > 0 then
                table.insert(cur.items, t)
                cur.width = cur.width + t.w
            end
        elseif t.kind == "word" then
            local needed = cur.width + t.w
            if #cur.items == 0 then
                table.insert(cur.items, t)
                cur.width = cur.width + t.w
            elseif needed <= max_w then
                table.insert(cur.items, t)
                cur.width = cur.width + t.w
            else
                -- try hyphenated split first
                local avail = max_w - cur.width
                local pre, pw, suf, sw = hyph_split(t, resolve_face, avail)
                if pre then
                    table.insert(cur.items, { kind = "word", text = pre, style = t.style, w = pw })
                    cur.width = cur.width + pw
                    commit(false)
                    table.insert(cur.items, { kind = "word", text = suf, style = t.style, w = sw, breakpoints = {} })
                    cur.width = cur.width + sw
                else
                    commit(false)
                    table.insert(cur.items, t)
                    cur.width = cur.width + t.w
                end
            end
        end
    end
    commit(true)
    return lines
end

-- ---------------------------------------------------------------------------
-- 5. Paint lines into Screen.bb.
-- ---------------------------------------------------------------------------
local function line_metrics(face_resolver, line_extra)
    -- Use freetype metrics for the normal face; same line-height for italic/
    -- bold (small differences average out at body sizes).
    local face = face_resolver("n")
    local face_height, face_ascender = face.ftsize:getHeightAndAscender()
    local height = math.ceil(face_height * (1 + (line_extra or 0.0)))
    local ascender = math.floor(face_ascender + 0.5)
    return height, ascender
end

function Layout.paint(opts)
    -- opts = { text, face_name, font_px, line_height_extra,
    --         left_x, top_y, width, height, justified, target_color }
    local text     = opts.text or ""
    local face_name = opts.face_name
    local font_px  = opts.font_px or 16
    local lh_extra = opts.line_height_extra or 0.3
    local left_x   = opts.left_x or 0
    local top_y    = opts.top_y or 0
    local width    = opts.width or 100
    local height   = opts.height or 100
    local justified = opts.justified ~= false  -- default true
    local color    = opts.target_color or Blitbuffer.COLOR_BLACK

    local resolve_face = make_face_resolver(face_name, font_px)
    local runs   = parse_runs(text)
    local tokens = tokens_from_runs(runs, resolve_face)
    local lines  = break_lines(tokens, width, resolve_face)
    local lh, ascender = line_metrics(resolve_face, lh_extra)

    local y = top_y
    for _, line in ipairs(lines) do
        if y + lh > top_y + height then break end
        if not line.blank and #line.items > 0 then
            local n_spaces = 0
            for _, it in ipairs(line.items) do
                if it.kind == "space" then n_spaces = n_spaces + 1 end
            end
            local slack = width - line.width
            local extra_per_space = 0
            if justified and not line.last_in_par and n_spaces > 0 and slack > 0 then
                extra_per_space = slack / n_spaces
            end
            local x = left_x
            local baseline = y + ascender
            for _, it in ipairs(line.items) do
                if it.kind == "word" then
                    RenderText:renderUtf8Text(Screen.bb, x, baseline,
                        resolve_face(it.style), it.text, true, false, color, it.w)
                    x = x + it.w
                else
                    x = x + it.w + extra_per_space
                end
            end
        end
        y = y + lh
    end
    return y - top_y  -- total height used
end

return Layout
