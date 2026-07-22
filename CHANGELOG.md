# Changelog

All notable changes to this project are documented here.

## [1.0.0] - 2026-07-22

Initial release.

- Two-stage download: map the directory tree, then fetch files.
- Scrapes the SourceForge "Files" pages with Nokogiri (HTML table + the
  `net.sf.files` JS metadata object).
- Preserves file and folder timestamps.
- Live two-line status bar with per-stage analytics.
- Options: `-c` concurrency, `-m` metadata, `-n` structure-only, `-o` output,
  `-t` timeout, `-s` sleep (first two still unimplemented).
