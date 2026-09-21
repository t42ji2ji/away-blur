#!/usr/bin/env python3
"""Art/*.png + Art/sheets.json -> Sources/AwayBlur/Render/CatFrames.swift.

The sheets are what GPT drew, at 1536x1024 with a 4x4 grid of 384x256 cells.
This cuts them into cells, takes each cell down to a 48x32 grid of art pixels,
pins the feet, and writes the lot out as packed bits in a Swift source file.

Two things here are not obvious and both were paid for:

  The downscale takes the *mode* of each 8x8 block, never the average. An
  average produces mid greys, and a mid grey in a one-bit sprite is a soft
  edge — the one thing the whole cat is built to avoid.

  Animations are placed by their feet, not by their bounding box. An arched
  back or a paw reaching forward stretches the box, so centring the box slides
  the cat sideways under a motion that never moved it; the bottom quarter of
  the ink does not move, so that is what gets measured.

  The offset is one per animation, not one per frame. Pinning every frame
  separately would flatten any vertical motion inside the animation — a
  gallop's extended phase has all four feet off the ground, and a leap is
  nothing but feet off the ground. One offset puts the animation on the same
  ground line as all the others while leaving everything that happens inside
  it alone, which is also why the cat does not hop sideways when one animation
  hands over to the next.

The sheets read a single bit per pixel, `alpha > 128`, and are stored that way:
see the note in sheets.json for what that threw away and why.

Needs Pillow:  python3 -m pip install --user pillow
"""
import json
import pathlib
import sys

from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent
ART = ROOT / "Art"
OUT = ROOT / "Sources/AwayBlur/Render/CatFrames.swift"

AW, AH = 48, 32          # the art grid one cell becomes

