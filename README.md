# Rosetta

AI-translated reading panel beneath the book text — for language learners reading foreign-language books in KOReader.

The original page stays in place; a panel at the bottom shows the same page rendered in your target language, typographically matched to the book: same font face, same margins, hyphenation, real italic and bold, headings, paragraph indents, manicule (`☞`) when a sentence is cut off.

> Fork of [splitread.koplugin](https://github.com/sadatdaniel/splitread.koplugin) by [@sadatdaniel](https://github.com/sadatdaniel) (GPL-3.0).

---

## Install

1. Drop `rosetta.koplugin/` into your KOReader plugins directory (`koreader/plugins/` on Kobo/Kindle, `/sdcard/koreader/plugins/` on Android, `~/.config/koreader/plugins/` on Linux desktop).
2. Restart KOReader.
3. Open a book → tap top of screen → **Typeset** → **rosetta** → **Enable for this book**.
4. In **rosetta → Settings**, set your target language, AI API key, and (optionally) model. Default model: `google/gemini-2.5-flash` via OpenRouter; any OpenAI-compatible endpoint works.

---

## Features

- **AI backend** with prev/next page as context and a `|` page-break marker round-tripped through the model. Optional Google Translate fallback.
- **Per-page disk cache**, keyed by MD5 of the page text (survives reflow / font changes). Background prefetch of the next page → instant page turns.
- **Book-matched typography**: panel uses the book's font face, configurable % size, line spacing, margins, and crengine hyphenation for the target language.
- **Inline formatting**: markdown markers (`# `, `## `, `*…*`, `**…**`, `• `) are preserved by the prompt and rendered as real headings (centered, bold, scaled) and inline italic / bold via a small mixed-style line-layout engine.
- **Page-boundary handling**: source-side check on the previous page's tail + lowercase heuristic + AI marker decide whether a page begins as a continuation (no indent) or a fresh paragraph (indent). Soft-hyphen joins (`gene-rations` → one word) at the boundary.
- **Fleuron (`❦`)** separator between book and panel, manicule (`☞`) when the last sentence is cut off.

---

## Settings

Book menu → **Typeset** → **rosetta** → **Settings**.

| Setting | Effect |
|---|---|
| Source / Target language | Source usually `auto`; target = language you want to read in. |
| Backend | `Google Translate` or `AI (with context)`. |
| AI model / API key / base URL | OpenAI-compatible endpoint. |
| Font / Font size | Override book face, or set size as % of book. |
| Line spacing | Follow book, or explicit override. |
| Paragraph indent | 0–8 spaces prepended to each paragraph. |
| Panel size | Small / Medium / Large (25 / 35 / 45 % of screen). |
| Formatting mode | `plain` (default) or `html` (experimental, MuPDF-rendered). |

Settings live in `~/.config/koreader/settings/rosetta.lua`. Cache: `settings/rosetta_cache/`.

---

## Limitations

- The panel uses KOReader's `TextBoxWidget` / `RenderText` primitives, not crengine's full HTML renderer. Font and metrics match the book, but the EPUB's own CSS rules don't apply to the panel.
- AI translation costs against your OpenRouter / OpenAI quota; cache + prefetch keep it modest.
- Tables, complex lists, and footnotes are not handled.

---

## Credits

Original concept and starting code: [splitread.koplugin](https://github.com/sadatdaniel/splitread.koplugin) by [@sadatdaniel](https://github.com/sadatdaniel) (GPL-3.0). Rosetta is a substantial rewrite around AI translation with disk cache, prefetch, book-matched typography, markdown round-trip, and a custom mixed-style line-layout engine.

License: GPL-3.0 (inherited).
