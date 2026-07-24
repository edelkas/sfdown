# Changelog

All notable changes to this project are documented here.

## [0.4.0] - 2026-07-24

Added file deduplication.

- Files that appear more than once in a project (same MD5/SHA1) are downloaded once and copied locally for every further occurrence. Planned before downloading starts, so progress totals only count the bytes that will really be fetched.
- New option: `-l` / `--link` hard-links duplicates instead of copying them, falling back to a copy (with a warning) where links aren't supported.
- Stage 2 summary reports how many duplicates were cloned and how many bytes that saved.

Sturdier error handling.

- Failures while mapping a page or downloading a file no longer abort the run when they aren't HTTP errors (unwritable path, full disk, unparseable page), they're warned and tallied instead.
- A failed download's partial file is now deleted instead of being left on disk.

## [0.3.0] - 2026-07-24

Added concurrency.

- New option: `-c` / `--concurrent` runs a pool of that many network workers for both stages (mapping directory pages, and downloading files).
- Children nodes are attached in parse order, so resulting tree and even metadata are identical regardless of concurrency settings.

## [0.2.0] - 2026-07-23

Added metadata and integrity hashes.

- New option: `-m` / `--metadata` dumps `metadata.json` (recursive tree with per-entry name/type/size/downloads/timestamp/content) to the project root after stage 1. Files also carry `md5`/`sha1` hashes when available.
- New option: `-i` / `--input` bootstraps the download directly from a metadata JSON file, skipping the mapping stage.
- Stage 2 verifies each downloaded file against its checksum (sha1 preferred, else md5) and warns on mismatch, tallied in the stage summary.

## [0.1.0] - 2026-07-22

Initial release.

- Two-stage download: map the directory tree, then fetch files.
- Scrapes the SourceForge "Files" pages with Nokogiri (HTML table + the `net.sf.files` JS metadata object).
- Preserves file and folder timestamps.
- Live two-line status bar with per-stage analytics.
- Options: `-c` concurrency, `-m` metadata, `-n` structure-only, `-o` output, `-t` timeout, `-s` sleep (the first two still unimplemented at this point).
