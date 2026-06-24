# Rosetta Anchor File Format (`parallel-aligned.json`)

The anchor file follows the **[parallel-align-spec](https://github.com/sypianski/parallel-align-spec)** open specification — a content-hash-keyed sidecar format for bilingual EPUB paragraph alignment.

This document is Rosetta's implementation notes on top of that spec.  For the canonical schema, normalization algorithm, and JSON Schema, see [parallel-align-spec](https://github.com/sypianski/parallel-align-spec).

The anchor file is produced by [paraligilo](https://github.com/sypianski/paraligilo) and consumed by Rosetta at read-time.  It lives in the book's KOReader sidecar:

```
<book.epub>.sdr/parallel-aligned.json
```

## Schema (version 1)

```json
{
  "epa_version": 1,
  "src":  { "file": "il-libro.epub",       "lang": "it" },
  "tgt":  { "file": "ksiazka-pl.epub",     "lang": "pl" },
  "method": "gale-church" | "embeddings" | "llm" | "hybrid",
  "generator": "paraligilo 0.1.0",
  "created_at": "2026-06-24T12:00:00Z",
  "stats": {
    "src_paragraphs": 3214,
    "matched": 3098,
    "low_confidence": 51
  },
  "by_hash": {
    "<md5 hex of normalized src paragraph>": {
      "tgt": "...translation paragraph...",
      "confidence": 0.95
    }
  }
}
```

### Normalization (for `by_hash` keys)

Both paraligilo (writer) and Rosetta (reader) must compute the hash identically:

1. Strip leading and trailing whitespace.
2. Collapse all internal runs of whitespace (incl. NBSP, tab, newline) to a single ASCII space.
3. UTF-8 NFC normalize.
4. MD5 hex of the resulting UTF-8 bytes.

### Lookup semantics

Rosetta's page-render pipeline already extracts the current page as paragraphs (split on `\n\n`).  For each source paragraph it computes the normalized hash and looks it up in `by_hash`.  Hits become the panel text.  Misses (or `confidence < threshold`) fall back to the AI translation pipeline, paragraph by paragraph.

### Confidence

`confidence` is in [0, 1].  Rosetta's default threshold is `0.6` — below that, the entry is ignored and the AI pipeline runs for that paragraph.  Mode-specific typical ranges:

| Method | Typical confidence range |
|---|---|
| `gale-church` | 0.5 – 0.95 (length-ratio based) |
| `embeddings`  | 0.7 – 0.99 (cosine similarity, rescaled) |
| `llm`         | 0.9 – 1.0  (model's self-reported certainty) |
| `hybrid`      | 0.85 – 1.0 (max of embedding cosine and LLM judgment) |

### Multi-paragraph alignments

When the translator joined two source paragraphs into one target paragraph (or split one into two), each source-paragraph hash maps to the same `tgt` string.  Rosetta detects identical `tgt` values for consecutive source paragraphs and renders the joined block only once.

When the translator split one source paragraph into two targets, the entry stores both joined with `\n\n` in `tgt`.

## File location

Rosetta loads `parallel-aligned.json` from the same `.sdr/` directory KOReader already uses for bookmarks, highlights, and reading state.  If you sync your `.sdr/` directories via Syncthing (recommended), anchor files travel with the book across devices.

If the file is missing or fails to parse, Rosetta silently falls back to its AI translation pipeline — no error UI.
