local https = require("ssl.https")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socketutil = require("socketutil")
local logger = require("logger")
local Trapper = require("ui/trapper")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local TrapWidget = require("ui/widget/trapwidget")
local _ = require("gettext")

local AI = {}

local SYSTEM_PROMPT_HTML = [[You are a literary translator. You receive a CURRENT page from a book as simplified HTML, plus surrounding PREVIOUS PAGE and NEXT PAGE HTML as context.

Translate the CURRENT page into the target language, with these rules:

1. PRESERVE THE HTML STRUCTURE EXACTLY. Keep every tag (`<p>`, `<h1>`–`<h6>`, `<em>`, `<i>`, `<strong>`, `<b>`, `<u>`, `<small>`, `<sup>`, `<sub>`, `<br>`, `<ul>`, `<ol>`, `<li>`, `<blockquote>`, `<q>`, `<cite>`, `<span>`, `<div>`, `<dl>`, `<dt>`, `<dd>`, `<section>`, `<article>`, `<hr>`) in the same nesting and order as input. Translate only the text content between tags. Do NOT add new tags, do NOT remove tags, do NOT change tag names, do NOT add attributes.

2. PAGE BOUNDARIES ARE NOT WORD BOUNDARIES. CURRENT often starts/ends mid-word or mid-sentence. NEVER output hyphenated half-words like "pokole-racje" or "gene-rations". Reconstruct the full word/sentence from context before translating, then output complete words.

3. Translate every sentence whose primary content lies on CURRENT — including a leading fragment that began on PREVIOUS and a trailing fragment that continues into NEXT. Do NOT translate sentences whose primary content lies on PREVIOUS or NEXT.

4. PAGE-BREAK MARKER. The CURRENT body begins with a single literal pipe character `|` placed just after its first opening tag. In your translation, insert exactly ONE `|` at the SAME logical position in the prose: if the boundary falls inside a sentence, place `|` inside the corresponding translated sentence at the matching word boundary; if the boundary falls at a paragraph/heading start, place `|` at the very start of the translated body (just after the first opening tag). Output exactly ONE `|`. No other `|` characters.

5. Return ONLY the translated HTML body fragment (with the single `|` marker as instructed). No preamble, no quotes, no markdown fences, no notes, no language tags.]]

local SYSTEM_PROMPT = [[You are a literary translator. You receive a CURRENT page from a book plus the surrounding PREVIOUS PAGE and NEXT PAGE as context.

Translate the CURRENT page into the target language, with these rules:

1. PAGE BOUNDARIES ARE NOT WORD BOUNDARIES. The CURRENT page often starts and ends mid-word or mid-sentence. NEVER translate partial words or partial sentences as if they were whole. If the CURRENT page begins with a fragment (e.g. starts with a lowercase letter or a soft-hyphen continuation like "rations" continuing from "gene-" on the previous page), reconstruct the full word/sentence from PREVIOUS PAGE before translating. Same at the end with NEXT PAGE.

2. Translate every sentence whose primary content lies on the CURRENT page — including the leading fragment that started on PREVIOUS PAGE and the trailing fragment that continues on NEXT PAGE. Do this so the output reads as complete words and complete sentences. NEVER output hyphenated half-words like "pokole-racje" or "gene-rations".

3. Do NOT translate sentences whose primary content lies on PREVIOUS or NEXT page. Use those only for context.

4. PRESERVE PARAGRAPH BREAKS. Every paragraph boundary in the input (an empty line, i.e. two consecutive newlines `\n\n`) MUST appear as the same empty line in the output. Output a blank line between paragraphs even when the translation is short. Match the register and prose flow of the source.

5. PAGE-BREAK MARKER. The CURRENT page text begins with a single literal pipe character `|`. This marker shows where the physical page break falls in the source — i.e. the very first word of the CURRENT page in the original. In your translation, insert exactly ONE `|` character at the SAME logical position in the prose: the place that semantically corresponds to where the original page break cut the sentence/paragraph. If the boundary falls inside a sentence, the `|` in your translation must also fall inside the corresponding translated sentence at the matching word boundary. If the boundary falls at a paragraph break (i.e. the CURRENT page starts a fresh paragraph), place the `|` at the very start of your translation, before the first word. Output exactly ONE `|`. No other `|` characters anywhere.

6. MARKDOWN HEADING MARKERS. If a line in the CURRENT page starts with `# ` or `## ` or `### ` etc., that line is a heading. Translate the heading text, but PRESERVE the leading `# ` / `## ` markers EXACTLY as in the input. Do not add new heading markers. Do not remove existing ones. Do not change their level.

7. LIST BULLETS. If a line starts with `• ` (bullet glyph), preserve the bullet — translate only the text after it.

8. INLINE EMPHASIS. The input uses markdown markers `*word*` for italic and `**word**` for bold. PRESERVE these markers EXACTLY around the corresponding translated words/phrases. Do not add new markers. Do not remove existing ones. If a marked span spans multiple words, keep the markers around the whole translated span.

9. Return ONLY the translation (with the single `|` marker, all heading markers, all bullets, and all `*…*` / `**…**` emphasis markers preserved). No preamble, no quotes, no notes, no explanations, no language tags.]]

