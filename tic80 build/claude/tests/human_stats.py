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
        for lv, secs, loss, drop in re.findall(r"(\d+):(\d+)s/(\d+)loss/(\d+)drop", m.group(4)):
            levels[int(lv)] = (int(secs), int(loss), int(drop))
        runs.append({"seed": m.group(1), "best": int(m.group(2)), "score": int(m.group(3)), "levels": levels})
    if not runs:
        print("no RUNLOG lines yet in", path)
        return
    print("%d runs  best level %d  avg level %.1f  best score %d" % (
        len(runs), max(r["best"] for r in runs), sum(r["best"] for r in runs) / len(runs),
        max(r["score"] for r in runs)))
    agg = defaultdict(lambda: [0, 0, 0, 0])  # visits, secs, losses, drops
    for r in runs:
        for lv, (secs, loss, drop) in r["levels"].items():
            a = agg[lv]
            a[0] += 1
            a[1] += secs
            a[2] += loss
            a[3] += drop
    print("\nlevel  reached  avg time  balls lost  drops   (per run that reached it)")
    for lv in sorted(agg):
        v, secs, loss, drop = agg[lv]
        print("%5d  %7d  %7.0fs  %10.2f  %5.2f" % (lv, v, secs / v, loss / v, drop / v))


if __name__ == "__main__":
    main()
