"""Play Fairy Ring in TIC-80 and log your runs for human analytics.

    python play.py

Opens TIC-80 (windowed, as normal) with fairy_ring.tic. Everything TIC-80
prints is shown here and appended to logs/runlog.txt; every game over adds
a RUNLOG line (seed, level reached, score, per-level time/losses/drops).
Summarise the log with:  python tests/human_stats.py
"""
import datetime
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TIC = os.environ.get("TIC80", r"C:\Program Files\tic80-v1.3-win.exe")


def main():
    os.makedirs(os.path.join(HERE, "logs"), exist_ok=True)
    log_path = os.path.join(HERE, "logs", "runlog.txt")
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    with open(log_path, "a", encoding="utf-8") as log:
        log.write("SESSION %s\n" % stamp)
        # pass the cart by full path (not --fs): TIC-80 then uses its normal
        # settings folder, so your gamepad / key mapping is kept between runs
        cart = os.path.join(HERE, "fairy_ring.tic")
        p = subprocess.Popen([TIC, "--skip", cart],
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             encoding="utf-8", errors="replace")
        for line in p.stdout:
            sys.stdout.write(line)
            if line.startswith(">"):
                line = line[1:]
            if line.startswith("RUNLOG"):
                log.write(stamp + " " + line)
                log.flush()
        p.wait()
    print("runs logged to", log_path)


if __name__ == "__main__":
    main()
