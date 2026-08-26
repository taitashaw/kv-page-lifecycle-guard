#!/usr/bin/env python3
"""Guard the README's figure block against accidental damage.

The figures are attached by hand: some are files under docs/images/, some are
GitHub user-attachments URLs pasted through the web editor. An edit elsewhere in
the README must never renumber a figure, reorder an embed, change a caption or
drop an <img> tag, because the uploads would then sit under the wrong captions.

    python3 docs/images/check_figures.py --save     # snapshot the current state
    python3 docs/images/check_figures.py            # verify nothing moved

Exit status is non-zero on any difference, so it can gate a commit.
"""
import argparse
import hashlib
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
README = ROOT / "README.md"
SNAP = ROOT / "docs" / "images" / "figures.lock.json"

# markdown embed, or a raw <img> tag, or a figure caption
TOKEN = re.compile(
    r'!\[(?P<alt>[^\]]*)\]\((?P<md>[^)]+)\)'
    r'|<img[^>]*?src="(?P<html>[^"]+)"[^>]*?>'
    r'|\*\*\*Figure (?P<num>\d+)\.\*\*\s*(?P<cap>.*?)\*',
    re.S,
)


def extract():
    """Return the ordered figure record: (n, src, caption-hash, caption-head)."""
    text = README.read_text()
    figs, pending = [], None
    for m in TOKEN.finditer(text):
        src = m.group("md") or m.group("html")
        if src:
            pending = src
            continue
        cap = " ".join(m.group("cap").split())
        figs.append({
            "n": int(m.group("num")),
            "src": pending or "NO-EMBED",
            "src_kind": "repo" if (pending or "").startswith("docs/") else "external",
            "caption_sha": hashlib.sha256(cap.encode()).hexdigest()[:16],
            "caption_head": cap[:70],
        })
        pending = None
    return figs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--save", action="store_true", help="write the snapshot")
    args = ap.parse_args()

    figs = extract()

    # numbering must be 1..N with no gaps, in document order
    seq = [f["n"] for f in figs]
    if seq != list(range(1, len(seq) + 1)):
        print(f"FAIL  figure numbering is not sequential in reading order: {seq}")
        return 2

    if args.save:
        SNAP.write_text(json.dumps(figs, indent=1) + "\n")
        print(f"saved {len(figs)} figures to {SNAP.relative_to(ROOT)}")
        for f in figs:
            print(f"  Figure {f['n']}  {f['src_kind']:<8} {f['src'].split('/')[-1][:44]}")
        return 0

    if not SNAP.exists():
        print(f"FAIL  no snapshot at {SNAP.relative_to(ROOT)}; run with --save first")
        return 2

    old = json.loads(SNAP.read_text())
    if old == figs:
        print(f"OK    {len(figs)} figures unchanged, numbering 1..{len(figs)} in reading order")
        return 0

    print(f"FAIL  figure block changed ({len(old)} -> {len(figs)} figures)")
    for i in range(max(len(old), len(figs))):
        a = old[i] if i < len(old) else None
        b = figs[i] if i < len(figs) else None
        if a == b:
            continue
        print(f"  slot {i + 1}:")
        print(f"    was: {a}")
        print(f"    now: {b}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
