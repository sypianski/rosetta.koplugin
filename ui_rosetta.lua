local UIManager = require("ui/uimanager")
local ButtonDialogTitle = require("ui/widget/buttondialogtitle")
local InputDialog = require("ui/widget/inputdialog")
local Device = require("device")
local logger = require("logger")

local LANGUAGES = {
    { code = "auto", name = "Auto detect" },
    { code = "de",   name = "German" },
    { code = "en",   name = "English" },
    { code = "fr",   name = "French" },
    { code = "es",   name = "Spanish" },
    { code = "it",   name = "Italian" },
    { code = "pt",   name = "Portuguese" },
    { code = "nl",   name = "Dutch" },
    { code = "pl",   name = "Polish" },
    { code = "ru",   name = "Russian" },
    { code = "ja",   name = "Japanese" },
    { code = "zh",   name = "Chinese" },
    { code = "ar",   name = "Arabic" },
    { code = "tr",   name = "Turkish" },
    { code = "ko",   name = "Korean" },
}

local FONT_PERCENTS = {50, 60, 70, 80, 90, 100, 110, 125, 150, 175, 200}
local LINE_SPACING_PERCENTS = {0, 80, 90, 100, 110, 120, 130, 140, 150, 160, 175, 200}
local INDENT_CHARS = {0, 2, 3, 4, 5, 6, 8}

local PANEL_SIZES = {
    { ratio = 0.25, name = "Small (25%)" },
    { ratio = 0.35, name = "Medium (35%)" },
    { ratio = 0.45, name = "Large (45%)" },
}


local UI = {}

function UI:getLanguageName(code)
    for _, lang in ipairs(LANGUAGES) do
        if lang.code == code then
            return lang.name
        end
    end
    return code:upper()
end

function UI:getPanelSizeName(ratio)
    for _, size in ipairs(PANEL_SIZES) do
        if size.ratio == ratio then
            return size.name
        end
    end
    return tostring(math.floor(ratio * 100)) .. "%"
end

function UI:showLanguagePicker(title, current_code, on_select, on_done)
    local picker_dialog
    local buttons = {}
    for _, lang in ipairs(LANGUAGES) do
        local is_current = lang.code == current_code
        table.insert(buttons, {
            {
                text = (is_current and "✓ " or "  ") .. lang.name,
                callback = function()
                    UIManager:close(picker_dialog)
                    on_select(lang.code)
                    on_done()
                end,
            }
        })
    end
    picker_dialog = ButtonDialogTitle:new{
        title = title,
        buttons = buttons,
    }
    UIManager:show(picker_dialog)
end

function UI:showFontFacePicker(current, on_select, on_done)
    local dlg
    local buttons = {}
    -- "follow book" entry first
    table.insert(buttons, {{
        text = ((current == "" or current == nil) and "✓ " or "  ") .. "(follow book)",
        callback = function()
            UIManager:close(dlg)
            on_select(""); on_done()
        end,
    }})
    -- enumerate crengine font faces
    local faces = {}
    local ok = pcall(function()
        local cre = require("libs/libkoreader-cre")
        if cre and cre.getFontFaces then faces = cre.getFontFaces() or {} end
    end)
    if not ok or #faces == 0 then
        -- fallback: a couple of generic FontList entries
        local FontList = require("fontlist")
        local list = FontList:getFontList()
        for _, e in ipairs(list or {}) do table.insert(faces, e) end
    end
    table.sort(faces)
    for _, name in ipairs(faces) do
        local is_cur = name == current
        table.insert(buttons, {{
            text = (is_cur and "✓ " or "  ") .. name,
            callback = function()
                UIManager:close(dlg)
                on_select(name); on_done()
            end,
        }})
    end
    dlg = ButtonDialogTitle:new{ title = "Translation font", buttons = buttons }
    UIManager:show(dlg)
end