local function build_user_prompt(current, prev_ctx, next_ctx, target_lang)
    local parts = { "Target language: " .. target_lang .. "\n" }
    if prev_ctx and #prev_ctx > 0 then
        table.insert(parts, "=== PREVIOUS PAGE (context only — do not translate) ===\n" .. prev_ctx .. "\n")
    end
    -- Prepend `|` to mark the page-break point.  See system prompt rule 5.
    table.insert(parts, "=== CURRENT PAGE (translate this) ===\n|" .. current .. "\n")
    if next_ctx and #next_ctx > 0 then
        table.insert(parts, "=== NEXT PAGE (context only — do not translate) ===\n" .. next_ctx .. "\n")
    end
    table.insert(parts, "=== END ===\nReturn ONLY the translation of CURRENT PAGE into " .. target_lang .. ", with exactly ONE `|` marker placed as instructed.")
    return table.concat(parts, "\n")
end

-- HTML variant: same shape, marker injected right after the first opening tag.
local function inject_marker_after_first_tag(html)
    if not html or html == "" then return "|" .. (html or "") end
    local before, tag, rest = html:match("^(.-<[%w][%w]*[^>]*>)()(.*)$")
    if before and rest then
        return before .. "|" .. rest
    end
    return "|" .. html
end

local function build_user_prompt_html(current_html, prev_html, next_html, target_lang)
    local parts = { "Target language: " .. target_lang .. "\n" }
    if prev_html and #prev_html > 0 then
        table.insert(parts, "=== PREVIOUS PAGE HTML (context only — do not translate) ===\n" .. prev_html .. "\n")
    end
    table.insert(parts, "=== CURRENT PAGE HTML (translate this; keep tags) ===\n"
        .. inject_marker_after_first_tag(current_html) .. "\n")
    if next_html and #next_html > 0 then
        table.insert(parts, "=== NEXT PAGE HTML (context only — do not translate) ===\n" .. next_html .. "\n")
    end
    table.insert(parts, "=== END ===\nReturn ONLY the translated HTML body of CURRENT PAGE, preserving all tags and inserting exactly ONE `|` marker as instructed.")
    return table.concat(parts, "\n")
end

-- Synchronous HTTPS POST.  BLOCKS the calling thread until the response
-- arrives or socketutil's timeouts fire — callers on the UI thread must
-- either run this inside Trapper:dismissableRunInSubprocess (interactive
-- paths) or keep the timeouts short (background prefetch).
local function do_request(url, api_key, payload_str, timeout, maxtime)
    local response_body = {}
    socketutil:set_timeout(timeout or 30, maxtime or 60)
    local _r, code, headers, status = https.request{
        url = url,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Authorization"] = "Bearer " .. api_key,
            ["Content-Length"] = tostring(#payload_str),
            ["HTTP-Referer"] = "https://github.com/sypianski/rosetta.koplugin",
            ["X-Title"] = "rosetta",
        },
        source = ltn12.source.string(payload_str),
        sink = ltn12.sink.table(response_body),
    }
    socketutil:reset_timeout()
    return code, table.concat(response_body), status
