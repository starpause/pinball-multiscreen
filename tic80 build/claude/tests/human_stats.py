"""Summarise human play logged by play.py (logs/runlog.txt).

    python tests/human_stats.py [path/to/runlog.txt]

Per level: how often players reached it, time spent, balls lost and
drops back down, so we can see where real people struggle (the bot's
numbers can't be trusted for things like side drains).
"""
import os
import re
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(HERE), "logs", "runlog.txt")
    runs = []
    for line in open(path, encoding="utf-8"):
        m = re.search(r"RUNLOG seed=(\S+) best=(\d+) score=(\d+)(.*)", line)
        if not m:
            continue
        levels = {}
        for lv, secs, loss, drop, bb, dc, do, code in re.findall(
                r"(\d+):(\d+)s/(\d+)loss/(\d+)drop(?:\((\d+)bb,(\d+)c,(\d+)o\)/(\w+))?", m.group(4)):
            levels[int(lv)] = (int(secs), int(loss), int(drop), int(bb or 0), int(dc or 0), int(do or 0), code)
        runs.append({"seed": m.group(1), "best": int(m.group(2)), "score": int(m.group(3)), "levels": levels})
    if not runs:
        print("no RUNLOG lines yet in", path)
        return
    print("%d runs  best level %d  avg level %.1f  best score %d" % (
        len(runs), max(r["best"] for r in runs), sum(r["best"] for r in runs) / len(runs),
        max(r["score"] for r in runs)))
    agg = defaultdict(lambda: [0, 0, 0, 0, 0, 0, 0])  # visits, secs, losses, drops, bb, centre, outlane
    tables = []
    for r in runs:
        for lv, (secs, loss, drop, bb, dc, do, code) in r["levels"].items():
            a = agg[lv]
            for i, v in enumerate((1, secs, loss, drop, bb, dc, do)):
                a[i] += v
            if code:
                tables.append((loss * 2 + drop, lv, code, r["seed"], secs, loss, drop))
    print("\nlevel  reached  avg time  balls lost  drops  (bounce-back / centre / outlane)")
    for lv in sorted(agg):
        v, secs, loss, drop, bb, dc, do = agg[lv]
        print("%5d  %7d  %7.0fs  %10.2f  %5.2f  (%.1f / %.1f / %.1f)" % (
            lv, v, secs / v, loss / v, drop / v, bb / v, dc / v, do / v))
    if tables:
        tables.sort(reverse=True)
        print("\nhardest individual tables (balls lost x2 + drops):")
        for bad, lv, code, seed, secs, loss, drop in tables[:8]:
            print("  level %2d table %s (seed %s): %ds, %d lost, %d drops" % (lv, code, seed, secs, loss, drop))


if __name__ == "__main__":
    main()
