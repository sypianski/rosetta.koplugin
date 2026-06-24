local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Screen = require("device").screen
local Event = require("ui/event")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")

local Config = require("rosetta_config")
local Translator = require("rosetta_translator")
local AI = require("rosetta_ai")
local Cache = require("rosetta_cache")
local Extract = require("rosetta_extract")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local Layout = require("rosetta_layout")
local Aligned = require("rosetta_aligned")
local UI = require("ui_rosetta")

local rosetta = InputContainer:extend{
    name = "rosetta",
    is_doc_only = true,
    panel_text = "",
    panel_height = 0,
    config = nil,
    is_initialized = false, 
}

function rosetta:init()
    self.ui.menu:registerToMainMenu(self)
    local ok, config = pcall(function() return Config:load() end)
    self.config = ok and config or {
        source_lang = "auto",
        target_lang = "en",
        panel_height_ratio = 0.50,
        auto_translate = true,
        font_size = 14,
    }
    self.panel_height = math.floor(Screen:getHeight() * self.config.panel_height_ratio)

    -- Best-effort: pre-load the crengine hyphenation dictionary for the
    -- target language so TextBoxWidget's xtext can break long words.  xtext
    -- ought to lazy-load on first xtext.new(...,lang) but the call is silent
    -- if the dict isn't already registered.
    pcall(function()
        local cre = require("libs/libkoreader-cre")
        if cre and cre.initHyphDict then cre.initHyphDict("./data/hyph/") end
    end)
    -- Diagnostic mode: clear the translation cache on every KOReader start
    -- so each session translates fresh.  Toggle via config.
    if self.config and self.config.clear_cache_on_start then
        Cache:clearAll()
    end
    logger.info("rosetta: init, panel_height:", self.panel_height)
end

function rosetta:getFooterHeight()
    if self.view and self.view.footer and self.view.footer_visible then
        return self.view.footer:getHeight()
    end
    return 0
end

function rosetta:getBookKey()
    if self.ui and self.ui.document and self.ui.document.file then
        return "book_" .. self.ui.document.file:gsub("[^%w]", "_")
    end
    return nil
end

function rosetta:_settings()
    local LuaSettings = require("luasettings")
    local DataStorage = require("datastorage")
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/rosetta.lua")
end

-- Tri-state per-book toggle:
--   explicit true  -> always on
--   explicit false -> always off (user opted out)
--   nil (never touched) -> AUTO: on iff <book>.sdr/rosetta-aligned.json exists
function rosetta:isEnabledForBook()
    local key = self:getBookKey()
    if not key then return false end
    local s = self:_settings()
    local stored = s:readSetting(key)
    if stored == true then return true end
    if stored == false then return false end
    -- nil — auto-detect anchor file presence
    if self.ui and self.ui.document and self.ui.document.file then
        local Aligned = require("rosetta_aligned")
        local path = Aligned:_existingPathFor(self.ui.document.file)
        if path then
            logger.info("rosetta: auto-enabled via anchor file at", path)
            -- Auto-switch backend to 'aligned' so the panel reads from the
            -- EPUB-derived JSON instead of going out to Google / AI.
            -- Only flip if the user hasn't explicitly chosen a backend
            -- (i.e. config is still on its default "google").
            if self.config and self.config.backend == "google" then
                self.config.backend = "aligned"
                local Config = require("rosetta_config")
                if Config.save then Config:save(self.config) end
                logger.info("rosetta: backend auto-switched to 'aligned'")
            end
            return true
        end
    end
    return false
end

function rosetta:setEnabledForBook(enabled)
    local key = self:getBookKey()
    if not key then return end
    local s = self:_settings()
    s:saveSetting(key, enabled)
    s:flush()
    logger.info("rosetta: book enabled state saved:", enabled, "key:", key)
end

function rosetta:onReaderReady()
    logger.info("rosetta: onReaderReady called, enabled:", self:isEnabledForBook(), "initialized:", self.is_initialized)
    if not self:isEnabledForBook() then
        logger.info("rosetta: disabled for this book")
        return
    end
    if self.is_initialized then
        logger.info("rosetta: already initialized, skipping")
        return
    end
    self.is_initialized = true
    logger.info("rosetta: initializing...")
    self.panel_text = ""
    self:shrinkReadingArea()
    UIManager:scheduleIn(0.5, function() self:refreshPanel() end)
    local orig_paintTo = self.view.paintTo
    self.view.paintTo = function(view, bb, x, y)
        orig_paintTo(view, bb, x, y)
        self:refreshPanel()
    end
    -- Kick off a translation for the current page immediately so the panel
    -- isn't blank until the user turns a page.
    UIManager:scheduleIn(0.6, function() self:translateCurrentPage() end)
end

function rosetta:shrinkReadingArea()
    local footer_h = self:getFooterHeight()
    local screen_h = Screen:getHeight()
    local new_h = screen_h - self.panel_height - footer_h
    self.view.dimen.h = new_h
    self.ui.dimen.h = new_h
    local margins = self.ui.document:getPageMargins()
    self.original_bottom_margin = margins.bottom or margins[4] or 20
    self.ui:handleEvent(Event:new("SetPageMargins", {
        margins.left,
        margins.top,
        margins.right,
        2,
    }))
    logger.info("rosetta: set bottom margin to 2")
    self.ui:handleEvent(Event:new("SetDimensions", self.ui.dimen))
end