end

function AI:isConfigured(config)
    return config and config.ai_api_key and #config.ai_api_key > 10
end

function AI:translateHTML(config, current_html, prev_html, next_html, target_lang, on_result, silent)
    if not self:isConfigured(config) then
        on_result(nil, "No AI API key configured. Open Settings → AI API key.")
        return
    end
    local url = config.ai_base_url or "https://openrouter.ai/api/v1/chat/completions"
    local model = config.ai_model or "google/gemini-2.5-flash"
    local key = config.ai_api_key
    local payload = {
        model = model,
        messages = {
            { role = "system", content = SYSTEM_PROMPT_HTML },
            { role = "user",   content = build_user_prompt_html(current_html, prev_html, next_html, target_lang) },
        },
        temperature = config.ai_temperature or 0.3,
        max_tokens = config.ai_max_tokens or 8192,  -- HTML adds overhead
    }
    local payload_str = rapidjson.encode(payload)

    local function run()
        local ok, code, body
        if silent then
            -- Blocking path (no Trapper) — short timeouts, prefetch only.
            ok, code, body = pcall(do_request, url, key, payload_str, 10, 30)
            if not ok then on_result(nil, "Network error: " .. tostring(code)); return end
            ok = true
        else
            local trap = TrapWidget:new{ text = _("Translating (AI)…") }
            UIManager:show(trap)
            ok, code, body = Trapper:dismissableRunInSubprocess(function()
                local c, b = do_request(url, key, payload_str, 45, 120)
                return c, b
            end, trap)
            UIManager:close(trap)
            if not ok then on_result(nil, "Cancelled"); return end
        end
        if not code or code ~= 200 then
            logger.info("rosetta AI HTML: HTTP", tostring(code), "body:", tostring(body):sub(1, 300))
            on_result(nil, "HTTP " .. tostring(code) .. ": " .. tostring(body):sub(1, 200))
            return
        end
        local pok, parsed = pcall(rapidjson.decode, body, {null = nil})
        if not pok or not parsed then on_result(nil, "Invalid JSON response"); return end
        if parsed.error then on_result(nil, "API error: " .. tostring(parsed.error.message or parsed.error)); return end
        local choice = parsed.choices and parsed.choices[1]
        local text = choice and choice.message and choice.message.content
        if not text or text == "" then on_result(nil, "Empty response"); return end
        -- strip leading markdown-fence if model added one
        text = text:gsub("^%s*```html%s*\n?", ""):gsub("\n?```%s*$", "")
        local stripped, is_continuation = self:_parsePipeMarker(text)
        on_result(stripped, nil, is_continuation)
    end

    if silent then
        NetworkMgr:runWhenOnline(run)
    else
        NetworkMgr:runWhenOnline(function() Trapper:wrap(run) end)
    end
end

