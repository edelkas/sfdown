# Changelog

All notable changes to this project are documented here.

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
- Options: `-c` concurrency, `-m` metadata, `-n` structure-only, `-o` output, `-t` timeout, `-s` sleep (first two still unimplemented).
