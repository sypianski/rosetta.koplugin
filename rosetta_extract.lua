-- Extracts a simplified HTML snippet for a single book page.
-- Output is a `<body>`-fragment using only a whitelist of semantic tags,
-- safe to feed to MuPDF / HtmlBoxWidget and to round-trip through an LLM
-- without prompting attribute-explosion.
--
-- Approach:
--   1. doc:getHTMLFromXPointers(xp_start, xp_end, 0xE830) — crengine returns
--      a well-formed HTML5 document for the page range, including styles.
--   2. Strip <html><head>…</head>, <script>, <style>, <link>, <img> entirely.
--   3. Walk the body and keep only whitelisted tags + their text content;
--      drop all attributes; collapse unknown tags into their children's text.
--
-- We deliberately keep the implementation regex-based: KOReader has no real
-- HTML parser available to plugins, and crengine's output is regular enough
-- that a tag-by-tag rewrite is reliable for prose books.

local logger = require("logger")

local Extract = {}

local WRITENODEEX_HTML = 0xE830

-- Tags we keep wholesale (with their text content).
local KEEP_TAGS = {
    p = true, br = true, hr = true,
    h1 = true, h2 = true, h3 = true, h4 = true, h5 = true, h6 = true,
    em = true, i = true, strong = true, b = true, u = true, s = true,
    sup = true, sub = true, small = true,
    blockquote = true, q = true, cite = true,
    ul = true, ol = true, li = true,
    dl = true, dt = true, dd = true,
    section = true, article = true,
    span = true, div = true,
    -- crengine sometimes emits these; keep as paragraph-equivalents
    ["epub:type"] = false, -- not a tag, just listed for clarity
}

-- Tags whose entire subtree is dropped (content + tag).
local DROP_SUBTREE = {
    script = true, style = true, link = true, meta = true,
    head = true, title = true,
    img = true, picture = true, source = true, svg = true, video = true,
    iframe = true, object = true, embed = true,
    nav = true, header = true, footer = true,
    -- crengine sometimes wraps page numbers / running headers in these
    -- removed-from-flow elements; we don't translate them.
}

local function unescape_html(s)
    if not s then return "" end
    return s:gsub("&amp;",  "&")
            :gsub("&lt;",   "<")
            :gsub("&gt;",   ">")
            :gsub("&quot;", '"')
            :gsub("&apos;", "'")
            :gsub("&nbsp;", "\194\160")
end

local function escape_html(s)
    return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

-- Walk the body, drop unknown / non-whitelisted tags, strip all attributes.
local function simplify(html)
    -- 1. cut off <html>...<body> prefix and </body>... suffix
    local body = html:match("<body[^>]*>(.-)</body>") or html
    -- 2. drop entire subtrees of DROP_SUBTREE tags
    for tag in pairs(DROP_SUBTREE) do
        local open  = "<" .. tag .. "[^>]*>"
        local close = "</" .. tag .. "%s*>"
        local self_close = "<" .. tag .. "[^>]*/%s*>"
        -- self-closing
        body = body:gsub(self_close, "")
        -- paired (greedy across content — pages are small)
        body = body:gsub(open .. ".-" .. close, "")
        -- orphaned closes
        body = body:gsub(close, "")
    end
    -- 3. process remaining tags: keep whitelist, strip attributes from kept
    --    tags, unwrap (drop tag, keep inner) unknown tags.
    body = body:gsub("<(/?)([%w:%-]+)([^>]*)>", function(slash, name, _attrs)
        local lname = name:lower()
        if lname:match("^epub:") or lname:match("^xml:") then
            return ""  -- drop namespaced tags entirely (keep children via "")
        end
        if KEEP_TAGS[lname] then
            -- keep tag, drop attrs
            if slash == "/" then return "</" .. lname .. ">" end
            return "<" .. lname .. ">"
        end
        -- unknown: drop the tag itself, keep its inner content
        return ""
    end)
    -- 4. collapse multiple blank lines + whitespace
    body = body:gsub("[ \t]+", " ")
    body = body:gsub("\n%s*\n%s*\n+", "\n\n")
    body = body:gsub("^%s+", ""):gsub("%s+$", "")
    return body
end

-- Extract HTML body for a page.  Returns simplified body string, or nil.
function Extract:forPage(doc, page)
    local ok, xp0 = pcall(function() return doc:getPageXPointer(page) end)
    if not ok or not xp0 then return nil end
    local ok2, xp1 = pcall(function() return doc:getPageXPointer(page + 1) end)
    if not ok2 or not xp1 then return nil end
    local ok3, html = pcall(function()
        return doc:getHTMLFromXPointers(xp0, xp1, WRITENODEEX_HTML, false)
    end)
    if not ok3 or not html or html == "" then
        logger.info("rosetta extract: getHTMLFromXPointers failed for page", page)
        return nil
    end
    return simplify(html)
end

-- Extract titles + body as plain text, with `# ` / `## ` markdown prefixes
-- preserved for headings.  Used by the plain-text AI backend to give the
-- model (and the renderer) a hint about heading lines.
function Extract:toTitledPlainText(html_body)
    if not html_body then return "" end
    local s = html_body
    -- inline emphasis → markdown markers (preserved through AI, rendered by us)
    s = s:gsub("<strong[^>]*>(.-)</strong>", "**%1**")
    s = s:gsub("<b[^>]*>(.-)</b>",          "**%1**")
    s = s:gsub("<em[^>]*>(.-)</em>",        "*%1*")
    s = s:gsub("<i[^>]*>(.-)</i>",          "*%1*")
    s = s:gsub("<cite[^>]*>(.-)</cite>",    "*%1*")
    -- headings (deepest first to avoid eating their inner emphasis)
    for level = 6, 1, -1 do
        local hashes = string.rep("#", level)
        local open  = "<h" .. level .. "[^>]*>"
        local close = "</h" .. level .. "%s*>"
        s = s:gsub(open .. "(.-)" .. close, "\n\n" .. hashes .. " %1\n\n")
    end
    -- paragraph + br conversion
    s = s:gsub("</p>%s*", "\n\n")
    s = s:gsub("<br%s*/?>", "\n")
    -- list items
    s = s:gsub("<li[^>]*>", "\n• ")
    s = s:gsub("</li>", "")
    -- drop remaining tags
    s = s:gsub("<[^>]+>", "")
    s = unescape_html(s)
    -- collapse whitespace
    s = s:gsub("\n[ \t]+", "\n")
    s = s:gsub("[ \t]+", " ")
    s = s:gsub("\n\n+", "\n\n")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
end

-- Utility: extract plain text from a simplified body (for hashing / fallbacks).
function Extract:toPlainText(body)
    if not body then return "" end
    local s = body:gsub("<br%s*/?>", "\n")
    s = s:gsub("</p>", "\n\n")
    s = s:gsub("<[^>]+>", "")
    s = unescape_html(s)
    s = s:gsub("\n\n+", "\n\n")
    return s
end

Extract.escape_html = escape_html
Extract.unescape_html = unescape_html

return Extract