function AI:translate(config, current, prev_ctx, next_ctx, target_lang, on_result, silent)
    if not self:isConfigured(config) then
        on_result(nil, "No AI API key configured. Open Settings → AI API key.")
        return
    end

    local url = config.ai_base_url or "https://openrouter.ai/api/v1/chat/completions"
    local model = config.ai_model or "google/gemini-2.5-flash"
    local key = config.ai_api_key

    local payload = {
        model = model,
        messages = {
            { role = "system", content = SYSTEM_PROMPT },
            { role = "user",   content = build_user_prompt(current, prev_ctx, next_ctx, target_lang) },
        },
        temperature = config.ai_temperature or 0.3,
        max_tokens = config.ai_max_tokens or 4096,
    }
    local payload_str = rapidjson.encode(payload)

    local function run()
        local ok, code, body
        if silent then
            -- Background prefetch: synchronous HTTP, no popup, no Trapper.
            -- WARNING: this DOES block the UI thread for the duration of the
            -- request (socket.http does NOT yield to the UI loop) — that's
            -- why we keep the socketutil timeouts short here and only use
            -- this path for prefetch, never for interactive translations.
            ok, code, body = pcall(do_request, url, key, payload_str, 10, 30)
            if not ok then
                on_result(nil, "Network error: " .. tostring(code))
                return
            end
            -- pcall returns (true, code, body) on success: realign.
            ok = true
        else
            local trap = TrapWidget:new{ text = _("Translating (AI)…") }
            UIManager:show(trap)
            ok, code, body = Trapper:dismissableRunInSubprocess(function()
                local c, b = do_request(url, key, payload_str, 45, 120)
                return c, b
            end, trap)
            UIManager:close(trap)
            if not ok then
                on_result(nil, "Cancelled")
                return
            end
        end
        if not code or code ~= 200 then
            logger.info("rosetta AI: HTTP", tostring(code), "body:", tostring(body):sub(1, 300))
            on_result(nil, "HTTP " .. tostring(code) .. ": " .. tostring(body):sub(1, 200))
            return
        end
        local pok, parsed = pcall(rapidjson.decode, body, {null = nil})
        if not pok or not parsed then
            on_result(nil, "Invalid JSON response")
            return
        end
        if parsed.error then
            on_result(nil, "API error: " .. tostring(parsed.error.message or parsed.error))
            return
        end
        local choice = parsed.choices and parsed.choices[1]
        local text = choice and choice.message and choice.message.content
        if not text or text == "" then
            on_result(nil, "Empty response")
            return
        end
        -- Parse the `|` marker (rule 5).  is_continuation = true iff the
        -- marker is preceded by non-whitespace prose (i.e. the page break
        -- falls inside a paragraph, not at its start).
        local stripped, is_continuation = self:_parsePipeMarker(text)
        on_result(stripped, nil, is_continuation)
    end

    if silent then
        -- runWhenOnline still works fine in silent mode (no UI shown)
        NetworkMgr:runWhenOnline(run)
    else
        NetworkMgr:runWhenOnline(function() Trapper:wrap(run) end)
    end
end

-- Heuristic: a translation that starts with a lowercase letter is almost
-- certainly a continuation of the previous page's paragraph (proper sentences
-- start capitalised in Polish/Italian/English/German/French/etc).
local function _starts_lowercase(text)
    if not text or text == "" then return false end
    -- strip leading whitespace + markdown markers (`*`, `#`, `•`, `>` etc.)
    -- so the heuristic sees the first actual letter, not a marker.
    local stripped = text:gsub("^[%s*#%•%>%-_`'\"]+", "")
    local first = stripped:match("^([%w])")
    if not first then return false end
    return first == first:lower() and first ~= first:upper()
end

