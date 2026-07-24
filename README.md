# sfdown

SourceForge project downloader. Will clone the project's directory tree and fetch all files.

Supports [concurrency](#concurrency-and-throttling), [integrity verification](#integrity-verification) and [file deduplication](#file-deduplication).

## Installation

```
gem install sfdown
```

## Usage

Run with:

```
sfdown project_name [-lmn] [-c concurrent] [-i input] [-o output] [-t timeout] [-s sleep]
```

Arguments:

| Arguments | Default | Description |
|--|--|--|
| `-c` or `--concurrent` | 4 | Number of [parallel](#concurrency-and-throttling) network workers, used in both stages |
|`-i` or `--input`|None|[Bootstrap](#bootstrapping-downloads) the download directly from a metadata JSON file|
|`-l` or `--link`|False|Hard-link [duplicate files](#file-deduplication) instead of copying them|
|`-m` or `--metadata`|False|Save metadata as JSON to disk at project's root|
|`-n` or `--no`|False|Only fetch directory tree structure and file metadata, not files|
|`-o` or `--output`|Current dir|Path to store project's root|
|`-t` or `--timeout`|5|Timeout for each GET request|
|`-s` or `--sleep`|0|Wait in-between requests|

## Features

### Integrity verification

SourceForge publishes each file's **MD5** / **SHA1** hash. Whenever available, this is used after downloading to verify file integrity. SHA1 is preferred for its strength, MD5 is used as a fallback. Mismatches aren't discarded, simply logged.

### File deduplication

The **MD5** / **SHA1** hashes are also used so that files that appear more than once in a project are downloaded only once: the first copy is fetched, the rest are copied from it locally. Progress totals only count the bytes that actually need fetching.

With `-l` the duplicates are hard-linked instead, so they take no extra disk space at all. If the filesystem doesn't support linking, sfdown warns once and falls back to copying.

### Bootstrapping downloads

The process happens in two stages:

- **Stage 1** browses the directory tree and maps it out, optionally exporting the metadata to a JSON file (`-m` flag).
- **Stage 2** creates the directory tree and fetches all files.

Stage 2 can be started directly from a preexisting metadata file exported in stage 1 (`-i` flag).

### Concurrency and throttling

Multiple workers can be used in parallel for both stages via the `-c` flag.

To prevent rate-limits, an optional sleep can be added between fetches via the `-s` flag.

**Note**: `-s` is applied per worker, so with `-c` the effective request rate scales roughly linearly with the number of workers.