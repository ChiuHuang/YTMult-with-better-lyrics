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
- [ours 339] The now-playing row's highlight band overflows: the blue highlight on
  the "Overdose" row spans the full screen width, outside the panel frame, and
  there is also an inset card inside it. The gap between the highlight band
  and the next card is too tight. (SHIPPED: the stock full-width selection
  band is hidden; our inset card carries the highlight.)
- [investigate] Last row thumbnail misaligned: the bottom "CHAooIN" thumbnail
  is further left and appears wider than the other rows' thumbnails.
- [investigate -> likely normal] Bottom content clipped: the last row's artist
  and duration text are cut off by the screen bottom. The queue's content
  inset already reserves 92pt at the bottom (QueueLiquidGlassV2.xm contentInset
  bottom), so the likelier reading is that the sheet is a half-screen detent
  and rows continue below -- a mid-scroll state, not clipped chrome. Confirm
  on device by scrolling to the end; if the LAST row is still clipped with the
  list at its end, re-open this item.
- [investigate] Mini player position and spacing: it sits at the very top,
  nearly touching the status bar with little headroom, and only a small gap
  to the panel below. Looks cramped.
- [SHIPPED 339] Mini player has no progress bar: the 1pt scrubber line was
  deliberately invisible; it is now raised to 2pt at the bar's bottom edge and
  coloured like the full player's scrubber (elapsed = song accent, unplayed =
  white .25).

## Components and styles

- [pending-dump] "All" chip contrast too low: selected "All" is dark grey text
  on a grey fill, harder to read than the unselected chips. No hook of ours
  paints chip TEXT colour anywhere (the only chip hooks paint fills/borders,
  and the home chip hook is gated on homeV2Enabled), so this is likely the
  app's own selected-chip styling. Needs a dump of the queue chip row before
  attributing or fixing.
- [native] The rightmost filter chip ("Explore...") is cut off at the edge.
  Possibly normal horizontal scroll, but there is no fade mask or affordance
  hinting it can scroll.
- [native] The playing indicator covers the artwork: the equalizer icon sits
  on top of the "Overdose" thumbnail and reads as a blurry "I.I.I".
- [native] The drag-reorder icon ("=") is small and thin; the touch target is
  not obvious. (Initial triage said ours-if-we-overlap-the-icon-zone, but the
  queue card is an INSET view added behind the content -- the icon's size and
  weight are the app's drawable unchanged.)
- [SHIPPED 339] Every row looks like a button: row card fill .10 -> .07 and
  border alpha .34 -> .20 (song-hued when the cover has colour). Tight vertical
  gaps remain the app's layout.

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