function AI:_parsePipeMarker(text)
    if not text then return text, false end
    local pos = text:find("|", 1, true)
    local joined, marker_says_continuation
    if not pos then
        -- model forgot the marker → use only the lowercase heuristic
        joined = text
        marker_says_continuation = false
    else
        local before = text:sub(1, pos - 1)
        local after  = text:sub(pos + 1)
        local trimmed_before = before:gsub("%s+$", "")
        local has_prose_before = trimmed_before:match("%S") ~= nil
        marker_says_continuation = has_prose_before
        if marker_says_continuation then
            local lead = after:match("^%s*") or ""
            local rest = after:sub(#lead + 1)
            local sep = " "
            if trimmed_before:match("%-$") then sep = "" end
            joined = trimmed_before .. sep .. rest
        else
            joined = (after:gsub("^%s+", ""))
        end
        joined = joined:gsub("|", "")
    end
    -- Fallback heuristic: lowercase-start → continuation, even if marker said
    -- otherwise.  The model often ignores rule 5 but cannot lie about case.
    local is_continuation = marker_says_continuation or _starts_lowercase(joined)
    return joined, is_continuation
end

-- ---------------------------------------------------------------------------
-- AI:matchAligned — aligned-mode AI fill-in (page-boundary locator).
--
-- Contract (kept in sync with the call site in
-- main.lua:translateCurrentPageAligned):
--   page_text   — STRING: source-language plain text of the current page.
--   corpus_text — STRING: continuous target-language excerpt from the same
--                 book (paragraphs joined with "\n\n").  The caller windows
--                 it (±N paragraphs) around the most likely position; we
--                 additionally clamp it to MATCH_MAX_CORPUS_CHARS before
--                 prompting.  Clamping only affects the prompt: quotes the
--                 model returns are verbatim substrings of the clamped text
--                 and therefore also of the full corpus_text.
--   on_result(phr, err):
--       phr = { first = <string>, last = <string> } — two short VERBATIM
--         quotes from corpus_text: `first` opens the corpus fragment that
--         corresponds to the page, `last` closes it.  The caller locates
--         them with corpus_text:find(phr.first, 1, true) and
--         corpus_text:find(phr.last, s, true) and slices between them.
--       phr = nil, err = nil — model reported "no match"; caller falls back
--         to the hash-only render.
--       phr = nil, err = <string> — transport/parse error; same fallback.
--   silent — true: synchronous request with short timeouts (blocks UI
--         briefly; only for background use).  false: runs inside
--         Trapper:dismissableRunInSubprocess with a dismissable TrapWidget
--         (tap to cancel → on_result(nil, "Cancelled")).
-- ---------------------------------------------------------------------------
local MATCH_SYSTEM_PROMPT = [[
You are a bilingual page-boundary locator.

You receive:
  - SOURCE PAGE: the source-language text physically on the current page of a book.
  - TRANSLATION CORPUS: a continuous target-language excerpt from the same book covering the nearby region.

Identify the contiguous fragment of TRANSLATION CORPUS that corresponds to the SOURCE PAGE content.

Return two short VERBATIM quotes copied character-for-character from TRANSLATION CORPUS:
  - "first": the first 3-8 words of that fragment (where the page's content begins in the corpus).
  - "last":  the last 3-8 words of that fragment (where the page's content ends in the corpus).

Rules:
  - Copy each quote EXACTLY as it appears in TRANSLATION CORPUS — same characters, same punctuation, same case. Do not translate, do not paraphrase, do not normalise quotes or dashes.
  - "first" must occur in the corpus at or before the position of "last".
  - If no part of the corpus corresponds to the source page, return {"first": "", "last": ""}.

Output ONLY a single JSON object: {"first": "...", "last": "..."}. No prose before or after.
]]

local MATCH_MAX_CORPUS_CHARS = 24000
local MATCH_MAX_PAGE_CHARS   = 6000

-- Clamp the corpus excerpt for the prompt.  Keeps the MIDDLE of the text
-- (the caller centres its paragraph window on the last known anchor), and
-- snaps both cut points inward to paragraph boundaries ("\n\n") so the model
-- only ever sees whole paragraphs.  The result is always a verbatim
-- substring of `corpus`.
function AI:_clampCorpusForMatch(corpus, max_chars)
    max_chars = max_chars or MATCH_MAX_CORPUS_CHARS
    if #corpus <= max_chars then return corpus end
    local excess = #corpus - max_chars
    local s = 1 + math.floor(excess / 2)
    local e = s + max_chars - 1
    -- snap start forward to the next paragraph boundary
    local ps = corpus:find("\n\n", s, true)
    if ps and ps + 2 <= e then s = ps + 2 end
    -- snap end backward to the last paragraph boundary within [s, e]
    local last_sep
    local from = s
    while true do
        local f = corpus:find("\n\n", from, true)
        if not f or f > e then break end
        last_sep = f
        from = f + 1
    end
    if last_sep and last_sep > s then e = last_sep - 1 end
    return corpus:sub(s, e)
end

-- Clamp the page text for the prompt.  The page EDGES are what define the
-- first/last quotes, so keep head + tail and elide the middle.
function AI:_clampPageForMatch(page_text, max_chars)
    max_chars = max_chars or MATCH_MAX_PAGE_CHARS
    if #page_text <= max_chars then return page_text end
    local half = math.floor((max_chars - 7) / 2)  -- 7 = #"\n[…]\n"
    return page_text:sub(1, half) .. "\n[…]\n" .. page_text:sub(-half)
end

-- Parse the raw HTTP response body of a matchAligned request.
-- Returns (phr, nil) on success, (nil, nil) when the model reports no
-- match (empty strings), (nil, err) on any transport/format problem.
function AI:_parseMatchResponse(body)
    local pok, parsed = pcall(rapidjson.decode, body, { null = nil })
    if not pok or type(parsed) ~= "table" then
        return nil, "Invalid JSON response"
    end
    if parsed.error then
        return nil, "API error: " .. tostring(parsed.error.message or parsed.error)
    end
    local choice = parsed.choices and parsed.choices[1]
    local text = choice and choice.message and choice.message.content
    if type(text) ~= "string" or text == "" then
        return nil, "Empty response"
    end
    -- Strip code fences just in case.
    text = text:gsub("^%s*```%w*%s*", ""):gsub("%s*```%s*$", "")
    local mok, mapped = pcall(rapidjson.decode, text, { null = nil })
    if not mok or type(mapped) ~= "table" then
        return nil, "Bad JSON from model: " .. text:sub(1, 200)
    end
    local first, last = mapped.first, mapped.last
    if type(first) ~= "string" or type(last) ~= "string" then
        return nil, "Bad phrase pair from model: " .. text:sub(1, 200)
    end
    first = first:gsub("^%s+", ""):gsub("%s+$", "")
    last  = last:gsub("^%s+", ""):gsub("%s+$", "")
    if first == "" or last == "" then
        return nil  -- explicit "no match" from the model — not an error
    end
    return { first = first, last = last }
end

function AI:matchAligned(config, page_text, corpus_text, target_lang, on_result, silent)
    if not self:isConfigured(config) then
        on_result(nil, "No AI API key configured.")
        return
    end
    if type(page_text) ~= "string" or page_text == ""
       or type(corpus_text) ~= "string" or corpus_text == "" then
        on_result(nil); return
    end
    local user_prompt = table.concat({
        "SOURCE PAGE (source language):",
        self:_clampPageForMatch(page_text),
        "",
        "TRANSLATION CORPUS (" .. tostring(target_lang or "??") .. "):",
        self:_clampCorpusForMatch(corpus_text),
        "",
        "Return the two verbatim corpus quotes bracketing the fragment that corresponds to the SOURCE PAGE.",
        'Output ONLY: {"first": "...", "last": "..."}',
    }, "\n")

    local url = config.ai_base_url or "https://openrouter.ai/api/v1/chat/completions"
    local model = config.ai_model or "google/gemini-2.5-flash"
    local key = config.ai_api_key
    local payload = {
        model = model,
        messages = {
            { role = "system", content = MATCH_SYSTEM_PROMPT },
            { role = "user",   content = user_prompt },
        },
        temperature = 0.1,
        max_tokens = 1024,  -- response is two short quotes
        response_format = { type = "json_object" },
    }
    local payload_str = rapidjson.encode(payload)

    local function handle(code, body)
        if not code or code ~= 200 then
            on_result(nil, "HTTP " .. tostring(code) .. ": " .. tostring(body):sub(1, 200))
            return
        end
        local phr, perr = self:_parseMatchResponse(body)
        on_result(phr, perr)
    end

    local function run()
        if silent then
            -- Blocking path — short timeouts only.
            local ok, code, body = pcall(do_request, url, key, payload_str, 10, 30)
            if not ok then on_result(nil, "Network error: " .. tostring(code)); return end
            handle(code, body)
        else
            local trap = TrapWidget:new{ text = _("Matching translation (AI)…") }
            UIManager:show(trap)
            local completed, code, body = Trapper:dismissableRunInSubprocess(function()
                local c, b = do_request(url, key, payload_str, 45, 120)
                return c, b
            end, trap)
            UIManager:close(trap)
            if not completed then on_result(nil, "Cancelled"); return end
            handle(code, body)
        end
    end

    if silent then
        NetworkMgr:runWhenOnline(run)
    else
        NetworkMgr:runWhenOnline(function() Trapper:wrap(run) end)
    end
end

return AI
