"""Table difficulty analytics: the bot plays many generated tables, we
measure which table features make them hard.

Usage:
    python tests/run_analytics.py [--seeds 20] [--tables 30] [--trials 4] [--frames 2700] [out.csv]

Runs TIC-80 headless in batches of seeds (to stay under the per-run
timeout), writes one CSV row per launch, then prints a summary:
difficulty by table index, by wall piece, by toy, by goal, and the
hardest / easiest tables. The CSV can be opened in any spreadsheet.
"""
import argparse
import csv
import os
import statistics
import subprocess
import sys
import tempfile
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
import build_tic  # noqa: E402

TIC = os.environ.get("TIC80", r"C:\Program Files\tic80-v1.3-win.exe")


def run_batch(seed0, seeds, tables, trials, frames):
    work = tempfile.mkdtemp(prefix="frana_")
    lua = os.path.join(work, "ana.lua")
    with open(lua, "w", encoding="utf-8", newline="\n") as f:
        f.write(open(os.path.join(ROOT, "fairy_ring.lua"), encoding="utf-8").read())
        f.write("\nA_SEED0, A_SEEDS, A_TABLES, A_TRIALS, A_FRAMES = %d, %d, %d, %d, %d\n"
                % (seed0, seeds, tables, trials, frames))
        f.write(open(os.path.join(HERE, "analytics.lua"), encoding="utf-8").read())
    build_tic.main(lua, os.path.join(ROOT, "fairy_ring_sprites.png"), os.path.join(work, "ana.tic"))
    r = subprocess.run([TIC, "--cli", "--skip", "--fs=" + work, "--cmd=load ana.tic & run"],
                       capture_output=True, text=True, timeout=1800)
    rows = [ln[4:] for ln in r.stdout.splitlines() if ln.startswith("CSV,")]
    if "DONE" not in r.stdout:
        print("batch %d did not finish:\n%s" % (seed0, r.stdout[-2000:]))
    return rows


def rate(rows, key="up"):
    return sum(1 for r in rows if r["result"] == key) / max(1, len(rows))


def summarize(rows):
    def table_line(label, rs):
        up, down = rate(rs, "up"), rate(rs, "down")
        ups = [int(r["frames"]) for r in rs if r["result"] == "up"]
        t = statistics.median(ups) / 60 if ups else float("nan")
        return "  %-26s n=%4d  climb %3.0f%%  drain %3.0f%%  stay %3.0f%%  median climb %4.1fs" % (
            label, len(rs), up * 100, down * 100, (1 - up - down) * 100, t)

    print("\n== overall")
    print(table_line("all launches", rows))

    print("\n== by table index (difficulty curve)")
    by = defaultdict(list)
    for r in rows:
        by[int(r["table"])].append(r)
    for k in sorted(by):
        print(table_line("table %d%s" % (k, " (bonus)" if by[k][0]["bonus"] == "1" else ""), by[k]))

    print("\n== by wall piece (either side)")
    by = defaultdict(list)
    for r in rows:
        for side in ("left", "right"):
            by[r[side]].append(r)
    for k in sorted(by, key=lambda k: rate(by[k])):
        print(table_line(k, by[k]))

    print("\n== by toy count (non-bonus tables)")
    plain = [r for r in rows if r["bonus"] == "0"]
    by = defaultdict(list)
    for r in plain:
        by[min(int(r["objs"]), 14) // 3 * 3].append(r)
    for k in sorted(by):
        print(table_line("%d-%d toys" % (k, k + 2), by[k]))

    print("\n== effect of each toy (tables with vs without, non-bonus)")
    for kind in ("bumper", "gold", "pixie", "hole", "well", "acorn", "shroom", "bud"):
        w = [r for r in plain if int(r["n_" + kind]) > 0]
        wo = [r for r in plain if int(r["n_" + kind]) == 0]
        if w and wo:
            print("  %-8s with: climb %3.0f%% drain %3.0f%%   without: climb %3.0f%% drain %3.0f%%" % (
                kind, rate(w) * 100, rate(w, "down") * 100, rate(wo) * 100, rate(wo, "down") * 100))

    print("\n== drains: where the ball left (x of last frame)")
    d = [int(float(r["exit_x"])) for r in rows if r["result"] == "down" and int(float(r["exit_x"])) >= 0]
    if d:
        out = sum(1 for x in d if x < 45 or x > 105)
        print("  outlanes %d (%.0f%%), centre %d (%.0f%%)" % (out, out / len(d) * 100,
              len(d) - out, (len(d) - out) / len(d) * 100))

    print("\n== hardest and easiest individual tables (seed/table)")
    per = defaultdict(list)
    for r in rows:
        per[(r["seed"], r["table"])].append(r)
    scored = sorted(per.items(), key=lambda kv: (rate(kv[1]) - rate(kv[1], "down")))
    for (seed, ti), rs in scored[:6]:
        r0 = rs[0]
        print("  HARD seed %s table %s: %s|%s objs %s goals %s  climb %.0f%% drain %.0f%%" % (
            seed, ti, r0["left"], r0["right"], r0["objs"], r0["rewards"], rate(rs) * 100, rate(rs, "down") * 100))
    for (seed, ti), rs in scored[-4:]:
        r0 = rs[0]
        print("  EASY seed %s table %s: %s|%s objs %s goals %s  climb %.0f%% drain %.0f%%" % (
            seed, ti, r0["left"], r0["right"], r0["objs"], r0["rewards"], rate(rs) * 100, rate(rs, "down") * 100))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=20)
    ap.add_argument("--seed0", type=int, default=1000)
    ap.add_argument("--tables", type=int, default=30)
    ap.add_argument("--trials", type=int, default=4)
    ap.add_argument("--frames", type=int, default=2700)
    ap.add_argument("--batch", type=int, default=4, help="seeds per TIC-80 run")
    ap.add_argument("--summary-only", metavar="CSV", help="just summarize an existing CSV")
    ap.add_argument("out", nargs="?", default=os.path.join(HERE, "out", "analytics.csv"))
    a = ap.parse_args()
    if a.summary_only:
        summarize(list(csv.DictReader(open(a.summary_only, encoding="utf-8"))))
        return
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    header, data = None, []
    for s0 in range(a.seed0, a.seed0 + a.seeds, a.batch):
        n = min(a.batch, a.seed0 + a.seeds - s0)
        rows = run_batch(s0, n, a.tables, a.trials, a.frames)
        if rows:
            header = rows[0]
            data += rows[1:]
        print("seeds %d-%d: %d rows" % (s0, s0 + n - 1, len(rows) - 1), flush=True)
    with open(a.out, "w", encoding="utf-8", newline="") as f:
        f.write(header + "\n")
        for r in data:
            f.write(r + "\n")
    print("wrote", a.out)
    summarize(list(csv.DictReader(open(a.out, encoding="utf-8"))))


if __name__ == "__main__":
    main()
