import argparse
import random
import statistics
import subprocess
import time
from datetime import date, timedelta
from pathlib import Path

parser = argparse.ArgumentParser(prog="bench", description="Benchmark tabl on generated CSV files.")
parser.add_argument("refs", nargs="*", default=["main"], help="git branches or tags to compare")
parser.add_argument("--sample", type=int, help="pass --sample <rows> to the import")
args = parser.parse_args()

# First step : build csv
empty_rate = 0.01

path = Path(__file__).parent / "data"
size_of_csvs = [100_000, 1_000_000, 10_000_000]
header = "id,intcol,floatcol,strcol,boolcol,datecol\n"

## check path
path.mkdir(parents=True, exist_ok=True)

labels = [f"label {i}" for i in range(100)]
start = date(2027, 1, 1)
dates = [(start + timedelta(days=d)).isoformat() for d in range(365)]


def maybe_empty(text: str) -> str:
    return "" if rng.random() < empty_rate else text


for size_of_csv in size_of_csvs:
    csv_path = path / f"rows_{size_of_csv}.csv"
    if csv_path.exists():
        continue

    ## same seed for all csv files
    rng = random.Random(42)

    with open(csv_path, "w") as f:
        f.write(header)

        batch = []
        for i in range(size_of_csv):
            intcol = rng.randint(0, 100_000)
            floatcol = intcol / 3 * 10
            strcol = rng.choice(labels)
            boolcol = intcol % 2 == 0
            datecol = rng.choice(dates)
            batch.append(
                f"{i},{maybe_empty(str(intcol))},{floatcol},"
                f'"{strcol}",{boolcol},{maybe_empty(datecol)}\n'
            )
            if len(batch) == 100_000:
                f.writelines(batch)
                batch.clear()
        f.writelines(batch)

# Second step : install versions
root = Path(__file__).parent.parent
clone = path.parent / "clone"
for ref in args.refs:
    subprocess.run(f"git clone --branch {ref} {root} {clone}", shell=True, check=False)
    subprocess.run(
        f"cd {clone} && zig build -Doptimize=ReleaseFast -p ../bin/{ref}",
        shell=True,
        check=False,
    )
    subprocess.run(f"rm -rf {clone}", shell=True, check=False)

# Third step : run benchmarks
repeat = 5
results = []


def measure(command):
    times = []
    for _ in range(repeat):
        start = time.perf_counter()
        subprocess.run(command, shell=True, stdout=subprocess.DEVNULL, check=True)
        times.append(time.perf_counter() - start)
    return times


for ref in args.refs:
    tabl = path.parent / "bin" / ref / "bin" / "tabl"
    for size_of_csv in size_of_csvs:
        csv_path = path / f"rows_{size_of_csv}.csv"
        cache_path = path / f"rows_{size_of_csv}_{ref}.tabl"

        import_command = f"{tabl} import {csv_path} {cache_path}"
        if args.sample is not None:
            import_command += f" --sample {args.sample}"

        page_command = f"{tabl} page {cache_path} {size_of_csv // 2} 100"
        scan_command = f"{tabl} scan {csv_path}"

        results.append((ref, size_of_csv, "scan", measure(scan_command)))
        results.append((ref, size_of_csv, "import", measure(import_command)))
        results.append((ref, size_of_csv, "page", measure(page_command)))

## summary
print(
    f"{'ref':<12}{'rows':>12}  {'command':<8}{'min':>9}{'max':>9}{'mean':>9}{'median':>9}{'stdev':>9}{'rows/s':>11}"
)
for ref, rows, command, times in results:
    ms = [t * 1000 for t in times]
    speed = (
        f"{rows / statistics.median(times) / 1e6:.2f} M" if command in ("scan", "import") else "-"
    )
    print(
        f"{ref:<12}{rows:>12}  {command:<8}"
        f"{min(ms):>9.1f}{max(ms):>9.1f}{statistics.mean(ms):>9.1f}"
        f"{statistics.median(ms):>9.1f}{statistics.stdev(ms):>9.1f}{speed:>11}"
    )