function rosetta:flattenText(t)
    if type(t) == "string" then return t end
    local words = {}
    for _, item in ipairs(t) do
        if type(item) == "table" and item.word then
            table.insert(words, item.word)
        elseif type(item) == "string" then
            table.insert(words, item)
        end
    end
    return table.concat(words, " ")
end

function rosetta:getTextForPage(page)
    -- Prefer the HTML-aware extractor: gives us heading markdown (`# `, `## `)
    -- and list bullets in the text we send to AI / render.  Falls back to the
    -- old plain xpointer text if extract fails.
    local doc = self.ui.document
    local body = Extract:forPage(doc, page)
    if body and body ~= "" then
        local titled = Extract:toTitledPlainText(body)
        if titled and titled ~= "" then return titled end
    end
    local ok, text = pcall(function()
        local pos0 = doc:getPageXPointer(page)
        local pos1 = doc:getPageXPointer(page + 1)
        return doc:getTextFromXPointers(pos0, pos1, false)
    end)
    if not ok or not text then return nil end
    return self:flattenText(text)
end

function rosetta:translateCurrentPage()
    local doc = self.ui.document
    local current_page = doc:getCurrentPage()

    local current = self:getTextForPage(current_page)
    if not current or #current == 0 then
        self.panel_text = "No text found."
        self:refreshPanel()
        return
    end

    if self.config.backend == "aligned" then
        return self:translateCurrentPageAligned(current_page, current)
    end

    if self.config.backend == "ai" then
        return self:translateCurrentPageAI(current_page, current)
    end

    -- google branch
    if not Translator:isNetworkAvailable() then
        self.panel_text = "No internet connection."
        self:refreshPanel()
        return
    end

    local book_key = self:getBookKey()
    local lang = self.config.target_lang or "en"
    local content_hash = Cache:keyFor(current)
    local cached = content_hash and Cache:get(book_key, content_hash, lang, "google")
    if cached then
        self.panel_text = cached
        self:refreshPanel()
        return
    end

    local prev_tail = ""
    if current_page > 1 then
        local prev = self:getTextForPage(current_page - 1)
        if prev and #prev > 0 then
            local last_dot = 0
            for i = #prev, 1, -1 do
                local c = prev:sub(i, i)
                if c == "." or c == "!" or c == "?" then
                    last_dot = i
                    break
                end
            end
            if last_dot > 0 and last_dot < #prev then
                prev_tail = prev:sub(last_dot + 1):gsub("^%s+", "")
            end
        end
    end

    local next_head = ""
    local next_text = self:getTextForPage(current_page + 1)
    if next_text and #next_text > 0 then
        local first_dot = 0
        for i = 1, #next_text do
            local c = next_text:sub(i, i)
            if c == "." or c == "!" or c == "?" then
                first_dot = i
                break
            end
        end
        if first_dot > 0 then
            next_head = next_text:sub(1, first_dot)
        end
    end

    local first_cap = current:find("[A-ZÄÖÜ]")
    local clean_current = current
    if first_cap and first_cap > 1 then
        local incomplete_start = current:sub(1, first_cap - 1):gsub("^%s+", "")
        clean_current = current:sub(first_cap)
        if #prev_tail > 0 then
            prev_tail = prev_tail .. incomplete_start
        end
    else
        prev_tail = ""
    end

    local last_dot = 0
    for i = #clean_current, 1, -1 do
        local c = clean_current:sub(i, i)
        if c == "." or c == "!" or c == "?" then
            last_dot = i
            break
        end
    end

    local incomplete_end = ""
    if last_dot > 0 and last_dot < #clean_current then
        incomplete_end = clean_current:sub(last_dot + 1):gsub("^%s+", "")
        clean_current = clean_current:sub(1, last_dot)
    end

    -- Join helpers — collapse "word-\n  rations" page-break hyphenation into
    -- the single underlying word ("words") before sending to the translator,
    -- so we don't get "pokole-racje" out of "gene-rations".
    local function smart_join(a, b)
        if not a or a == "" then return b or "" end
        if not b or b == "" then return a end
        -- if a ends with "<letter>-" and b starts with "<lowercase letter>",
        -- treat the hyphen as a soft-wrap break and join without it.
        if a:match("[%w]%-$") and b:match("^[%l]") then
            return a:sub(1, -2) .. b
        end
        return a .. " " .. b
    end

    local parts = {}
    if #prev_tail > 0 then table.insert(parts, prev_tail) end
    if #clean_current > 0 then table.insert(parts, clean_current) end
    local tail
    if #incomplete_end > 0 and #next_head > 0 then
        tail = smart_join(incomplete_end, next_head)
    elseif #incomplete_end > 0 then
        tail = incomplete_end
    end

    -- Apply smart_join across all adjacent parts so a page-break hyphen at
    -- prev/current or current/next boundary is collapsed.
    local final_text = ""
    for _, p in ipairs(parts) do
        final_text = smart_join(final_text, p)
    end
    if tail then final_text = smart_join(final_text, tail) end
    if #final_text == 0 then
        self.panel_text = "No complete sentences found."
        self:refreshPanel()
        return
    end

    self.panel_text = "Translating..."
    self:refreshPanel()

    local translated, err = Translator:translate(
        final_text,
        self.config.source_lang,
        self.config.target_lang
    )

    if err then
        self.panel_text = "Error: " .. err
    else
        self.panel_text = translated or "Empty translation."
        if translated and #translated > 0 then
            local h = Cache:keyFor(current)
            if h then
                Cache:put(self:getBookKey(), h,
                          self.config.target_lang or "en", "google", translated)
            end
        end
    end

    self:refreshPanel()
