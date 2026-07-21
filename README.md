# sfdown

SourceForge project downloader. Will clone the project's directory tree and fetch all files.

## Usage

Run with:

```
ruby sfdown.rb project_name [-mn] [-c concurrent] [-o output] [-t timeout] [-s sleep]

```

Arguments:

| Arguments | Default | Description |
|--|--|--|
| `-c` or `--concurrent` | 1 | Number of parallel downloads |
|`-m` or `--metadata`|False|Save metadata to disk at project's root|
|`-n` or `--no`|False|Only fetch directory tree structure and file metadata, not files|
|`-o` or `--output`|Current dir|Path to store project's root|
|`-t` or `--timeout`|5|Timeout for each GET request|
|`-s` or `--sleep`|0|Wait in-between requests|
