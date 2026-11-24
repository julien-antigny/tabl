# tabl

Read tabular data without friction.

Open a large CSV file and get to the data right away: no import wizard, no waiting, no spreadsheet freezing on millions of rows.

> Early stage: only the `scan` command exists for now.

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
```

Comma- and semicolon-separated files are supported, with quoted values and an optional UTF-8 BOM.

## Contributing

See [CONVENTIONS.md](CONVENTIONS.md).
