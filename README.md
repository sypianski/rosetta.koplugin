# Rosetta — Translation Panel for KOReader

A KOReader plugin that displays AI-translated text in a panel beneath the book, designed for language learners reading foreign-language books with their native-language translation visible at all times.

Fork of [splitread.koplugin](https://github.com/sadatdaniel/splitread.koplugin) by [@sadatdaniel](https://github.com/sadatdaniel) (GPL-3.0). Substantially extended with:

- **AI backend** via any OpenAI-compatible API (OpenRouter by default), with its own key / model / base URL
- **Disk cache** keyed by MD5 of page content (survives reflow + offline reading)
- **Background prefetch** of the next page so page turns are instant
- **Book-matched typography**: panel uses the book's font face, font size (as % of book), margins, and line spacing
- **Crengine soft-hyphenation** for the target language, applied to the panel text
- **Heading / italic / bold round-trip**: page HTML is extracted as markdown, AI is instructed to preserve `# `, `## `, `*…*`, `**…**` markers, and Rosetta renders them as real headings (centered, bold) and inline emphasis (mixed italic/bold faces with justified wrap)
- **Page-boundary handling**: AI prompt + source-side check + lowercase heuristic detect when a page begins mid-paragraph (no indent) vs a fresh paragraph (indent), and stitch soft-hyphen line breaks (`gene-rations` → one word)
- **Continuation marker**: a `|` round-trip pipe marker keeps "this is mid-paragraph" information through translation
- **Manicule (☞)** at the end of the panel when the last sentence is cut off by the page break
- **Fleuron (❦)** divider between book and panel, with auto-sized padding

The original splitread is a minimal Google-Translate-only panel; this fork pivots to a full AI-translation reading companion. Settings UI exposes font, font size %, line spacing, paragraph indent, formatting mode, AI model, API key, and base URL.

---

## Install

1. Copy `rosetta.koplugin/` into your KOReader plugins directory:
   - **Kobo/Kindle:** `koreader/plugins/`
   - **Android:** `/sdcard/koreader/plugins/`
   - **Desktop (Linux):** `~/.config/koreader/plugins/`
2. Restart KOReader.
3. Open a book → menu → **Typeset** tab → **rosetta** → **Enable for this book**.
4. In **Settings**, set your **AI model** and **AI API key** (OpenRouter default).

---

## License

GPL-3.0 — same as the upstream splitread. See [LICENSE](LICENSE).
