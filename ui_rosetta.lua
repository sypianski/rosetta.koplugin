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
        local btn_close = {
            text = "Close",
            callback = function()
                UIManager:close(dialog); self.current_dialog = nil
            end,
        }

        dialog = ButtonDialogTitle:new{
            title = "rosetta",
            buttons = {
                header("Translation"),
                { btn_source,       btn_target       },
                { btn_backend,      btn_auto         },
                { btn_formatting,   btn_panel        },
                header("AI"),
                { btn_ai_model,     btn_ai_key       },
                { btn_ai_url                          },
                header("Typography"),
                { btn_font,         btn_font_size    },
                { btn_line_spacing, btn_indent       },
                { btn_close },
            },
        }
        self.current_dialog = dialog
        UIManager:show(dialog)
    end)
end

return UI