# Where every animation's feet go: the middle of the frame, on a ground line
# with three rows of slack under it. Every animation shares these, so the cat
# stays put when one hands over to the next, and `Cat.baseline` is this row.
GROUND = (AW // 2, AH - 4)


def cells(path, cell, block):
    """Every cell of one sheet, as a list of bool rows."""
    image = Image.open(path).convert("RGBA")
    tall = cell * AH // AW          # cells are the art grid's shape, not square
    across, down = image.width // cell, image.height // tall
    alpha = image.split()[-1].load()
    out = []
    for index in range(across * down):
        ox, oy = (index % across) * cell, (index // across) * tall
        grid = []
        for row in range(AH):
            line = []
            for column in range(AW):
                lit = sum(alpha[ox + column * block + dx, oy + row * block + dy] > 128
                          for dy in range(block) for dx in range(block))
                line.append(lit * 2 > block * block)
            grid.append(line)
        out.append(grid)
    return out


def ink(grid):
    return [(c, r) for r in range(AH) for c in range(AW) if grid[r][c]]


def feet(grid):
    """The horizontal centre of the bottom quarter of the ink, and its lowest
    row. Not the bounding box — see the note at the top."""
    points = ink(grid)
    bottom = max(r for _, r in points)
    top = min(r for _, r in points)
    from_row = bottom - max(1, (bottom - top) // 4)
    columns = [c for c, r in points if r >= from_row]
    return sum(columns) // len(columns), bottom


def placed(frames, name, also=()):
    """One offset for the whole animation — see the note at the top.

    `also` rides along on the offset measured from `frames`, which is how the
    blink stays locked to the frame it replaces: measuring it separately would
    let the cat jump a pixel every time it shut its eyes."""
    anchors = [feet(f) for f in frames]
    dx = GROUND[0] - round(sum(a[0] for a in anchors) / len(anchors))
    dy = GROUND[1] - max(a[1] for a in anchors)
    out, lost = [], 0
    for frame in list(frames) + list(also):
        moved = [[False] * AW for _ in range(AH)]
        for c, r in ink(frame):
            if 0 <= c + dx < AW and 0 <= r + dy < AH:
                moved[r + dy][c + dx] = True
            else:
                lost += 1
        out.append(moved)
    if lost:
        print("  warning: %s loses %d pixels off the edge at (%+d,%+d)" % (name, lost, dx, dy))
    return out


def lock(frames, count, columns):
    """`idle` is a loop rather than eight drawings of a sitting cat.

    The sheet does not come back that way: a generation varies the ears, the
    outline of the feet and, in three of the eight cells, the height of an eye
    by one pixel. Any of that flickering eight times a second reads as a cat
    shuffling about, not a cat sitting still. So everything inside the columns
    the cat sits in is taken from the first frame, and only the tail, which
    swings outside them, is left free.

    The blink frames then stop being separate drawings too: each one is the
    frame it replaces with the shut eyes laid into it, so a blink changes the
    rows the eyes are on and nothing else, and the tail carries on its sweep
    while the cat's eyes are closed."""
    low, high = columns
    body = range(low, high + 1)
    awake, shut = frames[:count], frames[count:]
    # What the frames mostly agree on, not what the first of them happens to
    # say: the first frame of this sheet draws one eye a pixel taller than the
    # other, and taking it as the truth would have the cat sit there lopsided
    # for ever rather than blink it away every few frames.
    still = [[sum(frame[row][column] for frame in awake) * 2 > len(awake)
              for column in range(AW)] for row in range(AH)]
    for frame in awake:
        for row in range(AH):
            for column in body:
                frame[row][column] = still[row][column]
    if not shut:
        return awake
    # The eyes are one band of rows. The two sheets also disagree about a foot
    # pixel, and taking that along would move a foot every time the cat blinked,
    # so the widest band wins and the rest is the sheets' own noise.
    closed = [[sum(frame[row][column] for frame in shut) * 2 > len(shut)
               for column in range(AW)] for row in range(AH)]
    apart = {row: sum(closed[row][column] != still[row][column] for column in body)
             for row in range(AH)}
    bands, band = [], []
    for row in sorted(row for row, count in apart.items() if count):
        if band and row != band[-1] + 1:
            bands.append(band)
            band = []
        band.append(row)
    if band:
        bands.append(band)
    eyes = max(bands, key=lambda band: sum(apart[row] for row in band))
    blinked = []
    for frame in awake:
        copy = [line[:] for line in frame]
        for row in eyes:
            for column in body:
                copy[row][column] = closed[row][column]
        blinked.append(copy)
    print("  locked %s to frame 1 outside columns %d-%d; eyes on rows %s"
          % ("idle", low, high, ",".join(map(str, eyes))))
    return awake + blinked


def pack(grid):
    bits = "".join("1" if grid[r][c] else "0" for r in range(AH) for c in range(AW))
    return "%0*x" % ((AW * AH + 3) // 4, int(bits, 2))


def main():
    spec = json.loads((ART / "sheets.json").read_text())
    sheets = {}
    frames, animations = [], []

    for animation in spec["animations"]:
        name = animation["sheet"]
        if name not in sheets:
            sheets[name] = cells(ART / name, spec["cell"], spec["block"])
        first, last = animation["cells"]
        drop = set(animation.get("drop", []))
        cut = [sheets[name][i - 1] for i in range(first, last + 1) if i not in drop]
        shut = []
        if "blink" in animation:
            blinkFirst, blinkLast = animation["blink"]
            shut = [sheets[name][i - 1] for i in range(blinkFirst, blinkLast + 1)]
            assert len(shut) == len(cut), animation["name"] + ": blink cells do not match"
        picked = placed(cut, animation["name"], shut)
        if "still" in animation:
            picked = lock(picked, len(cut), animation["still"])
        span = range(len(frames), len(frames) + len(cut))
        blink = range(span.stop, span.stop + len(shut)) if shut else None
        animations.append((animation, span, blink))
        frames += picked
        print("%-8s %2d frames  %s  cells %d-%d%s%s"
              % (animation["name"], len(cut), name, first, last,
                 "  dropping " + ",".join(map(str, sorted(drop))) if drop else "",
                 "  + %d blink" % len(shut) if shut else ""))

    # The line under the cat hangs off the ground line, not off the bottom of
    # the frame: a 48x32 frame carries slack under the sprite, and measuring
    # from the frame would push the line that much further away.
    baseline = GROUND[1]

    lines = [
        "// Generated by Scripts/make-sprites.py from Art/sheets.json. Do not edit.",
        "//",
        "// %d frames of %dx%d, one bit per art pixel, row major, packed into hex."
        % (len(frames), AW, AH),
        "",
        "extension Cat {",
        "",
        "    static let width = %d" % AW,
        "    static let height = %d" % AH,
        "",
        "    /// The row the resting cat's feet reach. The line under the cat hangs",
        "    /// off this rather than off the bottom of the cell, which carries slack.",
        "    static let baseline = %d" % baseline,
        "",
        "    static let animations: [CatAnimation] = [",
    ]
    for animation, span, blink in animations:
        lines.append(
            '        CatAnimation(name: "%s", fps: %g, loops: %s, frames: %d..<%d, blink: %s, note: "%s"),'
            % (animation["name"], animation["fps"], "true" if animation["loop"] else "false",
               span[0], span[-1] + 1,
               "%d..<%d" % (blink[0], blink[-1] + 1) if blink else "nil",
               animation["note"]))
    lines += ["    ]", "", "    static let packed: [String] = ["]
    for frame in frames:
        lines.append('        "%s",' % pack(frame))
    lines += ["    ]", "}", ""]

    OUT.write_text("\n".join(lines))
    print("\nbaseline row %d" % baseline)
    print("wrote %s (%d frames, %d bytes)"
          % (OUT.relative_to(ROOT), len(frames), OUT.stat().st_size))

    # The same frames again for the review page, so the page and the app can
    # never drift apart over what the cat is doing.
    if "--json" in sys.argv:
        where = pathlib.Path(sys.argv[sys.argv.index("--json") + 1])
        where.write_text(json.dumps({
            "w": AW, "h": AH, "baseline": baseline,
            "anims": [{"name": a["name"], "view": a["view"], "note": a["note"],
                       "loop": a["loop"], "fps": a["fps"],
                       "frames": [pack(frames[i]) for i in span]}
                      for a, span, _ in animations],
        }, separators=(",", ":")))
        print("wrote %s (%d bytes)" % (where, where.stat().st_size))


if __name__ == "__main__":
    sys.exit(main())
