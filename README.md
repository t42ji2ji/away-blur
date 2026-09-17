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
go, uploaded to a mipmapped texture, and run through `MPSImageGaussianPyramid`.
No live stream: the picture is frozen anyway, so paying 30 frames a second for it
would be waste.

**The blur.** A blur of radius *r* is a trilinear sample at mip level `log2(r)`,
plus a 3×3 tent of taps to hide the steps between levels. That makes the radius
free to change per frame, which is the point: the ramp from sharp to frosted is a
real defocus, not a cross-fade between a sharp copy and a blurred one. Cross-fades
show both images at once and read as ghosting, especially on text.

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
Scripts/blurctl on         # hold the blur up, to tune the look
Scripts/blurctl off
tail -f ~/Library/Logs/AwayBlur.log
```

Screen Recording has to be granted in System Settings → Privacy & Security →
Screen & System Audio Recording. Nothing is written to disk or sent anywhere; the
still lives in a Metal texture and dies when the blur clears.

## Tuning

Menu bar → Settings… opens a panel that floats *above* the overlay, so the
sliders stay usable while the screen behind them is frosted. Turn on **Hold the
blur up while I tune** and every slider takes effect on the next frame.

## Credit

The blur technique — Gaussian pyramid, mip level by radius, tent of trilinear
taps — is how [mac-duo](https://github.com/ninobc/mac-duo) (MIT, Nino Bouchedid)
does its fold, along with the overlay window settings. Away Blur is a much
smaller thing: no lid sensor, no re-projection, no live capture.