function UI:showSimpleIntPicker(title, values, current, label_fn, on_select, on_done, cols)
    local dlg
    local buttons = {}
    cols = cols or 1
    -- closed = true after any intentional action; close_callback uses it to
    -- detect Escape/back so it can return to the settings menu
    local closed = false
    local function select_and_close(v)
        closed = true
        UIManager:close(dlg)
        on_select(v)
        on_done()
    end
    local function cancel_and_close()
        closed = true
        UIManager:close(dlg)
        on_done()
    end
    local row = {}
    for _, v in ipairs(values) do
        local is_current = v == current
        table.insert(row, {
            text = (is_current and "✓ " or "  ") .. label_fn(v),
            callback = function() select_and_close(v) end,
        })
        if #row >= cols then
            table.insert(buttons, row)
            row = {}
        end
    end
    if #row > 0 then
        while #row < cols do
            table.insert(row, { text = "", callback = function() end })
        end
        table.insert(buttons, row)
    end
    local function on_escape()
        if not closed then
            closed = true
            on_done()
        end
    end
    if Device:hasKeyboard() then
        -- keyboard present: prepend OK/Cancel row so user can type an arbitrary number
        local ok_row = {
            {
                text = "Cancel",
                callback = function() cancel_and_close() end,
            },
            {
                text = "OK",
                is_enter_default = true,
                callback = function()
                    local val = tonumber(dlg:getInputText())
                    if val then select_and_close(val) end
                end,
            },
        }
        table.insert(buttons, 1, ok_row)
        dlg = InputDialog:new{
            title = title,
            input = tostring(current),
            input_type = "number",
            buttons = buttons,
            close_callback = on_escape,
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    else
        dlg = ButtonDialogTitle:new{
            title = title,
            buttons = buttons,
            close_callback = on_escape,
        }
        UIManager:show(dlg)
    end
end

function UI:showPanelSizePicker(current_ratio, on_select, on_done)
    local panel_dialog
    local buttons = {}

    table.insert(buttons, {
        {
            text = "⚠ Reopen book to apply panel size change",
            callback = function() end,
        }
    })

    for _, size in ipairs(PANEL_SIZES) do
        local is_current = size.ratio == current_ratio
        table.insert(buttons, {
            {
                text = (is_current and "✓ " or "  ") .. size.name,
                callback = function()
                    UIManager:close(panel_dialog)
                    on_select(size.ratio)
                    on_done()
                end,
            }
        })
    end

    panel_dialog = ButtonDialogTitle:new{
        title = "Panel Size",
        buttons = buttons,
    }
    UIManager:show(panel_dialog)
end

function UI:showTextInput(title, current, on_save, on_done)
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = current or "",
        input_type = "text",
        text_type = "password",
        buttons = {{
            { text = "Cancel", id = "close", callback = function() UIManager:close(dlg); on_done() end },
            { text = "Save",   is_enter_default = true, callback = function()
                on_save(dlg:getInputText())
                UIManager:close(dlg); on_done()
            end },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function UI:showSettingsDialog(config, Config, on_refresh, on_panel_resize)
    logger.info("rosetta: showSettingsDialog called")

    if self.current_dialog then
        UIManager:close(self.current_dialog)
        self.current_dialog = nil
    end

    UIManager:scheduleIn(0.1, function()
        local dialog

        -- Local helpers to build entries
        local function reopen()
            self:showSettingsDialog(config, Config, on_refresh, on_panel_resize)
        end
        local function header(text)
            -- non-clickable header row
            return { { text = "── " .. text .. " ──", callback = function() end } }
        end
        local btn_source = {
            text = "Source: " .. self:getLanguageName(config.source_lang),
            callback = function()
                UIManager:close(dialog)
                self:showLanguagePicker("Source Language", config.source_lang,
                    function(code) config.source_lang = code; Config:save(config) end,
                    reopen)
            end,
        }
        local btn_target = {
            text = "Target: " .. self:getLanguageName(config.target_lang),
            callback = function()
                UIManager:close(dialog)
                self:showLanguagePicker("Target Language", config.target_lang,
                    function(code) config.target_lang = code; Config:save(config) end,
                    reopen)
            end,
        }
        local btn_backend = {
            text = "Backend: " .. ((config.backend == "ai") and "AI" or "Google"),
            callback = function()
                config.backend = (config.backend == "ai") and "google" or "ai"
                Config:save(config); UIManager:close(dialog); reopen()
            end,
        }
        local btn_auto = {
            text = "Auto-translate: " .. (config.auto_translate and "ON" or "OFF"),
            callback = function()
                config.auto_translate = not config.auto_translate
                Config:save(config); UIManager:close(dialog); reopen()
            end,
        }
        local btn_formatting = {
            text = "Formatting: " .. ((config.formatting_mode == "html") and "HTML" or "plain"),
            callback = function()
                config.formatting_mode = (config.formatting_mode == "html") and "plain" or "html"
                Config:save(config); UIManager:close(dialog); reopen()
            end,
        }
        local btn_ai_model = {
            text = "AI model: " .. (config.ai_model or "(unset)"),
            callback = function()
                UIManager:close(dialog)
                self:showTextInput("AI model (e.g. google/gemini-2.5-flash)", config.ai_model,
                    function(v) config.ai_model = v; Config:save(config) end, reopen)
            end,
        }
        local btn_ai_key = {
            text = "AI key: " .. ((config.ai_api_key and #config.ai_api_key > 0)
                and ("set (" .. #config.ai_api_key .. " ch)") or "(unset)"),
            callback = function()
                UIManager:close(dialog)
                self:showTextInput("OpenRouter API key (sk-or-…)", config.ai_api_key,
                    function(v) config.ai_api_key = v; Config:save(config) end, reopen)
            end,
        }
        local btn_ai_url = {
            text = "AI URL: " .. ((config.ai_base_url or ""):match("^https?://([^/]+)") or "(unset)"),
            callback = function()
                UIManager:close(dialog)
                self:showTextInput("AI base URL (OpenAI-compat /chat/completions)", config.ai_base_url,
                    function(v) config.ai_base_url = v; Config:save(config) end, reopen)
            end,
        }
        local btn_font = {
            text = "Font: " .. ((config.font_override ~= nil and config.font_override ~= "")
                and config.font_override or "follow book"),
            callback = function()
                UIManager:close(dialog)
                self:showFontFacePicker(config.font_override or "",
                    function(name) config.font_override = name; Config:save(config) end, reopen)
            end,
        }
        local btn_font_size = {
            text = "Size: " .. (config.font_size_percent or 100) .. "%",
            callback = function()
                UIManager:close(dialog)
                self:showSimpleIntPicker("Translation Font Size (relative to book)",
                    FONT_PERCENTS, config.font_size_percent or 100,
                    function(v) return tostring(v) .. "%" end,
                    function(pct) config.font_size_percent = pct; Config:save(config) end,
                    reopen, 3)
            end,
        }
        local btn_line_spacing = {
            text = "Line spacing: " .. ((tonumber(config.line_spacing_override) or 0) > 0
                and (tostring(config.line_spacing_override) .. "%") or "book"),
            callback = function()
                UIManager:close(dialog)
                self:showSimpleIntPicker("Translation line spacing",
                    LINE_SPACING_PERCENTS, config.line_spacing_override or 0,
                    function(v) return v == 0 and "follow book" or (tostring(v) .. "%") end,
                    function(v) config.line_spacing_override = v; Config:save(config) end,
                    reopen, 3)
            end,
        }
        local btn_indent = {
            text = "Indent: " .. (config.paragraph_indent_chars or 0) .. " sp",
            callback = function()
                UIManager:close(dialog)
                self:showSimpleIntPicker("Paragraph indent (spaces)",
                    INDENT_CHARS, config.paragraph_indent_chars or 0,
                    function(v) return v == 0 and "off" or (tostring(v) .. " sp") end,
                    function(v) config.paragraph_indent_chars = v; Config:save(config) end,
                    reopen, 3)
            end,
        }
        local btn_panel = {
            text = "Panel: " .. self:getPanelSizeName(config.panel_height_ratio),
            callback = function()
                UIManager:close(dialog)
                self:showPanelSizePicker(config.panel_height_ratio,
                    function(ratio)
                        config.panel_height_ratio = ratio; Config:save(config)
                        if on_panel_resize then on_panel_resize(ratio) end
                    end, reopen)
            end,
        }
        -- ── Alignment helpers ──
        local InfoMessage = require("ui/widget/infomessage")
        local function book_file()
            return self._book_file or ""
        end
        local function anchor_path()
            local f = book_file()
            return f ~= "" and (f .. ".sdr/rosetta-aligned.json") or nil
        end
        local function file_exists(p)
            local fh = p and io.open(p, "rb"); if not fh then return false end
            fh:close(); return true
        end
        local function pair_path()
            local f = book_file()
            return f ~= "" and (f .. ".sdr/rosetta-paired.txt") or nil
        end
        local function read_pair()
            local p = pair_path(); if not p then return nil end
            local fh = io.open(p, "rb"); if not fh then return nil end
            local s = fh:read("*a"); fh:close()
            return (s or ""):gsub("[\r\n]+$", "")
        end
        local btn_auto_detect = {
            text = "Auto-detect…",
            callback = function()
                UIManager:close(dialog)
                local orig = book_file()
                if orig == "" then
                    UIManager:show(InfoMessage:new{ text = "No book open." })
                    reopen(); return
                end
                local sdr = orig .. ".sdr"
                local notes = {}

                -- 1. anchor JSON / Lua already in .sdr/
                local anchor_candidates = {
                    sdr .. "/rosetta-aligned.json",
                    sdr .. "/rosetta-aligned.lua",
                }
                local anchor_found
                for _, p in ipairs(anchor_candidates) do
                    if file_exists(p) then
                        anchor_found = p
                        table.insert(notes, "anchor: " .. p)
                        break
                    end
                end
                if not anchor_found then
                    table.insert(notes, "anchor: not found in " .. sdr .. "/")
                end

                -- 2. paired EPUB: try existing rosetta-paired.txt first, else
                -- read tgt.file from the anchor JSON, else scan siblings
                local pair_p = pair_path()
                local pair_now = read_pair()
                if pair_now and pair_now ~= "" and file_exists(pair_now) then
                    table.insert(notes, "pair: already set → " .. pair_now)
                elseif anchor_found and anchor_found:match("%.json$") then
                    local fh = io.open(anchor_found, "rb")
                    if fh then
                        local body = fh:read("*a"); fh:close()
                        local tgt = body:match('"tgt"%s*:%s*{[^}]-"file"%s*:%s*"([^"]+)"')
                        if tgt and file_exists(tgt) then
                            local wfh = io.open(pair_p, "wb")
                            if wfh then wfh:write(tgt); wfh:close()
                                table.insert(notes, "pair: from anchor → " .. tgt)
                            end
                        end
                    end
                end
                if not pair_now or pair_now == "" or not file_exists(pair_now or "") then
                    -- scan siblings
                    local dir, fname = orig:match("^(.*)/([^/]+)$")
                    dir = dir or "."
                    local base = (fname or ""):gsub("%.epub$", "")
                    local cmd = string.format("ls -1 %q/*.epub 2>/dev/null", dir)
                    local p = io.popen(cmd, "r")
                    local found_siblings = {}
                    if p then
                        for line in p:lines() do
                            if line ~= orig and line:lower():match("%.epub$") then
                                table.insert(found_siblings, line)
                            end
                        end
                        p:close()
                    end
                    if #found_siblings == 1 then
                        local wfh = io.open(pair_p, "wb")
                        if wfh then wfh:write(found_siblings[1]); wfh:close()
                            table.insert(notes, "pair: single sibling → " .. found_siblings[1])
                        end
                    elseif #found_siblings > 1 then
                        table.insert(notes, "pair: " .. #found_siblings .. " sibling EPUBs — use \"Add target EPUB…\" to pick one")
                    elseif (not pair_now) or pair_now == "" then
                        table.insert(notes, "pair: no sibling EPUBs in " .. dir)
                    end
                end

                UIManager:show(InfoMessage:new{ text = table.concat(notes, "\n") })
                reopen()
            end,
        }
        local btn_pair_epub = {
            text = "Add target EPUB…",
            callback = function()
                UIManager:close(dialog)
                local p = pair_path()
                if not p then
                    UIManager:show(InfoMessage:new{ text = "No book open." })
                    reopen(); return
                end
                local PathChooser = require("ui/widget/pathchooser")
                local start_dir = book_file():match("^(.*)/[^/]+$") or "/"
                local chooser
                chooser = PathChooser:new{
                    title = "Pick translation EPUB",
                    path = start_dir,
                    select_directory = false,
                    select_file = true,
                    show_files = true,
                    file_filter = function(filename)
                        return filename:lower():match("%.epub$") ~= nil
                    end,
                    onConfirm = function(src)
                        os.execute(string.format("mkdir -p %q", p:match("^(.*)/[^/]+$") or "."))
                        local fh = io.open(p, "wb")
                        if not fh then
                            UIManager:show(InfoMessage:new{ text = "Cannot write: " .. p })
                            reopen(); return
                        end
                        fh:write(src); fh:close()
                        UIManager:show(InfoMessage:new{
                            text = "Paired with:\n" .. src .. "\n\nUse \"Generate via paraligilo\" to compute the alignment.",
                        })
                        reopen()
                    end,
                }
                UIManager:show(chooser)
            end,
        }
        local function pair_status_short()
            local pp = pair_path()
            if pp and file_exists(pp) then return "paired" end
            return "none"
        end
        -- pair_status_short is called at row-build time below; status text:
        local anchor_status_text = (function()
            local p = anchor_path()
            local ap = (p and file_exists(p)) and "anchor" or "no anchor"
            local pp = pair_status_short()
            return "Status: " .. ap .. " / " .. pp
        end)()
        local btn_anchor_status = {
            text = anchor_status_text,
            callback = function()
                local p = anchor_path()
                local msg
                if not p then
                    msg = "No book is open."
                elseif file_exists(p) then
                    msg = "Anchor file found:\n" .. p
                else
                    msg = "No anchor file at:\n" .. p .. "\n\nPaths searched:\n  • <book>.sdr/rosetta-aligned.json"
                end
                UIManager:close(dialog)
                UIManager:show(InfoMessage:new{ text = msg })
                reopen()
            end,
        }
        local btn_set_anchor = {
            text = "Add anchor file…",
            callback = function()
                UIManager:close(dialog)
                local p = anchor_path()
                if not p then
                    UIManager:show(InfoMessage:new{ text = "No book open." })
                    reopen(); return
                end
                local PathChooser = require("ui/widget/pathchooser")
                local start_dir = book_file():match("^(.*)/[^/]+$") or "/"
                local chooser
                chooser = PathChooser:new{
                    title = "Pick rosetta-aligned.json",
                    path = start_dir,
                    select_directory = false,
                    select_file = true,
                    show_files = true,
                    onConfirm = function(src)
                        local sfh = io.open(src, "rb")
                        if not sfh then
                            UIManager:show(InfoMessage:new{ text = "Cannot open: " .. src })
                            reopen(); return
                        end
                        local body = sfh:read("*a"); sfh:close()
                        os.execute(string.format("mkdir -p %q", p:match("^(.*)/[^/]+$") or "."))
                        local dfh = io.open(p, "wb")
                        if not dfh then
                            UIManager:show(InfoMessage:new{ text = "Cannot write: " .. p })
                            reopen(); return
                        end
                        dfh:write(body); dfh:close()
                        UIManager:show(InfoMessage:new{
                            text = "Installed:\n" .. p .. "\n\nReopen the book to use anchors.",
                        })
                        reopen()
                    end,
                }
                UIManager:show(chooser)
            end,
        }
        local btn_run_paraligilo = {
            text = "Generate via paraligilo",
            callback = function()
                UIManager:close(dialog)
                local orig = book_file()
                local trans = read_pair()
                local par_home = config.paraligilo_path or ""
                local run_py = par_home .. "/run.py"
                local emit_py = par_home .. "/emit_rosetta.py"
                if orig == "" then
                    UIManager:show(InfoMessage:new{ text = "No book open." }); reopen(); return
                end
                if not trans or trans == "" then
                    UIManager:show(InfoMessage:new{
                        text = "No target EPUB paired.\nUse \"Add target EPUB…\" first.",
                    }); reopen(); return
                end
                if not file_exists(run_py) or not file_exists(emit_py) then
                    UIManager:show(InfoMessage:new{
                        text = "paraligilo scripts not found at:\n" .. par_home
                            .. "\n\nInstall paraligilo or set paraligilo_path "
                            .. "in ~/.config/koreader/settings/rosetta.lua.\n\n"
                            .. "Or use the web UI: sypian.ski/paraligilo",
                    }); reopen(); return
                end

                -- pick a mode
                local mode_dlg
                local function run_with(mode_args, mode_label)
                    UIManager:close(mode_dlg)
                    local slug = orig:match("([^/]+)%.epub$") or "rosetta_pair"
                    slug = slug:gsub("[^%w]+", "_")
                    local workdir = "/tmp/rosetta-paraligilo-" .. slug
                    os.execute(string.format("mkdir -p %q", workdir))
                    local out_json = orig .. ".sdr/rosetta-aligned.json"
                    os.execute(string.format("mkdir -p %q", orig .. ".sdr"))

                    local Trapper = require("ui/trapper")
                    local TrapWidget = require("ui/widget/trapwidget")
                    local trap = TrapWidget:new{
                        text = "paraligilo: aligning (" .. mode_label .. ")…\nThis may take 30s–5min.",
                    }
                    UIManager:show(trap)
                    Trapper:wrap(function()
                        local cmd1 = string.format(
                            "cd %q && %q %q %q --name %s --workdir %q %s 2>&1",
                            par_home, run_py, orig, trans, slug, workdir, mode_args)
                        local ok1 = Trapper:dismissableRunInSubprocess(function()
                            local p = io.popen(cmd1, "r")
                            local out = p:read("*a"); local _, _, rc = p:close()
                            return rc, out
                        end, trap)
                        if not ok1 then
                            UIManager:close(trap)
                            UIManager:show(InfoMessage:new{ text = "Cancelled." })
                            reopen(); return
                        end
                        local cmd2 = string.format(
                            "%q --orig-jsonl %q --trans-jsonl %q --align %q "
                            .. "--src-file %q --tgt-file %q --method %s -o %q 2>&1",
                            emit_py,
                            workdir .. "/" .. slug .. "_orig.jsonl",
                            workdir .. "/" .. slug .. "_trans.jsonl",
                            workdir .. "/" .. slug .. "_final.jsonl",
                            orig, trans, mode_label, out_json)
                        local ok2 = Trapper:dismissableRunInSubprocess(function()
                            local p = io.popen(cmd2, "r")
                            local out = p:read("*a"); local _, _, rc = p:close()
                            return rc, out
                        end, trap)
                        UIManager:close(trap)
                        if not ok2 then
                            UIManager:show(InfoMessage:new{ text = "Cancelled during emit." })
                        elseif file_exists(out_json) then
                            UIManager:show(InfoMessage:new{
                                text = "Anchor file generated:\n" .. out_json
                                    .. "\n\nTurn a page to use the alignment.",
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = "paraligilo finished but no anchor file produced.\n"
                                    .. "Check " .. workdir .. " for intermediates.",
                            })
                        end
                        reopen()
                    end)
                end
                local function mb(label, args)
                    return { text = label, callback = function() run_with(args, label) end }
                end
                mode_dlg = ButtonDialogTitle:new{
                    title = "paraligilo alignment mode",
                    buttons = {
                        { mb("gale-church", "--mode deterministic") },
                        { mb("embeddings",  "--mode ai") },
                        { mb("hybrid",      "--mode ai --llm") },
                        { { text = "Cancel", callback = function()
                            UIManager:close(mode_dlg); reopen() end } },
                    },
                }
                UIManager:show(mode_dlg)
            end,
        }

        local btn_close = {
            text = "Close",
            callback = function()
                UIManager:close(dialog); self.current_dialog = nil
            end,
        }

        local empty = { text = " ", callback = function() end }
        local hdr_translation = { { text = "── Translation ──", callback = function() end } }
        local hdr_formatting  = { { text = "── Formatting ──",  callback = function() end } }
        local hdr_alignment   = { { text = "── Alignment ──",   callback = function() end } }
        dialog = ButtonDialogTitle:new{
            title = "rosetta",
            buttons = {
                hdr_translation,
                { btn_source,         btn_target          },
                { btn_backend,        btn_auto            },
                { btn_ai_model,       btn_ai_key          },
                { btn_ai_url,         empty               },
                hdr_alignment,
                { btn_anchor_status,  btn_auto_detect     },
                { btn_set_anchor,     btn_pair_epub       },
                { btn_run_paraligilo, empty               },
                hdr_formatting,
                { btn_font,           btn_font_size       },
                { btn_line_spacing,   btn_indent          },
                { btn_panel,          empty               },
                { btn_close },
            },
        }
        self.current_dialog = dialog
        UIManager:show(dialog)
    end)
end

return UI