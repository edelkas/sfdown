# SourceForge project format

This document contains essential information for automatically parsing and downloading a SourceForge project.

The info is current as of 2026-07-21.

## URL templates

The first two templates allow to browse and map out the directory tree. The third one can be used to fetch each found file.

- Project tree root: `https://sourceforge.net/projects/[PROJECT_NAME]/files/`
- Directory page: `https://sourceforge.net/projects/[PROJECT_NAME]/files/[FULL_PATH]/`
- Direct file download: `https://downloads.sourceforge.net/project/[PROJECT_NAME]/[FULL_PATH]`

The direct file download link might actually redirect a few times (via HTTP 3xx codes). In those cases the `location` header link should be followed until the final link can be resolved.

## HTML structure

The current relevant structure of each directory's HTML page:

- Contents stored in a **<table>** with id `files_list`.
- It has the following 4 **<col>** elements (not within a **<colgroup>**) with self-explanatory classes: `name-column`, `date-column`, `size-column` and `downloads-column`.
- Each **<tr>** in its **<tbody>** represents an entry of the directory. The class is either `folder` or `file`, and the title is the folder / file name.
- Each **<th>** / **<td>** represents an attribute of the corresponding entry:
    - The first one has a headers attribute of `files_name_h`, and contains a **<span>** element with class `name` whose content should match the title of the row, i.e., the folder / file name. It also contains an **<a>** link relative to SourceForge's root:
        - For folders this link can be used to navigate the directory tree.
        - For files this link should be ignored, as it directs to the user-facing download page, instead of the direct link found in [URL templates](#url-templates).
    - The second one has a headers attribute of `files_date_h`, and contains the timestamp inside an **<abbr>** element. The full one follows the format `YYYY-mm-dd HH:MM:SS UTC`, the short one `YYYY-mm-dd`.
    - The third one has a headers attribute of `files_size_h`. It is empty for folders, and is in human-readable form for files (e.g. `3.4 MB`).
    - The fourth one has a headers attribute of `files_downloads_h`, and contains a **<span>** element with class `count` whose content is an integer representing the number of weekly downloads. For folders these are the counts of its contents aggregated recursively.

## Additional metadata

Additional file information can be found inside a **<script>** element that defines the object `net.sf.files` with metadata for each folder / file:

    - The **key** is the folder / file name, i.e. the title attribute of the corresponding table row.
    - The **value** is another object with the corresponding properties, potentially including the following ones:
        - **name**: String, the folder / file name, should probably coincide with all other mentioned instances of this name.
        - **path**: String, file base path relative to project's root.
        - **download_url**: String, absolute link. For files, links to user-facing download page, same as **<a>** attribute in the **<td>** element. For folders, redirects to project root.
        - **url**: String, relative link. For folders, links to directory page. For files, redirects to user-facing download page.
        - **full_path**: String, file path relative to project's root (base path + name).
        - **type**: String, `d` for directories and `f` for files.
        - **downloads**: Integer, total download count, aggregated recursively for folders.
        - **sha1**: String, SHA1 hash as lowercase hexdump for files, empty for folders.
        - **md5**: String, MD5 hash as lowercase hexdump for files, empty for folders.
        - **default**: String, comma-separated list of supported OS's for files, empty for folders.
        - **downloadable**: Boolean, generally `true` for files and `false` for folders.
        - **files_url**: String, relative link to project tree root (see [URL templates](#url-templates)).

Note that in the above descriptions a "paths" are w.r.t. the project tree itself, whereas "urls" are w.r.t SourceForge's server, either absolute or relative.
