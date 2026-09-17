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

The mip chain is the hardware one, not `MPSImageGaussianPyramid`. The Gaussian
pyramid is the nicer filter, but its levels sit half a texel off what a mipmap
sampler expects, so the whole picture slides towards the bottom right by about
half the blur radius as it goes out of focus — 31px at radius 64, plainly
visible. `--measure` reports it.

**The window.** Borderless, at `CGShieldingWindowLevel()`, joins all spaces, never
takes focus or clicks. It goes up already holding a sharp copy of the screen, so
there is no seam when it appears.

## The two looks

**Privacy** — 110px blur, sunk 45% towards black, up in 0.45s and gone in 0.14s.
Nothing is readable.

**Ambient** — 55px blur, barely dimmed, washed 35% towards the picture's own
average colour, 1.6s in and 0.8s out. You can still tell what is under there.

Switch in the menu bar. Each look keeps its own numbers.

## Build

Needs Xcode 16 or later. Plain Swift package, no dependencies.

```sh
Scripts/build.sh --run     # builds dist/Away Blur.app and launches it
Scripts/blurctl on         # put the blur up, to look at it
Scripts/blurctl off
tail -f ~/Library/Logs/AwayBlur.log

# Renders a soft blob at a range of radii and reports where its centre of mass
# ended up. A blur must not move the picture. Anything above a tenth of a pixel
# below radius 128 is a bug.
"dist/Away Blur.app/Contents/MacOS/AwayBlur" --measure
```

The build is signed with a self-signed `Away Blur Dev` identity from the login
keychain. That is only so Screen Recording survives a rebuild: TCC remembers the
grant against the signature, and an ad-hoc one changes every time.

Screen Recording has to be granted in System Settings → Privacy & Security →
Screen & System Audio Recording. Nothing is written to disk or sent anywhere; the
still lives in a Metal texture and dies when the blur clears.

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
