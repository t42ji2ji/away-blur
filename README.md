# Away Blur

Frosts the screen when you stop using the Mac, and clears it the moment a hand
comes back. Menu bar app, two looks, everything tunable while you watch it.

Download it from [awayblur.dorara.app](https://awayblur.dorara.app) or the
[latest release](https://github.com/t42ji2ji/away-blur/releases/latest).

## How it works

**Deciding you are gone.** Seconds since the last keyboard or mouse event
(`CGEventSourceSecondsSinceLastEventType`, no permission needed), vetoed by any
app currently holding a `PreventUserIdleDisplaySleep` power assertion. That veto
is the whole trick: anything playing video or running a call takes one of those
out, which is exactly the case where idle seconds is wrong — you are sitting
right there, watching, and the keyboard has not moved in ten minutes.

What that misses is reading and thinking, so there is a second veto behind it.
Once the idle clock has run out, the front camera is opened for a moment and
Vision is asked whether there is a face in frame; if there is, the screen is
left alone and the camera is not asked again for a minute. It is off until you
turn it on, it can only hold the blur back and never cause it, and every failure
— no camera, no permission, the lid shut — counts as nobody. The session is
closed the instant it has an answer, so the green light is a blink rather than
a state; keeping it open would be a lie about what the app is doing.

Vision finds faces, not open eyes. Nothing public can tell you reliably whether
someone is looking at the screen, so the question it actually answers is whether
there is still a person in front of the Mac.

**The picture.** One ScreenCaptureKit still per display, taken at the moment you
go, uploaded to a mipmapped texture. No live stream: the picture is frozen
anyway, so paying 30 frames a second for it would be waste.

The still goes in at its own size in the top left of a texture whose sides are
multiples of 256, with the last row and column stretched into the margin. Both
halves of that matter, and `--measure` shows why. Mip levels are the level above
halved and *rounded down*, so an odd size loses half a texel and that level's
grid sits half a texel off the original; it compounds, and the picture pulls
apart as the radius grows — 14px at radius 240. Scaling the still to fit instead
of padding it fixes the same problem, but then level zero is a resampled copy of
the screen rather than the screen, and the overlay blinks as it arrives.

**The blur.** A blur of radius *r* is a trilinear sample at mip level `log2(r)`,
plus a 3×3 tent of taps to hide the steps between levels. That makes the radius
free to change per frame, which is the point: the ramp from sharp to frosted is a
real defocus, not a cross-fade between a sharp copy and a blurred one. Cross-fades
show both images at once and read as ghosting, especially on text.

The averaging happens on the values the screen shows, not on light: the texture
is `bgra8Unorm`, not `bgra8Unorm_srgb`. With the sRGB format the sampler hands
the shader linear light, and a white pixel averaged with a black one comes back
at half the light — which still reads as bright. Everything bright then swells
into the dark around it as the radius grows, by 15 or 20px at radius 20, and on
a dark screen with a bright panel in one corner the whole picture looks like it
is sliding that way. It is what a real lens does and it is wrong here.

That also makes measurement subtle: an edge's midpoint only survives a blur in
the space the averaging happened in, so `--edges` converts to linear before it
looks. Measuring the sRGB bytes tilts every edge towards its darker side and
reports drift that is not there.

The mip chain is the hardware one, not `MPSImageGaussianPyramid`. The Gaussian
pyramid is the nicer filter, but its levels sit half a texel off what a mipmap
sampler expects, so the whole picture slides towards the bottom right by about
half the blur radius as it goes out of focus — 31px at radius 64, plainly
visible. `--measure` reports it.

**The window.** Borderless, at `CGShieldingWindowLevel()`, joins all spaces, never
takes focus or clicks. It goes up at alpha zero holding a sharp copy of the
screen, and only fades in — over 80ms, across two pictures that are the same
picture — once that first frame is actually scheduled. The ramp starts after
that. Taking the screen over in one step instead is visible however exact the
copy is, and the layer's own first `frame` assignment animates from nothing,
which reads as the whole screen scaling into place.

Going away is not reversible. The fade-out runs to the end whatever happens
during it: with a 0.8s fade, standing still for half a second in the middle is
enough to satisfy the idle rule again, and the screen climbs back up under a
hand that is already on the keyboard.

## The two looks

**Privacy** — 110px blur, sunk 45% towards black, up in 0.45s and gone in 0.14s.
Nothing is readable.

**Ambient** — 55px blur, barely dimmed, washed 35% towards the picture's own
average colour, 1.6s in and 0.8s out. You can still tell what is under there.

Switch in the menu bar. Each look keeps its own numbers, except the idle delay
and the camera, which answer whether anyone is there and so belong to neither.

## Build

Needs Xcode 16 or later. Plain Swift package, no dependencies.

```sh
Scripts/build.sh --run     # builds dist/Away Blur.app and launches it
Scripts/blurctl on         # put the blur up, to look at it
Scripts/blurctl off
tail -f ~/Library/Logs/AwayBlur.log

# A blur must not move the picture. --edges renders a corner block and reports
# where its two straight edges ended up; --measure does the same with a soft
# blob and its centre of mass. Anything above a tenth of a pixel below radius
# 128 is a bug. --shot puts the real screen through the pipeline and writes the
# frames out, for when the numbers and the eyes disagree.
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --edges
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --measure
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --shot ~/Desktop

# Opens the camera once and says what it saw, with the frame count, so "nobody
# there" can be told apart from "the camera never delivered a frame".
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --camera
```

The build is signed with a self-signed `Away Blur Dev` identity from the login
keychain. That is only so Screen Recording survives a rebuild: TCC remembers the
grant against the signature, and an ad-hoc one changes every time.

Screen Recording has to be granted in System Settings → Privacy & Security →
Screen & System Audio Recording. Nothing is written to disk or sent anywhere; the
still lives in a Metal texture and dies when the blur clears.

## Release

```sh
Scripts/release.sh             # dist/Away-Blur.dmg: universal, Developer ID, notarized
Scripts/release.sh --publish   # and a GitHub release tagged from Info.plist's version
```

The release build is signed with the Developer ID and the hardened runtime,
which refuses the camera unless `Resources/AwayBlur.entitlements` asks for it.
Notarization reads a keychain profile, saved once with
`xcrun notarytool store-credentials away-blur`.

The site is `site/`, plain files with no build step, on Cloudflare Pages. It
draws the app's own cat and letters: `Scripts/make-site-art.py` copies them
out of `CatFrames.swift` and `PixelFont.swift` into `site/art.js`, so run it
after the art or the font changes.

```sh
npx wrangler pages deploy site --project-name away-blur --branch main
```

## The cat

A cat sits in the middle of the frosted screen and does something with itself
every twenty seconds or so, because nobody is watching.

It used to be a grid of characters written by hand in `Sprite.swift` — `#` was
ink — with a kaomoji face cut out of it as holes. That could hold exactly one
shape: a rounded block with ears. No legs, no tail, so the only motion
available was moving the whole block, and a whole block moving is a jitter
rather than an action.

So the frames are drawn now. `Art/` holds the sheets, each one a single image
generation from one locked character reference, laid out as a 4x4 grid of
384x256 cells. `Scripts/make-sprites.py` takes each cell down to a 48x32 grid
of art pixels and writes `CatFrames.swift`: thirteen animations, 110 frames,
169KB of texture built once and kept. Changing the art means replacing a sheet
and running the script, not editing characters in the source.

Two things in that script are not obvious and both were paid for. The
downscale takes the **mode** of each 8x8 block and never the average — an
average makes mid greys, and a mid grey in a one-bit sprite is a soft edge.
And each animation is placed by its **feet**, with one offset for the whole
animation rather than one per frame. The bounding box is no use: an arched
back or a paw reaching forward stretches it, so centring the box slides the
cat sideways under a motion that never moved it. Per-animation rather than
per-frame is what leaves a gallop's float and a leap's arc where they were
drawn, and it is also why the cat does not hop sideways when one animation
hands over to the next.

Three rules keep it sharp, and all three have to hold at once:

1. A whole number of screen pixels per art pixel. Never a fraction.
2. The whole sprite lands on a whole screen pixel, including while it is
   shaking — every offset is rounded before it is used.
3. Nearest sampling. A pixel is a square and it stays a square.

The frame is 48x32 and the cat is about 21x22 of it; the slack is there so a
leap has somewhere to go. That means `Its size` in the panel sets the height of
the *frame*, so the default is 20% of the screen rather than the old 12%, and
the cat inside it comes out the same size it always was.

It still never quite sits still: a boil of half a pixel, rerolled three times
a second. The rate is the whole of it — every frame is noise, nine times a
second is a buzz, three reads as a drawing that will not settle. A whole pixel
was the first default and it was too much: with the body finally locked, the
boil was the only thing left moving, and at that size it read as the cat
shifting about rather than as a line that will not settle. `Its jitter` in the
panel sets how far, and zero holds it perfectly still.

It is drawn dark on a light screen and light on a dark one, decided once from
the picture's own average rather than per pixel, so the shape never breaks up
over a busy background. While it is moving the display link drops to about
15fps; the screen is not being watched.

## What it does

Resting is `idle`, and in it the body, the head, the ears and the feet are
identical in every frame, pixel for pixel. Only the tail moves, sweeping out
to one side and back across the feet. The first attempt at it asked for a
breath and an ear flick and a tail sweep all at once and came back as eight
slightly different drawings of a sitting cat: the head lurched from side to
side and the body dropped four art pixels — forty-eight screen pixels —
between two frames. This is the animation that is on screen almost all the
time, so it is the one that has to be a loop rather than eight pictures, and
locking everything except one moving part is what makes it one.

Asking for that is not the same as getting it. The sheet that came back still
varies the ears, the outline of the feet and, in three of the eight cells, the
height of an eye by a pixel, and any of that at eight frames a second reads as
a cat shuffling rather than sitting. So `idle` carries a `still` span in
`sheets.json` — the columns the cat sits in — and `make-sprites.py` takes
everything inside them from the first frame, leaving only the tail, which
swings outside them, free to move. The blink frames are then built rather than
drawn: each one is the frame it replaces with the shut eyes laid into it, so a
blink changes the four rows the eyes are on and nothing else, and the tail
carries on its sweep while they are closed.

It blinks, an eighth of a second every few seconds and never on a metronome.
That used to be free: the face was a second grid cut out of the body, so
swapping the eyes cost nothing. The face is drawn into the art now, so the
blink had to be drawn too — `idle` carries the same eight frames again with
the eyes shut, and it is the only animation worth eight extra frames for it.

Every twelve to thirty seconds it does one thing instead and goes back:
stretch, shake, yawn, flop, roll, situp, paw at the frost, walk, run, pounce.
After ten minutes away it lies down, `sleep` becomes the resting state, and
from there the beats come every ninety seconds to four minutes and only the
ones a cat does lying down are left. A cat that galloped across the screen
every twenty seconds and lay straight back down would not read as asleep.

`bristle` is the one with a job. When a cmux session starts waiting on you the
cat crouches and then snaps into an arch, fur out, tail straight up — frame
three to frame four is a total redraw, which is what being startled looks
like. That is the part you notice from across a room; the line only tells you
which session once you have looked. The shake rides on top of it, the
technique lifted from the pet in
[bili-open-live](https://github.com/t42ji2ji): a random offset decaying on the
square of the time left, so it starts hard and settles instead of rattling
evenly to the end, rounded to whole screen pixels per display because a
fraction of a pixel would soften the art for as long as it lasted.

Nothing transitions into anything. Every beat is a cut, which at this size and
eight frames a second reads as a cat changing its mind rather than as a bug.
The frame clock is wall time and not display link ticks, because the link is
down at 15fps while the cat is the only thing moving and counting ticks would
play a 12fps gallop at 15.

Two animations did not survive the size, and they are worth recording so
nobody tries them again. A full 360-degree turn chasing its tail came back as
sixteen unrelated drawings: 60 to 90% of the pixels change between
neighbouring frames, against 46% for the walk cycle. Kneading with the front
paws, seen from the front, does not move enough pixels to see at all. What
works at 48x32 is whole-body deformation and cyclic leg motion; what fails is
turning, fine limb work, and anything whose entire signal is a two-pixel arc.

Two rules came out of getting those wrong. When an animation fails, change the
pose or the camera rather than the wording — a yawn read from the front is
nothing and read from the side is obvious. And ask for one thing to change per
frame: every animation here that asked for two or three at once came back
jittering, and the fix was never a longer prompt.

```sh
# Every animation, one row each, every frame at the size it is drawn.
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --cat ~/Desktop/cats.png

# Half an hour of the cat with no screen at all: what it did and when. The
# beats are half a minute apart and it does not lie down for ten minutes, so
# this is the only way to see whether the rest of it happens.
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --beats 30
```

## The line under it

One line at a time, arriving letter by letter out of scrambled characters,
sitting long enough to read twice, then eaten from the right. Spaces never
scramble, so the shape of the line is there before the words are.

What it says is whatever is true of a machine nobody is at: how long you have
been gone, the time (the overlay covers the menu bar, so it has to give the
clock back), the battery, how much of the CPU and the memory is in use, whether
something you started is still running, and — from cmux's own state on disk —
whether an agent is waiting on you. Plus one line of the cat's own opinion each
time round.

The work lines are left out of the privacy look on purpose. A caption naming
what you are building rather defeats a screen you made unreadable.

The text is a 5x7 font drawn by hand on the same grid as the cat, then
emboldened the way bitmap faces always have been: every stem drawn again one
column to the right. The counters stay open because the shapes were designed
with three pixels of air in them. A real typeface shrunk to nine pixels with
antialiasing off is a *squashed* typeface, not a drawn one — the stems land
where they land, and the letters come out uneven next to art that was placed
pixel by pixel.

```sh
# The whole alphabet at drawing size, to see what bolding did to the counters.
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --font ~/Desktop/font.png
```

```sh
# What it would say right now, for both looks.
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --lines
# The cat and a line at the size they are actually drawn.
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --scene ~/Desktop/scene.png
```

## Taking the screen now

**⌃⌥⌘B** frosts it without waiting out the idle clock — registered through
Carbon, because an `NSEvent` global monitor would cost an Accessibility
permission to watch every keystroke on the machine in order to catch one. From
there it behaves like the real thing: a hand on the keyboard takes it back,
after a four second grace long enough to let go of the keys and stand up. The
camera is not consulted; you asked.

## Tuning

Menu bar → Settings… opens a panel that floats *above* the overlay, so the
sliders stay usable while the screen behind them is frosted. Turn on **Hold the
blur up while I tune** and every slider takes effect on the next frame.

## A preview is never a mode you can get stuck in

The overlay sits above the menu bar and ignores the mouse, so while it is up
there is no interface to reach. The real blur is safe because any key or any
movement takes it down. A preview that ignored input the same way had to be
escaped by rebooting, so: a preview also goes away the moment you touch
anything, except while the settings panel is open — and then the panel is on
screen, above the overlay, with the toggle on it. Anything that takes the
overlay down ends the preview with it, and nothing may put it back up inside a
second.

## Credit

The technique — mip level chosen by radius, tent of trilinear taps, and the
overlay window settings — is how [mac-duo](https://github.com/ninobc/mac-duo)
(MIT, Nino Bouchedid) does its fold. Away Blur is a much smaller thing: no lid
sensor, no re-projection, no live capture.
