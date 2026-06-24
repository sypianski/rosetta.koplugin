local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")

local Config = {}

local config_path = DataStorage:getSettingsDir() .. "/rosetta.lua"

local defaults = {
    api_key = "",
    source_lang = "auto",
    target_lang = "en",
    panel_height_ratio = 0.50,
    auto_translate = true,
    font_size = 14,            -- legacy (fallback when book font px is unknown)
    font_size_percent = 100,   -- panel font size as % of book font size
    line_spacing_override = 0, -- 0 = follow book; else explicit % (50-200)
    paragraph_indent_chars = 0,-- prepend N spaces to each paragraph (0 = off)
    font_override = "",        -- "" = follow book; else crengine face name
    formatting_mode = "plain", -- "plain" | "html" (preserve titles/italic/bold via MuPDF)
    clear_cache_on_start = false, -- diagnostic: nuke translation cache every restart
    backend = "google",  -- "google" | "ai"
    ai_api_key = "",
    ai_base_url = "https://openrouter.ai/api/v1/chat/completions",
    ai_model = "google/gemini-2.5-flash",
    ai_temperature = 0.3,
    ai_max_tokens = 4096,
}

function Config:load()
    local ok, settings = pcall(function()
        return LuaSettings:open(config_path)
    end)
    if not ok or not settings then
        logger.info("rosetta config: using defaults")
        local result = {}
        for k, v in pairs(defaults) do result[k] = v end
        return result
    end
    local result = {}
    for k, v in pairs(defaults) do
        result[k] = settings:readSetting(k) or v
    end
    return result
end

function Config:save(data)
    local ok, settings = pcall(function()
        return LuaSettings:open(config_path)
    end)
    if not ok or not settings then
        logger.info("rosetta config: failed to open settings file")
        return false
    end
    for k, v in pairs(data) do
        settings:saveSetting(k, v)
    end
    settings:flush()
    logger.info("rosetta config: saved")
    return true
end

return Config
