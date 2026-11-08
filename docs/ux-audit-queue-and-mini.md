# UX audit: queue sheet + mini player (Build 337 device screenshot)

Source: user-supplied review of the 2026-11-08 device screenshot
(queue sheet over the play view, song "Overdose").
Triage tags are provisional; work items get claimed one at a time and each
verified on device. `[native]` = the app's own rendering, a tweak may still
be able to influence it; `[ours]` = a tweak hook is a confirmed or likely
cause; `[investigate]` = not yet attributed.

## Layout and alignment

- [investigate] Inconsistent margins: the top mini player sits nearly flush
  against the screen edges (about 5px); the queue panel below has about 25px
  of margin; the song list about 30px. Three different left/right boundaries
  looks messy.
- [investigate] Double-container overlap: the queue panel has a rounded outer
  frame, but the frame stops at the filter chip row and the song list is not
  contained inside it, as if it fell out of the container.
- [ours] The now-playing row's highlight band overflows: the blue highlight on
  the "Overdose" row spans the full screen width, outside the panel frame, and
  there is also an inset card inside it. The gap between the highlight band
  and the next card is too tight. (Likely our row's card/glass styling combined
  with YT's selection highlight.)
- [investigate] Last row thumbnail misaligned: the bottom "CHAooIN" thumbnail
  is further left and appears wider than the other rows' thumbnails.
- [ours] Bottom content clipped: the last row's artist and duration text are
  cut off by the screen bottom; no safe-area leave for the home indicator.
  (Our bottomPad math or the sheet's detent inset.)
- [investigate] Mini player position and spacing: it sits at the very top,
  nearly touching the status bar with little headroom, and only a small gap
  to the panel below. Looks cramped.
- Mini player has no progress bar: [ours by design] the 1pt scrubber line is
  deliberately alpha=0 (LiquidGlass.xm); if we want it visible, style it to
  match the full player's accent bar instead of hiding it.

## Components and styles

- [ours?] "All" chip contrast too low: selected "All" is dark grey text on a
  grey fill, harder to read than the unselected chips. (If our chip styling
  touches the queue filter chips, re-check contrast; otherwise native.)
- [native] The rightmost filter chip ("Explore...") is cut off at the edge.
  Possibly normal horizontal scroll, but there is no fade mask or affordance
  hinting it can scroll.
- [native] The playing indicator covers the artwork: the equalizer icon sits
  on top of the "Overdose" thumbnail and reads as a blurry "I.I.I".
- [ours] The drag-reorder icon ("$") is small and thin; the touch target is
  not obvious. (If we shrink rows or overlap the icon zone, our fault.)
- [ours?] Every row looks like a button: borders and grey fills everywhere,
  tight vertical gaps, heavy and crowded. (Our row card styling, likely.)

## Text and typography

- [native] Long titles crowd the cards: wrapped titles leave three lines
  total but the card height does not grow, text nearly touches the card
  edges top and bottom.
- [native] Title area too tight: the playlist title's right end leaves only a
  tiny gap before the "Save" button.
- [native] Inconsistent artist separators: some use "and", some mix "、" and
  "and".
- [native] Mixed localisation: UI in Traditional Chinese, song titles in
  Japanese, with translated "feat." markers; no spacing handling between
  full-width punctuation and Latin text.
- [native] Icon and label mismatch: the "Save" button's icon is "add to
  playlist" but the label reads "Save".
- [native] Inconsistent corner radii: the mini player's thumbnail is nearly
  square-cornered while the list thumbnails below have obvious rounding.
- [native] Circular artwork inside a square black frame: the mini player's
  cover is a circular disc image on black corners. Either crop the cover
  into a circle or fill the square (aspect fill).
- [native] Same artwork cropped differently in two places: the mini player
  shows the full disc, the list thumbnail crops it closer.
- [native] Inconsistent proportions: mini cover about 133px vs list thumbnail
  about 110px with no proportional correspondence in radius or crop.
- [native] Uneven padding around the cover: about 40px left of the cover but
  only about 15px above/below.

## Notes

- The thick grabber drag fix shipped separately in the same build cycle
  (LyricsSheet.x `ytmu_grabberPan:`): down dismisses, up jumps to the large
  detent; threshold + velocity, finite gesture because iOS exposes no API for
  a custom view to drive a sheet presentation continuously.
