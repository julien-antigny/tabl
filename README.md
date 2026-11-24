# tabl

Read tabular data without friction.

Open a large CSV file and get to the data right away: no import wizard, no waiting, no spreadsheet freezing on millions of rows.

> Early stage: a command line to scan a CSV file, import it into a cache, and read it page by page.

## Build

Requires [Zig](https://ziglang.org) 0.17.1.

```sh
zig build
zig build test
```

## Usage

```sh
$ tabl scan sales.csv
1200000 rows, 8 columns

$ tabl import sales.csv sales.tabl
1200000 rows, 8 columns imported into sales.tabl

$ tabl page sales.tabl 40 20
city    age    …
rows 40 to 59 of 1200000
```

Comma- and semicolon-separated files are supported, with quoted values and an optional UTF-8 BOM.

The cache is a directory of column files, opened with mmap; see [its format](back/infra/table/cache/FORMAT.md).

## Contributing

See [CONVENTIONS.md](CONVENTIONS.md).
