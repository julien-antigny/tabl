# Cache format — version 1

The cache holds a table that has already been imported, stored **column by column**, so that it can be opened with mmap and read without decoding.

## Layout

A cache is a directory:

```
sales.tabl/
  meta.json       metadata, written last
  0.ends          column 0: end positions of the values
  0.bytes         column 0: values laid end to end
  0.empty         column 0: mask of empty values
  1.ends
  1.bytes
  1.empty
  …
```

Columns are numbered from 0, in header order.

## `meta.json`

```json
{
  "format": "tabl-cache",
  "version": 1,
  "rows": 2,
  "source": {
    "path": "/home/alice/sales.csv",
    "size": 48213377,
    "modified_ns": 1764001234123456789
  },
  "columns": [
    { "name": "city", "offset_width": 32 },
    { "name": "age", "offset_width": 32 }
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
| `columns[].offset_width` | integer | width of the column's positions: `32` or `64` |

## A column: `N.ends`, `N.bytes` and `N.empty`

- **`N.bytes`**: the column's values, laid end to end, with no separator. Each value is the cell's text, with its surrounding quotes removed and `""` replaced by `"`.
- **`N.ends`**: for each row, the **end** position of its value in `N.bytes`. These are unsigned little-endian integers, 32 or 64 bits wide depending on `offset_width`. The file holds exactly `rows` integers.
- **`N.empty`**: one bit per row, set to `1` when the cell is empty (no value, as in `a,,b`), `0` otherwise. Row `i` is bit `i % 8` of byte `i / 8`, lowest bit first. The file holds exactly `ceil(rows / 8)` bytes; unused bits of the last byte are `0`.

The value of row `i` is:

```
start = 0 if i = 0, otherwise ends[i - 1]
end   = ends[i]
value = bytes[start .. end]
```

An empty cell adds nothing to `N.bytes`: its end position is the same as the previous one. An empty text (`""` in the source) also has a zero-length value, but its bit in `N.empty` is `0`.

### Position width

- `32` by default: a column can hold up to 4 GiB of text.
- `64` only when the column's text exceeds 4 GiB.

The writer starts with 32 bits. When it goes past the limit, it rewrites `N.ends` once in 64 bits, then carries on.

### Example

Three rows, `Paris,31`, `Lyon,45` and `,""` (an empty city, an empty text as age):

```
0.bytes  "ParisLyon"                           (9 bytes)
0.ends   05 00 00 00  09 00 00 00  09 00 00 00  (5, 9, 9 as little-endian u32)
0.empty  04                                    (bit 2 set: row 2 is empty)
1.bytes  "3145"
1.ends   02 00 00 00  04 00 00 00  04 00 00 00  (2, 4, 4)
1.empty  00                                    (row 2 holds an empty text, not an empty cell)
```

## Writing

1. Record the size and modification time of the source file before reading it.
2. Create the directory, then write the `.ends`, `.bytes` and `.empty` files as a stream, row by row, through fixed-size buffers.
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
| `offset_width` is `32` or `64` | damaged cache |
| `source.path` is an absolute path | damaged cache |
| each column has its three files | damaged cache |
| size of `N.ends` = `rows` × `offset_width` / 8 | damaged cache |
| size of `N.empty` = `ceil(rows / 8)` | damaged cache |
| last position = size of `N.bytes` (0 when `rows` = 0) | damaged cache |

Positions are not checked one by one on opening: it would read all of `N.ends`, a cost that grows with the row count. Instead, reading a value clamps its positions to the size of `N.bytes`. A damaged cache may show wrong values, but nothing is ever read outside the files.

## Evolution

- Any change to the format increments `version`.
- A reader only accepts the versions it knows. There is no implicit forward compatibility.
- Planned changes:

| Version | Addition | PR |
|---|---|---|
| 2 | types (`i64`, `f64`, dates) | 5 |
| 3 | min and max per block of rows | 6 |
| 4 | dictionary for repeated values | 7 |

- Unplanned ideas, to decide on measurements:

| Idea | Principle | Expected gain | Cost |
|---|---|---|---|
| block positions | a `u64` base every 65,536 rows, then 16-bit offsets | positions halved | low; direct access is kept |
| block compression (zstd, lz4) | each block of text compressed, decompressed on read | ×2 to ×4 on free text | high; no more direct mmap, a block cache to manage |
