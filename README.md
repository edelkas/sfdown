# sfdown

SourceForge project downloader. Will clone the project's directory tree and fetch all files.

## Installation

```
gem install sfdown
```

## Usage

Run with:

```
sfdown project_name [-mn] [-c concurrent] [-i input] [-o output] [-t timeout] [-s sleep]
```

Arguments:

| Arguments | Default | Description |
|--|--|--|
| `-c` or `--concurrent` | 1 | Number of parallel network workers, used in both stages |
|`-i` or `--input`|None|Bootstrap the download directly from a metadata JSON file, skipping the mapping stage|
|`-m` or `--metadata`|False|Save metadata to disk at project's root|
|`-n` or `--no`|False|Only fetch directory tree structure and file metadata, not files|
|`-o` or `--output`|Current dir|Path to store project's root|
|`-t` or `--timeout`|5|Timeout for each GET request|
|`-s` or `--sleep`|0|Wait in-between requests|

**Note**: `-s` is applied per worker, so with `-c` the effective request rate scales with the number of workers.