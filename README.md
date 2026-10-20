<div align="center">
  <h1>Rosetta</h1>
  <p>A translation under the book text.</p>
  <p>by <a href="https://sypian.ski/">Jakub Sypiański</a> · License: GPL-3.0</p>
  <p>Version 1 · updated 24 July 2026</p>

  [![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
  ![Platform](https://img.shields.io/badge/platform-KOReader-brightgreen)
</div>

> **Part of the KOReader family.** Related apps:
> [Hairline](https://github.com/sypianski/hairline.koplugin), a thin progress bar at the bottom edge;
> [KoTheme](https://github.com/sypianski/kotheme.koplugin), rounded corners and thinner borders;
> [Marjenoti](https://github.com/sypianski/marjenoti.koplugin), notes in the right margin;
> and others.

An AI-translated reading panel beneath the book text, for language learners reading foreign-language books in KOReader.

The original page stays in place; a panel at the bottom shows the same page rendered in your target language, typographically matched to the book: same font face, same margins, hyphenation, real italic and bold, headings, paragraph indents, manicule (`☞`) when a sentence is cut off.

## Install

Clone the repository (it is the plugin directory) into KOReader's `plugins/` folder under the name `rosetta.koplugin`:

```sh
git clone https://github.com/sypianski/rosetta.koplugin \
    ~/.config/koreader/plugins/rosetta.koplugin
```

The path above is for native Linux. On other systems use the plugins folder of your KOReader:

| Platform | Plugins folder |
|---|---|
| Linux (native) | `~/.config/koreader/plugins/` |
| Linux (Flatpak) | `~/.var/app/rocks.koreader.KOReader/config/koreader/plugins/` |
| Kobo / Kindle / PocketBook | `koreader/plugins/` on the device |
| Android | `koreader/plugins/` in KOReader's storage folder |

Instead of cloning you can download the repository as a ZIP from GitHub and unpack it into the plugins folder; the folder must be named `rosetta.koplugin`.

Restart KOReader.

There are no prebuilt releases; the repository is the distribution.

After restarting:

1. Open a book, tap the top of the screen, then **Typeset** > **rosetta** > **Enable for this book**.
2. In **rosetta > Settings**, set your target language, AI API key and (optionally) model. Default model: `google/gemini-2.5-flash` via OpenRouter; any OpenAI-compatible endpoint works.

## What it does

- **AI backend** with prev/next page as context and a `|` page-break marker round-tripped through the model. Optional Google Translate fallback.
- **Per-page disk cache**, keyed by MD5 of the page text (survives reflow / font changes). Background prefetch of the next page → instant page turns.
- **Book-matched typography**: panel uses the book's font face, configurable % size, line spacing, margins, and crengine hyphenation for the target language.
- **Inline formatting**: markdown markers (`# `, `## `, `*…*`, `**…**`, `• `) are preserved by the prompt and rendered as real headings (centered, bold, scaled) and inline italic / bold via a small mixed-style line-layout engine.
- **Page-boundary handling**: source-side check on the previous page's tail + lowercase heuristic + AI marker decide whether a page begins as a continuation (no indent) or a fresh paragraph (indent). Soft-hyphen joins (`gene-rations` → one word) at the boundary.
- **Fleuron (`❦`)** separator between book and panel, manicule (`☞`) when the last sentence is cut off.
- **Human translation via [paraligilo](https://github.com/sypianski/paraligilo) anchors**: drop a `parallel-aligned.json` into the book's `.sdr/` directory and Rosetta will serve the human-translated text instead of calling AI per page. The file follows the [parallel-align-spec](https://github.com/sypianski/parallel-align-spec) open spec — see [ANCHOR_FORMAT.md](ANCHOR_FORMAT.md) for Rosetta-specific notes and [paraligilo](https://github.com/sypianski/paraligilo) for how to produce it.

### Settings

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

### Limitations

- The panel uses KOReader's `TextBoxWidget` / `RenderText` primitives, not crengine's full HTML renderer. Font and metrics match the book, but the EPUB's own CSS rules don't apply to the panel.
- AI translation costs against your OpenRouter / OpenAI quota; cache + prefetch keep it modest.
- Tables, complex lists, and footnotes are not handled.

## Technical notes

**Data and network.** With the AI backend the text of the current page (plus the previous and next page as context) is sent to the configured OpenAI-compatible endpoint; with the other backend it is sent to Google Translate. Translations are cached on the device in `settings/rosetta_cache/`; settings live in `settings/rosetta.lua`. With human-translation anchors (see above) no per-page request is made.

See [ANCHOR_FORMAT.md](ANCHOR_FORMAT.md) for the Rosetta-specific notes on the parallel-alignment anchors.

## How this was made

Rosetta was written largely by a large language model, working from my specifications and
under my direction ("vibe coding"). I reviewed and tested the results, but
the code has not had an independent audit. Treat it as you would any young
project and report what you find.

The code inherited from splitread.koplugin is written by its authors; the changes and additions in this repository were made largely with a large language model under my direction. See Credits for what comes from where.

## Feedback

Rosetta is a young project. If something breaks, behaves oddly or is missing, tell me:

<!-- feedback-form: https://sypian.ski/uwagi/?app=rosetta -->
- [Open an issue on GitHub](https://github.com/sypianski/rosetta.koplugin/issues/new). Bug reports, ideas and questions are all fine there; include your KOReader version, your device, the translation backend and the version of Rosetta (1).
- Or email jakub.sypianski@gmail.com.

## Support

Rosetta is free. If it is useful to you, you can [buy me a coffee on Ko-fi](https://ko-fi.com/sypianski).

## License and credits

Rosetta is licensed under the GNU General Public License v3.0 (GPL-3.0), see [LICENSE](LICENSE).

Original concept and starting code: [splitread.koplugin](https://github.com/sadatdaniel/splitread.koplugin) by [@sadatdaniel](https://github.com/sadatdaniel) (GPL-3.0). Rosetta is a substantial rewrite around AI translation with disk cache, prefetch, book-matched typography, markdown round-trip and a custom mixed-style line-layout engine. The GPL-3.0 license is inherited from it.

---

<p align="center">Rosetta · <a href="https://sypian.ski/">Jakub Sypiański</a> · GPL-3.0</p>
