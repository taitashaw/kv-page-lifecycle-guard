#!/usr/bin/env python3
"""Render the captured ILA violation as a video.

This is a VISUALISATION OF MEASURED DATA, not a screen recording. Every sample
comes from vivado/g10_violation.csv, which Hardware Manager wrote from the ILA
on the ZCU104. Nothing here is synthesised or idealised: the playhead walks the
real 1024-sample window and the annotations read the real probe values.

Screen capture is not available on this host: the session is Wayland, so
ffmpeg -f x11grab records a black XWayland root window, and GNOME's
org.gnome.Shell.Screencast dbus API accepts the call, returns success, then
writes an empty file for a non-interactive caller.

    python3 vivado/render_violation_video.py

Writes docs/video/violation.mp4.
"""
import csv
import pathlib
import subprocess
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[1]
CSV = ROOT / "vivado" / "g10_violation.csv"
OUT = ROOT / "docs" / "video" / "violation.mp4"
FRAMES = ROOT / "docs" / "video" / "_frames"

# probe suffix -> (label, is_bus)
ROWS = [
    ("dbg_reuse_req",          "reuse_req",   False),
    ("dbg_reuse_grant",        "reuse_grant", False),
    ("dbg_reuse_refused",      "reuse_refused", False),
    ("dbg_evictable",          "evictable",   False),
    ("dbg_refcount[7:0]",      "refcount",    True),
    ("dbg_reservation[7:0]",   "reservation", True),
    ("dbg_inflight[5:0]",      "inflight",    True),
    ("dbg_fill_pending[3:0]",  "fill_pending", True),
    ("dbg_sticky[7:0]",        "sticky",      True),
]

BG, FG, GRID = "#0b0f14", "#d7e0ea", "#1e2833"
GREEN, RED, AMBER = "#3ddc84", "#ff5c5c", "#ffb340"


def load():
    rows = list(csv.reader(open(CSV)))
    hdr = [h.strip() for h in rows[0]]
    data = rows[2:]

    def col(suffix):
        m = [i for i, h in enumerate(hdr) if h.endswith(suffix)]
        if len(m) != 1:
            sys.exit(f"probe {suffix!r} resolved to {len(m)} columns")
        return m[0]

    trig = col("TRIGGER")
    series = {}
    for suffix, label, is_bus in ROWS:
        i = col(suffix)
        series[label] = np.array([int(r[i].strip(), 16) for r in data])
    tidx = next(n for n, r in enumerate(data) if r[trig].strip() == "1")
    return series, tidx, len(data)


def main():
    series, tidx, n = load()
    grant = series["reuse_grant"]
    infl = series["inflight"]
    assert grant[tidx] == 1, "trigger sample is not a grant; wrong capture"
    print(f"  {n} samples, trigger at {tidx}: grant={grant[tidx]} inflight={infl[tidx]}")

    FRAMES.mkdir(parents=True, exist_ok=True)
    for f in FRAMES.glob("*.png"):
        f.unlink()

    fps, hold = 30, 45
    sweep = 300                      # frames spent walking the window
    total = sweep + hold
    x = np.arange(n)

    for k in range(total):
        pos = min(int((k / sweep) * n), n - 1) if k < sweep else n - 1
        fig, axes = plt.subplots(len(ROWS), 1, figsize=(12.8, 7.2), sharex=True,
                                 facecolor=BG,
                                 gridspec_kw={"hspace": 0.0, "left": 0.16,
                                              "right": 0.98, "top": 0.88, "bottom": 0.08})
        fired = pos >= tidx
        for ax, (_, label, is_bus) in zip(axes, ROWS):
            v = series[label][: pos + 1]
            ax.set_facecolor(BG)
            for s in ax.spines.values():
                s.set_color(GRID)
            ax.set_yticks([])
            ax.set_xlim(0, n)
            ax.tick_params(colors=FG, labelsize=8)
            colour = GREEN
            if label == "reuse_grant" and fired:
                colour = RED
            if label == "sticky" and fired:
                colour = AMBER
            if is_bus:
                hi = max(series[label].max(), 1)
                ax.set_ylim(-0.25 * hi, 1.35 * hi)
                ax.step(x[: pos + 1], v, where="post", color=colour, lw=1.4)
                ax.fill_between(x[: pos + 1], 0, v, step="post", color=colour, alpha=0.16)
            else:
                ax.set_ylim(-0.3, 1.5)
                ax.step(x[: pos + 1], v, where="post", color=colour, lw=1.8)
            ax.axvline(tidx, color=RED if fired else GRID, lw=1.0,
                       ls="--", alpha=0.9 if fired else 0.5)
            ax.axvline(pos, color=FG, lw=0.9, alpha=0.75)
            ax.set_ylabel(label, color=FG, fontsize=9, rotation=0,
                          ha="right", va="center", labelpad=10,
                          fontfamily="monospace")
            ax.grid(axis="x", color=GRID, lw=0.5)

        axes[-1].set_xlabel("ILA sample (1024-deep window, trigger at 512)",
                            color=FG, fontsize=9)

        if not fired:
            title = "ARMED   waiting for:  reuse_grant == 1  AND  inflight != 0"
            sub = "safe mode, CTRL bit 2 clear.  Every reuse request is REFUSED."
            tc = GREEN
        else:
            title = "VIOLATION CAPTURED"
            sub = (f"interlock removed (CTRL bit 2).  grant=1 while inflight="
                   f"{infl[tidx]}, evictable=0, refcount=00.  sticky bit 7 latched.")
            tc = RED
        fig.text(0.16, 0.955, title, color=tc, fontsize=15,
                 fontweight="bold", fontfamily="monospace")
        fig.text(0.16, 0.917, sub, color=FG, fontsize=9.5, fontfamily="monospace")
        fig.text(0.98, 0.955, "ZCU104  xczu7ev  187.5 MHz", color=FG, fontsize=8.5,
                 ha="right", alpha=0.65, fontfamily="monospace")

        fig.savefig(FRAMES / f"f{k:05d}.png", dpi=100, facecolor=BG)
        plt.close(fig)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-framerate", str(fps),
         "-i", str(FRAMES / "f%05d.png"),
         "-c:v", "libx264", "-preset", "slow", "-crf", "20",
         "-pix_fmt", "yuv420p", str(OUT)], check=True)
    for f in FRAMES.glob("*.png"):
        f.unlink()
    FRAMES.rmdir()
    print(f"  wrote {OUT.relative_to(ROOT)}  ({OUT.stat().st_size/1e6:.2f} MB, "
          f"{total/fps:.1f}s)")


if __name__ == "__main__":
    main()
