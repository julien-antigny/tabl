# Cache format — version 1

The cache holds a table that has already been imported, stored **column by column**, so that it can be opened with mmap and read without decoding.

## Layout

A cache is a directory:

```
sales.tabl/
  meta.json       metadata, written last
  0.ends          column 0: end positions of the values
  0.bytes         column 0: values laid end to end
  1.ends
  1.bytes
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

## A column: `N.ends` and `N.bytes`

- **`N.bytes`**: the column's values, laid end to end, with no separator. Each value is the cell's text, with its surrounding quotes removed and `""` replaced by `"`.
- **`N.ends`**: for each row, the **end** position of its value in `N.bytes`. These are unsigned little-endian integers, 32 or 64 bits wide depending on `offset_width`. The file holds exactly `rows` integers.

The value of row `i` is:

```
start = 0 if i = 0, otherwise ends[i - 1]
end   = ends[i]
value = bytes[start .. end]
```

An empty cell gives a zero-length value. Version 1 does not tell an empty cell from an empty text.

### Position width

- `32` by default: a column can hold up to 4 GiB of text.
- `64` only when the column's text exceeds 4 GiB.

The writer starts with 32 bits. When it goes past the limit, it rewrites `N.ends` once in 64 bits, then carries on.

### Example

Two rows, `Paris,31` and `Lyon,45`:

```
0.bytes  "ParisLyon"              (9 bytes)
0.ends   05 00 00 00  09 00 00 00  (5, 9 as little-endian u32)
1.bytes  "3145"
1.ends   02 00 00 00  04 00 00 00  (2, 4)
```

## Writing

1. Record the size and modification time of the source file before reading it.
2. Create the directory, then write the `.ends` and `.bytes` files as a stream, row by row, through fixed-size buffers.
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
| each column has both of its files | damaged cache |
| size of `N.ends` = `rows` × `offset_width` / 8 | damaged cache |
| positions never decrease (each ≥ the previous one) | damaged cache |
| last position = size of `N.bytes` (0 when `rows` = 0) | damaged cache |

Checking that positions never decrease means reading all of `N.ends` on opening. Version 1 accepts this cost. It will be measured, and the check will become lazy if it gets in the way.

## Evolution

- Any change to the format increments `version`.
- A reader only accepts the versions it knows. There is no implicit forward compatibility.
- Planned changes:

| Version | Addition | PR |
|---|---|---|
| 2 | types (`i64`, `f64`, dates) and a mask of empty values | 5 |
| 3 | min and max per block of rows | 6 |
| 4 | dictionary for repeated values | 7 |

- Unplanned ideas, to decide on measurements:

| Idea | Principle | Expected gain | Cost |
|---|---|---|---|
| block positions | a `u64` base every 65,536 rows, then 16-bit offsets | positions halved | low; direct access is kept |
| block compression (zstd, lz4) | each block of text compressed, decompressed on read | ×2 to ×4 on free text | high; no more direct mmap, a block cache to manage |