end

-- Backend: aligned-only. Pure paraligilo anchor lookup, no AI / Google
-- fallback. Used when the user has chosen the EPUB-translation source.
function rosetta:translateCurrentPageAligned(page, current)
    local book_file = self.ui and self.ui.document and self.ui.document.file
    if not book_file then
        self.panel_text = "No book open."
        self:refreshPanel(); return
    end
    -- Pure aligned-only flow: drop missing paragraphs rather than echoing
    -- the Polish source into the panel (the previous behavior was meant for
    -- the AI-fallback flow where a later step would translate the misses).
    local MISS_MARKER = "_[…]_"
    local aligned, hits, misses = Aligned:lookupBlock(book_file, current,
        self.config.anchor_min_confidence, MISS_MARKER)
    if aligned and hits > 0 then
        if misses > 0 then
            self.panel_text = aligned ..
                "\n\n_[" .. misses .. " paragraph(s) without alignment — switch backend to Google/AI to fill them in]_"
        else
            self.panel_text = aligned
        end
    else
        self.panel_text = "No aligned translation for this page.\n\n" ..
            "Switch the backend back to Google or AI to fall back to live translation."
    end
    self:refreshPanel()
end

-- Bump this when the AI prompt changes, to invalidate stale cached translations.
local AI_PROMPT_VERSION = "v7"

function rosetta:_aiKey()
    local model = (self.config.ai_model or "x") .. "+" .. AI_PROMPT_VERSION
    return self:getBookKey(), self.config.target_lang or "en", model
end

function rosetta:_translatePageAI(page, on_done, is_prefetch)
    if self.config.formatting_mode == "html" then
        return self:_translatePageAIHTML(page, on_done, is_prefetch)
    end

    local current = self:getTextForPage(page)
    if not current or #current == 0 then
        if on_done then on_done(nil, "no text") end
        return
    end

    -- Anchor pass: if a paraligilo file exists in the book's .sdr/ and covers
    -- every paragraph on this page, skip the AI call entirely.
    local book_file = self.ui and self.ui.document and self.ui.document.file
    if book_file then
        local aligned, hits, misses = Aligned:lookupBlock(book_file, current,
            self.config.anchor_min_confidence)
        if aligned and hits > 0 and misses == 0 then
            logger.info("rosetta: page", page, "fully covered by anchors (", hits, "paragraphs)")
            if on_done then
                on_done(aligned, nil, self:_isPageStartContinuationFromSource(page))
            end
            return
        elseif aligned and hits > 0 then
            logger.info("rosetta: page", page, "partial anchor coverage", hits, "/", hits + misses,
                "— falling back to AI for misses (not yet implemented, doing full AI)")
        end
    end

    local book_key, lang, model = self:_aiKey()
    local content_hash = Cache:keyFor(current)
    local cached = content_hash and Cache:get(book_key, content_hash, lang, model)
    if cached then
        local flag = cached:sub(1, 1)
        local body = cached:sub(2)
        if flag ~= "C" and flag ~= "N" then
            body = cached
            flag = "N"
        end
        local is_continuation = (flag == "C")
        -- lowercase-start fallback: even if the cached flag says "N", treat as
        -- continuation when the translation begins with a lowercase letter.
        if not is_continuation then
            local stripped = body:gsub("^[%s*#%•%>%-_`'\"]+", "")
            local first = stripped:match("^([%w])")
            if first and first == first:lower() and first ~= first:upper() then
                is_continuation = true
            end
        end
        if on_done then on_done(body, nil, is_continuation) end
        return
    end

    local prev_ctx = ""
    if page > 1 then prev_ctx = self:getTextForPage(page - 1) or "" end
    local next_ctx = self:getTextForPage(page + 1) or ""

    -- Collapse page-break soft hyphenation at the boundaries BEFORE sending to
    -- the model.  AI prompts alone can't reliably handle "Eu-" + "ropa"; if we
    -- merge the split word into one chunk and move it whole into `current`, the
    -- model has no way to bisect the translation.
    --
    -- Rules (only at chunk boundaries, never mid-text):
    --   * prev ends with "<letter>-" and current starts with "<lowercase>" →
    --     take leading-fragment-up-to-first-whitespace from current, append to
    --     prev's trailing word minus the hyphen, then strip that fragment from
    --     `current`.
    --   * current ends with "<letter>-" and next starts with "<lowercase>" →
    --     take leading-fragment from next, append to current minus the hyphen,
    --     strip that fragment from `next_ctx`.
    local function strip_soft_hyphen_join(left, right)
        if not left or not right or left == "" or right == "" then
            return left, right
        end
        local lead = left:match("([%w])%-%s*$")
        local follow = right:match("^([%l])")
        if not lead or not follow then return left, right end
        local frag, rest = right:match("^(%S+)(.*)$")
        if not frag then return left, right end
        -- absorb fragment into left's trailing word, drop hyphen + whitespace
        local new_left = left:gsub("([%w])%-%s*$", "%1" .. frag, 1)
        local new_right = rest:gsub("^%s+", "")
        return new_left, new_right
    end

    prev_ctx, current = strip_soft_hyphen_join(prev_ctx, current)
    current, next_ctx = strip_soft_hyphen_join(current, next_ctx)

    if not is_prefetch then
        self.panel_loading = true
        self:refreshPanel()
    end

    AI:translate(self.config, current, prev_ctx, next_ctx, lang, function(translated, err, is_continuation)
        if translated and not err and content_hash then
            local flag = is_continuation and "C" or "N"
            Cache:put(book_key, content_hash, lang, model, flag .. translated)
        end
        if on_done then on_done(translated, err, is_continuation) end
    end, true)  -- silent=true always; in-panel "Translating…" indicator replaces popup
