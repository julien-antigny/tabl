# Cache format

The cache holds a table that has already been imported, stored **column by column**, so that it can be opened with mmap and read without decoding.

## Layout

A cache is a directory:

```
sales.tabl/
  meta.json       metadata, written last
  0.ends          column 0 (text): end positions of the values
  0.bytes         column 0 (text): values laid end to end
  0.empty         column 0: mask of empty values
  1.values        column 1 (integer): one value per row
  1.empty         column 1: mask of empty values
  …
```

Columns are numbered from 0, in header order. The files of a column depend on its type.

## `meta.json`

```json
{
  "format": "tabl-cache",
  "version": 1,
  "rows": 3,
  "source": {
    "path": "/home/alice/sales.csv",
    "size": 48213377,
    "modified_ns": 1764001234123456789
  },
  "columns": [
    { "name": "city", "type": "text", "offset_width": 32 },
    { "name": "age", "type": "integer" }
  ]
}
```

| Field | Type | Meaning |
|---|---|---|
| `format` | text | always `"tabl-cache"`: marks the directory as a tabl cache |
| `version` | integer | format version, `1` here |
| `rows` | integer | number of rows, from 0 to 2³² − 1 |
| `source.path` | text | absolute path of the imported file |
| `source.size` | integer | size of the imported file, in bytes, at import time |
| `source.modified_ns` | integer | modification time of the imported file, in nanoseconds since January 1st 1970, at import time |
| `columns` | list | one entry per column, in order |
| `columns[].name` | text | column name, in UTF-8 |
| `columns[].type` | text | `"text"`, `"integer"`, `"decimal"`, `"boolean"` or `"date"` |
| `columns[].offset_width` | integer | text columns only: width of the positions, `32` or `64` |

## Empty values: `N.empty`

Every column has a `N.empty` file: one bit per row, set to `1` when the cell is empty (no value, as in `a,,b`), `0` otherwise.

- Row `i` is bit `i % 8` of byte `i / 8`, lowest bit first.
- The file holds exactly `ceil(rows / 8)` bytes; unused bits of the last byte are `0`.

## Text column: `N.ends` and `N.bytes`

- **`N.bytes`**: the values, laid end to end, with no separator. Each value is the cell's text, with its surrounding quotes removed and `""` replaced by `"`.
- **`N.ends`**: for each row, the **end** position of its value in `N.bytes`. Unsigned little-endian integers, 32 or 64 bits wide depending on `offset_width`. The file holds exactly `rows` integers.

The value of row `i` is:

```
start = 0 if i = 0, otherwise ends[i - 1]
end   = ends[i]
value = bytes[start .. end]
```

An empty cell adds nothing to `N.bytes`. An empty text (`""` in the source) also has a zero-length value, but its bit in `N.empty` is `0`.

Positions are 32 bits wide by default, so a column holds up to 4 GiB of text. When it goes past that, the writer rewrites `N.ends` once in 64 bits, then carries on.

## Other columns: `N.values`

One value per row, all the same width, little-endian:

| Type | Width | Value |
|---|---|---|
| `integer` | 8 bytes | signed integer (`i64`) |
| `decimal` | 8 bytes | IEEE 754 double (`f64`) |
| `date` | 4 bytes | signed number of days since January 1st 1970 (`i32`) |
| `boolean` | 1 byte | `0` for false, `1` for true |

The value of row `i` starts at byte `i × width`. An empty cell holds `0`: its bit in `N.empty` tells it apart.

## Example

Three rows: `Paris,31`, `Lyon,45` and `,` (both cells empty).

```
0.bytes   "ParisLyon"
0.ends    05 00 00 00  09 00 00 00  09 00 00 00   (5, 9, 9)
0.empty   04                                     (bit 2: row 2 is empty)
1.values  1F 00 00 00 00 00 00 00                (31)
          2D 00 00 00 00 00 00 00                (45)
          00 00 00 00 00 00 00 00                (0, empty)
1.empty   04
```

## Writing

1. Record the size and modification time of the source file before reading it.
2. Create the directory, then write the column files as a stream, row by row, through fixed-size buffers.
3. Write `meta.json` **last**.

A directory without `meta.json` is an incomplete cache, for instance after an interrupted import, and must be refused.

## Freshness

The cache is **stale** when the file at `source.path` exists and its size or modification time differs from the one recorded in `source`.

- A stale cache can still be read: it is not damaged, only outdated. The caller decides whether to warn or to import again.
- If the source file no longer exists, the cache stays valid and readable.
- Size and time do not detect a content change that keeps both the same (for instance a copy that preserves the time). This rare case is accepted; a content fingerprint may be added later.

## Checks on opening

Any failure refuses the cache with a clear message.

| Check | Error |
|---|---|
| `meta.json` exists | incomplete or missing cache |
| `meta.json` is valid JSON with every field | damaged cache |
| `format` is `"tabl-cache"` | not a tabl cache |
| `version` is `1` | unsupported version (cache written by another version of tabl) |
| `type` is one of the five types | damaged cache |
| `offset_width` is `32` or `64` for a text column, absent otherwise | damaged cache |
| `source.path` is an absolute path | damaged cache |
| each column has its files | damaged cache |
| size of `N.empty` = `ceil(rows / 8)` | damaged cache |
| size of `N.ends` = `rows` × `offset_width` / 8 | damaged cache |
| last position = size of `N.bytes` (0 when `rows` = 0) | damaged cache |
| size of `N.values` = `rows` × width of the type | damaged cache |

Values are not checked one by one on opening: it would read whole files, a cost that grows with the row count. Instead, reading a text clamps its positions to the size of `N.bytes`, and a boolean byte other than `0` reads as true. A damaged cache may show wrong values, but nothing is ever read outside the files.
