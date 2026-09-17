# Away Blur

Frosts the screen when you stop using the Mac, and clears it the moment a hand
comes back. Menu bar app, two looks, everything tunable while you watch it.

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

## The cat

A cat floats in the middle of the frosted screen, and its face is a kaomoji.

The art is text in `Sprite.swift` — `#` is ink, anything else is not — and a
face is a second grid whose ink is cut *out* of the body, the way the eyes of a
paper cut-out are holes rather than marks. There is no asset pipeline: changing
the art means editing characters in the source, and it diffs.

Three rules keep it sharp, and all three have to hold at once:

1. A whole number of screen pixels per art pixel. Never a fraction.
2. The whole sprite lands on a whole screen pixel, including while it is
   drifting — the float is rounded every frame.
3. Nearest sampling. A pixel is a square and it stays a square.

It is drawn dark on a light screen and light on a dark one, decided once from
the picture's own average rather than per pixel, so the shape never breaks up
over a busy background. While it is drifting the display link drops to about
15fps; the screen is not being watched.

```sh
# Every face on one sheet, at the size it is actually drawn.
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --cat ~/Desktop/cats.png
```

Eyes and mouth are separate grids, because that is how a kaomoji is built —
(･ω･) is two eyes and an ω — and because it makes blinking free: swap the eyes
for the closed pair, keep the mouth. The cat blinks for an eighth of a second
every few seconds, never on a metronome.

Eyes stay narrow and a blank row separates them from the mouth. Widen them and
the eyes and the ω run together into one zigzag across the whole face.

## The line under it

One line at a time, arriving letter by letter out of scrambled characters,
sitting long enough to read twice, then eaten from the right. Spaces never
scramble, so the shape of the line is there before the words are.

What it says is whatever is true of a machine nobody is at: how long you have
been gone, the time (the overlay covers the menu bar, so it has to give the
clock back), the battery, whether something you started is still running, and —
from cmux's own state on disk — whether an agent is waiting on you. Plus one
line of the cat's own opinion each time round.

The work lines are left out of the privacy look on purpose. A caption naming
what you are building rather defeats a screen you made unreadable.

The text is a real font rendered small with antialiasing off, which leaves the
glyphs one bit deep, then blown up by the same whole-number rule as the cat. A
9pt system mono at 4x looks like it was drawn on the grid rather than set next
to it.

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