end

function rosetta:translateCurrentPageAI(current_page, _current)
    if not AI:isConfigured(self.config) then
        self.panel_text = "No AI API key. Settings → AI API key."
        self:refreshPanel()
        return
    end

    local req_page = current_page
    self:_translatePageAI(current_page, function(translated, err, is_continuation)
        local now_page = self.ui.document:getCurrentPage()
        if now_page == req_page then
            self.panel_loading = false
            if err then
                self.panel_text = "AI error: " .. err
                self.panel_continuation = false
            else
                self.panel_text = translated or "Empty translation."
                -- Combine AI's marker/heuristic with a source-side check:
                -- prev-page tail tells us deterministically whether this
                -- page starts mid-paragraph.
                local src_cont = self:_isPageStartContinuationFromSource(req_page)
                self.panel_continuation = (is_continuation == true) or src_cont
            end
            self:refreshPanel()
        end
        -- prefetch next page regardless of stale-current
        self:_prefetchNextAI(current_page + 1)
    end, false)
end

function rosetta:_translatePageAIHTML(page, on_done, is_prefetch)
    local doc = self.ui.document
    local current_html = Extract:forPage(doc, page)
    if not current_html or current_html == "" then
        if on_done then on_done(nil, "no html") end
        return
    end
    local book_key, lang, model = self:_aiKey()
    -- separate model slug for html so caches don't collide
    model = model .. "+html"
    local content_hash = Cache:keyFor(current_html)
    local cached = content_hash and Cache:get(book_key, content_hash, lang, model)
    if cached then
        local flag = cached:sub(1, 1)
        local body = cached:sub(2)
        if flag ~= "C" and flag ~= "N" then
            body = cached; flag = "N"
        end
        if on_done then on_done(body, nil, flag == "C") end
        return
    end

    local prev_html = ""
    if page > 1 then prev_html = Extract:forPage(doc, page - 1) or "" end
    local next_html = Extract:forPage(doc, page + 1) or ""

    if not is_prefetch then
        self.panel_loading = true
        self:refreshPanel()
    end

    AI:translateHTML(self.config, current_html, prev_html, next_html, lang,
        function(translated, err, is_continuation)
            if translated and not err and content_hash then
                local flag = is_continuation and "C" or "N"
                Cache:put(book_key, content_hash, lang, model, flag .. translated)
            end
            if on_done then on_done(translated, err, is_continuation) end
        end, true)
end

function rosetta:_prefetchNextAI(page)
    if not self.config or self.config.backend ~= "ai" then return end
    if not AI:isConfigured(self.config) then return end
    local book_key, lang, model = self:_aiKey()
    local text = self:getTextForPage(page)
    local h = text and Cache:keyFor(text)
    if h and Cache:get(book_key, h, lang, model) then return end
    -- yield to UI before firing prefetch
    UIManager:scheduleIn(0.2, function()
        self:_translatePageAI(page, function(_t, _e) end, true)
    end)
end

function rosetta:_cancelPendingTranslate()
    if self._translate_timer then
        UIManager:unschedule(self._translate_timer)
        self._translate_timer = nil
    end
end

function rosetta:_scheduleTranslate(delay)
    self:_cancelPendingTranslate()
    self._translate_pending_page = self.ui.document:getCurrentPage()
    local function trigger()
        self._translate_timer = nil
        -- Only fire if user is still on the same page (didn't keep flipping)
        local now_page = self.ui.document:getCurrentPage()
        if now_page == self._translate_pending_page then
            self:translateCurrentPage()
        end
    end
    self._translate_timer = trigger
    UIManager:scheduleIn(delay, trigger)
end

function rosetta:onPageUpdate(pageno)
    if not self:isEnabledForBook() then return end
    if not self.config.auto_translate then return end
    self:_scheduleTranslate(0.5)
end

function rosetta:onPosUpdate(pos, pageno)
    if not self:isEnabledForBook() then return end
    if not self.config.auto_translate then return end
    self:_scheduleTranslate(0.5)
end

function rosetta:getPanelGearRegion()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local footer_h = self:getFooterHeight()
    local icon_size = Screen:scaleByDPI(32)
    local margin = Screen:scaleByDPI(8)
    return {
        x = screen_w - icon_size - margin,
        y = screen_h - footer_h - icon_size - margin,
        w = icon_size,
        h = icon_size,
    }
end

function rosetta:showSettingsDialog()
    if not self.config then
        self.config = Config:load()
    end
    UI._book_file = self.ui and self.ui.document and self.ui.document.file or nil
    UI:showSettingsDialog(self.config, Config,
        function()
            self:refreshPanel()
        end,
        function(new_ratio)
        end
    )
end

function rosetta:_bookFace()
    -- Match the book's current font face for the panel; size = book font px
    -- scaled by config.font_size_percent (default 100%).  Falls back to
    -- config.font_size when the book's px size can't be discovered.
    local book_size_px
    local face_name
    local ok = pcall(function()
        local rf = self.ui and self.ui.font
        if rf then
            face_name = rf.font_face
            local cfg_size = rf.configurable and rf.configurable.font_size
            if cfg_size then book_size_px = Screen:scaleBySize(cfg_size) end
        end
    end)
    -- explicit override wins
    if self.config.font_override and self.config.font_override ~= "" then
        face_name = self.config.font_override
    end
    local percent = tonumber(self.config.font_size_percent) or 100
    if percent < 30 then percent = 30 end
    if percent > 300 then percent = 300 end
    local size_px
    if ok and book_size_px and book_size_px >= 8 then
        size_px = math.floor(book_size_px * percent / 100 + 0.5)
    else
        -- fallback: scale the static config.font_size by percent too
        size_px = math.floor(Screen:scaleBySize(self.config.font_size or 14) * percent / 100 + 0.5)
    end
    if size_px < 8 then size_px = 8 end
    logger.info("rosetta: book face name =", tostring(face_name), "size_px =", size_px)
    if face_name then
        local cre_ok, cre = pcall(require, "libs/libkoreader-cre")
        if cre_ok and cre and cre.getFontFaceFilenameAndFaceIndex then
            local fok, fn, fi = pcall(cre.getFontFaceFilenameAndFaceIndex, face_name)
            logger.info("rosetta: cre filename =", tostring(fn), "idx =", tostring(fi), "ok =", tostring(fok))
            if fok and fn then
                local face = Font:getFace(fn, size_px, fi)
                if face then return face, size_px end
            end
        else
            logger.info("rosetta: cre module not loadable:", tostring(cre))
        end
        local face = Font:getFace(face_name, size_px)
        if face then return face, size_px end
    end
    return Font:getFace("cfont", size_px), size_px
end

function rosetta:_bookLineHeight()
    -- Map book's interline-space-percent (e.g. 130 → 30% extra) to
    -- TextBoxWidget.line_height which is "extra height in em" (0.3 == 30%).
    local pct
    -- explicit user override beats book-derived value
    local ov = tonumber(self.config.line_spacing_override) or 0
    if ov >= 50 and ov <= 300 then
        pct = ov
    else
        pcall(function()
            local rf = self.ui and self.ui.font
            if rf and rf.configurable then pct = rf.configurable.line_spacing end
            if (not pct) and self.ui and self.ui.doc_settings then
                pct = self.ui.doc_settings:readSetting("copt_line_spacing")
            end
            if (not pct) and _G.G_reader_settings then
                pct = G_reader_settings:readSetting("copt_line_spacing")
            end
        end)
    end
    logger.info("rosetta: book line_spacing pct =", tostring(pct))
    if not pct or pct < 50 or pct > 300 then pct = 130 end
    -- crengine interline-space-percent = TOTAL line height as % of font height
    -- (100 = no leading).  TextBoxWidget.line_height = EXTRA em on top of
    -- face.size.  Conversion: extra = pct/100 - 1.
    local extra = pct / 100 - 1
    if extra < 0 then extra = 0 end
    if extra > 1.5 then extra = 1.5 end
    return extra
end

function rosetta:_bookFaceAtPx(px)
    if px < 8 then px = 8 end
    local face_name
    pcall(function()
        local rf = self.ui and self.ui.font
        if rf then face_name = rf.font_face end
    end)
    if self.config.font_override and self.config.font_override ~= "" then
        face_name = self.config.font_override
    end
    if face_name then
        local cre_ok, cre = pcall(require, "libs/libkoreader-cre")
        if cre_ok and cre and cre.getFontFaceFilenameAndFaceIndex then
            local fok, fn, fi = pcall(cre.getFontFaceFilenameAndFaceIndex, face_name)
            if fok and fn then
                local f = Font:getFace(fn, px, fi)
                if f then return f end
            end
        end
        local f = Font:getFace(face_name, px)
        if f then return f end
    end
    return Font:getFace("cfont", px)
end

function rosetta:_bookMargins()
    local m = { left = 20, top = 20, right = 20, bottom = 20 }
    local ok = pcall(function()
        local raw = self.ui.document:getPageMargins()
        -- raw can be table {left,top,right,bottom} or hash
        if raw then
            m.left   = raw.left   or raw[1] or m.left
            m.top    = raw.top    or raw[2] or m.top
            m.right  = raw.right  or raw[3] or m.right
            m.bottom = raw.bottom or raw[4] or m.bottom
        end
    end)
    if not ok then return { left = 20, top = 20, right = 20, bottom = 20 } end
    if self.original_bottom_margin then
        m.bottom = self.original_bottom_margin
    end
    return m
end

function rosetta:_buildPanelCss(font_px, line_height_em, indent_em, suppress_first_indent)
    -- Minimal stylesheet for MuPDF, sized to roughly match book typography.
    -- MuPDF lacks crengine's font-fallback, so font-family resolution is limited;
    -- we keep "serif" as default and only nudge sizes/leading.
    local css = string.format([[
body { font-size: %dpx; line-height: %.3f; margin: 0; padding: 0; }
p { margin: 0; text-indent: %.2fem; text-align: justify; }
%s
h1, h2, h3 { margin: 0.4em 0 0.2em 0; font-weight: bold; text-indent: 0; text-align: left; }
h1 { font-size: 1.4em; } h2 { font-size: 1.25em; } h3 { font-size: 1.1em; }
em, i, cite { font-style: italic; }
strong, b { font-weight: bold; }
blockquote { margin: 0.3em 1em; font-style: italic; }
ul, ol { margin: 0.2em 0 0.2em 1.2em; padding: 0; }
li { text-indent: 0; }
hr { border: 0; border-top: 1px solid #888; margin: 0.6em 0; }
small { font-size: 0.85em; }
sup { font-size: 0.7em; vertical-align: super; }
sub { font-size: 0.7em; vertical-align: sub; }
]], math.floor(font_px), 1 + line_height_em, indent_em,
        suppress_first_indent and "p:first-of-type, h1:first-of-type, h2:first-of-type, h3:first-of-type { text-indent: 0; }" or "")
    return css
end

function rosetta:_appendManiculeHtml(html)
    -- Find last paragraph closing tag and inject space + ☞ before it.
    -- If no closing tag, append at end.
    local plain = Extract:toPlainText(html):gsub("[%s%c]+$", "")
    local last = plain:sub(-1)
    local terminators = {
        ["."]=true,["!"]=true,["?"]=true,[":"]=true,[";"]=true,
        ['"']=true,["'"]=true,[")"]=true,["]"]=true,["}"]=true,
    }
    local end_punct = terminators[last]
        or plain:sub(-3) == "\226\128\166"  -- …
        or plain:sub(-3) == "\226\128\157"  -- ”
        or plain:sub(-3) == "\226\128\153"  -- ’
    if end_punct or plain == "" then return html end
    -- inject before final closing tag
    local injected, n = html:gsub("(.*)(</[%w]+%s*>%s*)$", "%1 ☞%2", 1)
    if n == 1 then return injected end
    return html .. " ☞"
end

function rosetta:_renderHtmlPanel(panel_y, top_pad, bottom_pad, left_pad, right_pad, screen_w, font_px, _face)
    local text_w = math.max(50, screen_w - left_pad - right_pad)
    local text_h = math.max(20, self.panel_height - top_pad - bottom_pad)
    local body = self.panel_text
    body = self:_appendManiculeHtml(body)
    local indent_em = (tonumber(self.config.paragraph_indent_chars) or 0) * 0.5
    local suppress_first = self.panel_continuation == true
    local css = self:_buildPanelCss(font_px, self:_bookLineHeight(), indent_em, suppress_first)

    local hbw = HtmlBoxWidget:new{
        dimen = { w = text_w, h = text_h, x = 0, y = 0 },
    }
    hbw:init()
    hbw.dimen = { w = text_w, h = text_h, x = 0, y = 0 }
    local ok = pcall(function()
        hbw:setContent(body, css, font_px, false, false, nil)
    end)
    if not ok then
        logger.info("rosetta: HtmlBoxWidget setContent failed; falling back to plain")
        return
    end
    pcall(function()
        hbw:_render()
        if hbw.bb then
            Screen.bb:blitFrom(hbw.bb, left_pad, panel_y + top_pad, 0, 0, text_w, text_h)
        end
        hbw:free()
    end)
    Screen:refreshUI(0, panel_y, screen_w, self.panel_height)
end

function rosetta:_hyphenateText(text)
    -- Inject crengine-computed soft hyphens (U+00AD, UTF-8 0xC2 0xAD) into
    -- words so TextBoxWidget/xtext can break long words at sensible spots.
    -- Costs one cre call per unique word per session; cached.
    if not text or text == "" then return text end
    if not self._hyph_cache then self._hyph_cache = {} end
    local cre_ok, cre = pcall(require, "libs/libkoreader-cre")
    if not cre_ok or not cre or not cre.getHyphenationForWord then return text end
    local cache = self._hyph_cache
    -- iterate over whitespace-separated tokens, preserving the original
    -- whitespace exactly.
    -- Strip leading/trailing punctuation BEFORE passing the word to cre — the
    -- hyph dictionary returns a clean form and may swallow trailing dots,
    -- commas, quotes, dashes, etc., destroying the surrounding punctuation.
    local out = text:gsub("(%S+)", function(token)
        if #token < 6 then return token end
        if token:find("[*#]") then return token end
        -- skip tokens that start with NBSP (UTF-8 0xC2 0xA0): those are
        -- paragraph-indent prefixes; cre would otherwise strip them.
        if token:sub(1, 2) == "\194\160" then return token end
        if cache[token] ~= nil then return cache[token] end
        -- separate prefix punctuation, core word, suffix punctuation
        local prefix, core, suffix = token:match("^([%p]*)(.-)([%p]*)$")
        if not core or core == "" or #core < 5 then
            cache[token] = token; return token
        end
        local ok, hyph = pcall(cre.getHyphenationForWord, core)
        if not (ok and hyph and hyph ~= "" and hyph ~= core) then
            cache[token] = token; return token
        end
        local soft = core:find("%-") and hyph or hyph:gsub("%-", "\194\173")
        local out_word = (prefix or "") .. soft .. (suffix or "")
        cache[token] = out_word
        return out_word
    end)
    return out
end

function rosetta:_isPageStartContinuationFromSource(page)
    -- Source-side hint: if the previous page ends without a sentence
    -- terminator, or ends with a soft-hyphen "-", the current page starts
    -- mid-paragraph and should NOT carry a paragraph indent.
    if not page or page <= 1 then return false end
    local prev = self:getTextForPage(page - 1)
    if not prev or prev == "" then return false end
    local tail = prev:gsub("[%s%c]+$", "")
    if tail == "" then return false end
    local last = tail:sub(-1)
    if last == "-" then return true end
    if last == "." or last == "!" or last == "?" or last == ":" or last == ";" then
        return false
    end
    -- closing quotes/brackets count as sentence ends too
    if last == '"' or last == "'" or last == ")" or last == "]" or last == "}" then
        return false
    end
    -- Unicode terminators (ellipsis, right double quote, right single quote)
    if tail:sub(-3) == "\226\128\166" or tail:sub(-3) == "\226\128\157"
        or tail:sub(-3) == "\226\128\153" then
        return false
    end
    return true
end

function rosetta:_currentPageHasText()
    local ok, t = pcall(function()
        local page = self.ui.document:getCurrentPage()
        return self:getTextForPage(page)
    end)
    if not ok or not t then return false end
    -- consider whitespace-only as empty
    return t:match("%S") ~= nil
end

function rosetta:refreshPanel()

    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local footer_h = self:getFooterHeight()
    local panel_y = screen_h - self.panel_height - footer_h

    -- On pages without any text (cover, illustration plates, blank pages)
    -- repaint the panel area in white and skip the fleuron + translation,
    -- so the bottom strip looks like a continuation of the blank book area.
    if not self:_currentPageHasText() then
        Screen.bb:paintRect(0, panel_y, screen_w, self.panel_height, Blitbuffer.COLOR_WHITE)
        Screen:refreshUI(0, panel_y, screen_w, self.panel_height)
        return
    end

    local face, font_px = self:_bookFace()
    local m = self:_bookMargins()

    local left_pad = m.left
    local right_pad = m.right
    local bottom_pad = m.bottom

    -- Separator zone: small pad above rule, horizontal rule with centered
    -- fleuron, generous pad below (roughly one full body line) so the
    -- translation block doesn't crowd the ornament.
    local sep_gap_top = math.max(2, math.floor(font_px * 0.35))
    local sep_gap_bot = math.max(sep_gap_top * 3, math.floor(font_px * 1.8))
    local sep_h = math.max(1, Screen:scaleByDPI(1))
    local sep_y = panel_y + sep_gap_top
    local top_pad = sep_gap_top + sep_h + sep_gap_bot

    local text_w = math.max(50, screen_w - left_pad - right_pad)
    local text_h = math.max(20, self.panel_height - top_pad - bottom_pad)

    -- White-fill the whole panel area first (overwrites stale content).
    Screen.bb:paintRect(0, panel_y, screen_w, self.panel_height, Blitbuffer.COLOR_WHITE)

    -- Horizontal rule spanning the text block.
    Screen.bb:paintRect(left_pad, sep_y, text_w, sep_h, Blitbuffer.COLOR_BLACK)

    -- Fleuron centered on the rule; white halo breaks the line under glyph.
    local fleuron_face = Font:getFace("cfont", math.max(10, math.floor(font_px * 1.1)))
    local fleuron = TextWidget:new{ text = "❦", face = fleuron_face }
    local fsize = fleuron:getSize()
    local halo = Screen:scaleByDPI(6)
    local fx = math.floor((screen_w - fsize.w) / 2)
    local fy = sep_y + math.floor(sep_h / 2) - math.floor(fsize.h / 2)
    Screen.bb:paintRect(fx - halo, fy, fsize.w + halo * 2, fsize.h, Blitbuffer.COLOR_WHITE)
    fleuron:paintTo(Screen.bb, fx, fy)
    fleuron:free()

    if self.panel_loading then
        -- After fleuron, draw a small centered "Translating…" caption and
        -- leave the rest of the panel blank.
        local cap_face = Font:getFace("cfont", math.max(10, math.floor(font_px * 0.85)))
        local cap = TextWidget:new{ text = "Translating…", face = cap_face, fgcolor = Blitbuffer.COLOR_BLACK }
        local cs = cap:getSize()
        local cx = math.floor((screen_w - cs.w) / 2)
        local cy = panel_y + top_pad + math.floor(font_px * 0.3)
        cap:paintTo(Screen.bb, cx, cy)
        cap:free()
        Screen:refreshUI(0, panel_y, screen_w, self.panel_height)
        return
    end

    if self.config.formatting_mode == "html" and self.panel_text and self.panel_text:match("<%a") then
        self:_renderHtmlPanel(panel_y, top_pad, bottom_pad, left_pad, right_pad, screen_w, font_px, face)
        return
    end

    local display_text = self.panel_text or ""
    -- Normalise newlines first: single `\n` (soft wrap from extractor / AI)
    -- → space; runs of 3+ → 2 (paragraph break).
    display_text = display_text:gsub("([^\n])\n([^\n])", "%1 %2")
    display_text = display_text:gsub("\n\n\n+", "\n\n")

    -- Split text into paragraphs (separated by \n\n+).  Each paragraph is
    -- either a heading (starts with `#+ `) or normal body.
    local segments = {}
    do
        local pos = 1
        local n = #display_text
        while pos <= n do
            local s, e = display_text:find("\n\n+", pos)
            local chunk
            if s then
                chunk = display_text:sub(pos, s - 1)
                pos = e + 1
            else
                chunk = display_text:sub(pos)
                pos = n + 1
            end
            if chunk ~= "" then
                local hashes, htext = chunk:match("^(#+)%s+(.*)$")
                if hashes then
                    table.insert(segments, { kind = "heading", level = #hashes, text = htext })
                else
                    table.insert(segments, { kind = "body", text = chunk })
                end
            end
        end
    end

    -- Append paragraph indents to body segments (skip first one when this
    -- page is a continuation from the previous).
    local indent_n = tonumber(self.config.paragraph_indent_chars) or 0
    local indent = indent_n > 0 and string.rep("\194\160", indent_n) or ""
    local seen_first_body = false
    for _, seg in ipairs(segments) do
        if seg.kind == "body" then
            local apply = indent ~= ""
            if not seen_first_body and self.panel_continuation then
                apply = false  -- first body paragraph on a continuation page
            end
            seen_first_body = true
            if apply then seg.text = indent .. seg.text end
        end
    end

    -- Apply hyphenation to all segments.
    for _, seg in ipairs(segments) do
        seg.text = self:_hyphenateText(seg.text)
    end

    -- Append manicule (☞) when the LAST body segment is cut off.
    do
        local last_body
        for i = #segments, 1, -1 do
            if segments[i].kind == "body" then last_body = segments[i]; break end
        end
        if last_body then
            local tail = last_body.text:gsub("[%s%c]+$", "")
            local last = tail:sub(-1)
            local terms = { ["."]=true, ["!"]=true, ["?"]=true, [":"]=true, [";"]=true,
                ['"']=true, ["'"]=true, [")"]=true, ["]"]=true, ["}"]=true }
            local ends_terminator = terms[last]
                or tail:sub(-3) == "\226\128\166"
                or tail:sub(-3) == "\226\128\157"
                or tail:sub(-3) == "\226\128\153"
            if tail ~= "" and not ends_terminator then
                last_body.text = tail .. " ☞"
            end
        end
    end

    -- Resolve face name for Layout body chunks.
    local face_name
    pcall(function()
        if self.config.font_override and self.config.font_override ~= "" then
            face_name = self.config.font_override
        elseif self.ui and self.ui.font then
            face_name = self.ui.font.font_face
        end
    end)

    -- Render segments in order.  Track cur_y so each chunk lands below the
    -- previous one.  Layout.paint returns the height it consumed.
    local cur_y = panel_y + top_pad
    local panel_bottom = panel_y + self.panel_height - bottom_pad
    local seg_index = 0
    for _, seg in ipairs(segments) do
        seg_index = seg_index + 1
        if cur_y >= panel_bottom then break end
        if seg.kind == "heading" then
            -- modest air above each heading (skip for the very first segment
            -- so the heading hugs the fleuron when it's the page opener).
            if seg_index > 1 then
                cur_y = cur_y + math.floor(font_px * 0.8)
            end
            local scale = ({ [1] = 1.15, [2] = 1.08, [3] = 1.03 })[math.min(seg.level, 3)] or 1.0
            local h_px = math.floor(font_px * scale)
            local hface = self:_bookFaceAtPx(h_px)
            local h_text = seg.text:gsub("%*+", "")
            local hw = TextBoxWidget:new{
                text = self:_hyphenateText(h_text),
                face = hface,
                width = text_w,
                alignment = "center",
                justified = false,
                bold = true,
                lang = self.config.target_lang,
            }
            hw:paintTo(Screen.bb, left_pad, cur_y)
            local content_h = hw.text_height or hw._height or h_px
            cur_y = cur_y + content_h + math.floor(font_px * 0.8)
            hw:free()
        else  -- body
            local avail = panel_bottom - cur_y
            if avail < 8 then break end
            local used = 0
            local lok, lerr = pcall(function()
                used = Layout.paint{
                    text = seg.text,
                    face_name = face_name,
                    font_px = font_px,
                    line_height_extra = self:_bookLineHeight(),
                    left_x = left_pad,
                    top_y = cur_y,
                    width = text_w,
                    height = avail,
                    justified = true,
                } or 0
            end)
            if not lok then
                logger.info("rosetta: Layout.paint failed:", tostring(lerr))
                break
            end
            cur_y = cur_y + used
        end
    end

    Screen:refreshUI(0, panel_y, screen_w, self.panel_height)
    logger.info("rosetta: painted at y:", panel_y)
end

function rosetta:addToMainMenu(menu_items)
    menu_items.rosetta = {
        text = "Rosetta — bilingual reader",
        sorting_hint = "typeset",
        sub_item_table = {
            {
                text_func = function()
                    return self:isEnabledForBook()
                        and "Disable for this book"
                        or "Enable for this book"
                end,
                callback = function()
                    local enabled = self:isEnabledForBook()
                    self:setEnabledForBook(not enabled)
                    if not enabled then
                        -- enabling
                        self.is_initialized = false  
                        self:onReaderReady()       
                    else
                        -- disabling — restore viewport
                        self.view.dimen.h = Screen:getHeight()
                        self.ui.dimen.h = Screen:getHeight()
                        self.ui:handleEvent(Event:new("SetDimensions", self.ui.dimen))
                        Screen.bb:paintRect(0, Screen:getHeight() - self.panel_height,
                            Screen:getWidth(), self.panel_height, Blitbuffer.COLOR_WHITE)
                        Screen:refreshUI(0, Screen:getHeight() - self.panel_height,
                            Screen:getWidth(), self.panel_height)
                    end
                end,
            },
            {
                text = "Settings",
                callback = function()
                    self:showSettingsDialog()
                end,
            },
        },
    }
end

return rosetta
