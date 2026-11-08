# UX audit: full player, mini player, lyrics screen

User-reported screenshots batch (2026-11-08, builds 335-341). Vocab:
"injected" = our views/hooks paint it; "native" = YT's own spec, untouched by
any of our hooks. Status values: SHIPPED (fixed in some shipped build),
[ours] (ours to fix, open), [native] (YT behavior; needs a measured decision
before we fight it), [investigate] (cannot attribute ours vs native from these
screenshots; needs a dump), [pending-dump] (needs fresh device dump data).

Four items from the same report were fixed first and shipped as builds >=342:
grabber live rubber-band (f579725), live push re-lights the highlight
(3073bcd), 60/120 animation fps preference (0eeeea3), seek-bar interpolation
+ mini bar recolor removed (90308c4). The mini-bar item below records only the
part of that report that is still open.

## Full player (figure 1)

| # | Report | Triage | Notes |
|---|--------|--------|-------|
| F1 | Brown-red gradient block y~1575-2240 hard-cut against deep blue elsewhere | [investigate] | Likely YT's own ambient scrims (`YTMGradientScrim`, which ClearRoot deliberately keeps) over a song whose artwork mean is warm; ours only clears. Device observation from Build 345 (the last build with the song-accented seek bar): the accent-colored bar read as clearly DIFFERENT from both the ambient background and the brown block, so the block is NOT a leak of our seek-bar paint. Need a dump tagging which view carries the warm fill before touching it. |
| F2 | Four different left insets (34/57/28/25px) across header / cover+title / transport / bottom panel | [investigate] | Revised: most of those boundaries are YT's own layout of its children -- we paint glass INSIDE existing bounds and reposition almost nothing. Only the bottom panel's inset is ours. Blindly re-framing YT's buttons risks hitting its animation targets; needs the dump's per-view frames first. |
| F3 | Title "Hatsune Miku" cut mid-glyph, half a "u" visible, no ellipsis | [ours] | YTMNowPlayingView's own title restyle (`layoutSubviews` font bump). A size change wedged between YT's label config passes clips mid-glyph. Re-approach: keep YT's font, only weight, or set truncation semantics explicitly. |
| F4 | Title glued to block top edge (~10px) | [ours] | Same restyle pass; needs a top inset before attribution. |
| F5 | Artist name low contrast (grey on the warm block) | [ours] | YTMULyricInk/brightness-derived ink hooked to lyrics, but the full-player artist label is native. If [native], leave; the dump must decide. |
| F6 | Progress-bar has no drag knob, played/track contrast low | SHIPPED (knob only; colors reverted) | The interpolator's display link positions a 12pt injected knob riding the elapsed fill's leading edge (scrubbing itself stays YT's gesture). The SONG-ACCENT RECOLOR was then reviewed out at the user's ask ("don't color the progress bar") -- YT's own fill/track colors stand, frames-only interpolation and the neutral knob remain. |
| F7 | Time text too small/dim, 15px from the transport row | [native] | YTMTimeControl is native layout; we only round it. Needs a deliberate design call before restyling. |
| F8 | Transport row crowded (pause top edge touches the time, 15px below) | [native] | Same. |
| F9 | Shuffle/repeat have no enabled state distinct from default | [native] | YT's own buttons; a state indicator is a feature request first. |
| F10 | Cast button larger circle than collapse/more | [ours] | ApplyCircle caps at 44pt deliberately (wide buttons got pill/squares). Unify the cap or exclude the cast button from the cap. |
| F11 | Uneven vertical spacing (top 120 / cover-title 140 / 100 bottom) | [ours, partially] | The spacing between our injected pieces and YT's layout; needs measured numbers from a dump before shifting anything. |
| F12 | Bottom panel shows only a sliver, title centered, unlike the queue panel's left-aligned style | [ours] | The "adopt playlist" panel is a YT view we clear. Whether the panel is clipped by our sheet chrome or by YT needs a tree from the dump. |
| F13 | Artwork edge has a bright ring | [ours] | YTMPlayerCarouselCell border .8 at white .22 + ApplyDrop shadow. Reduce or remove the border alpha. |
| F14 | "Save" capsule clipped to the first glyph, no fade mask hinting scroll | [native] | Native horizontal chip-overflow behavior; our glass pass paints it the same as its siblings. |

## Mini player + bottom panel (figures 2/3)

| # | Report | Triage | Notes |
|---|--------|--------|-------|
| M1 | Empty panel below, only the drag handle visible, no content or skeleton | [ours?] | Two identical figures = it lasted, not a transient. Suspects: panel view built but its content sink never wired, or our clear pass wiped content YT painted later. Needs a dump mid-state. |
| M2 | Panel inset: mini bar 5px vs panel flush (fig 2/3) vs 25px elsewhere (fig 1) | [ours] | The glass dish inset vs the panel's own margins -- one constant needed. |
| M3 | Panel's top corners overpainted by the mini bar; 8px apart reads as stacked | [ours] | Z-order/offset between the mini bar and the injected panel. |
| M4 | Status bar near-black vs panel dark-blue vs mini bar -- three mismatched background layers | [ours]/[native] | Our dish dither vs YT's surface vs system bar; needs one base tone decision. |
| M5 | Mini title ellipsis at x~800 while the cast button starts at x~950 (150px wasted) | [native] | The swipe carousel metadata width is YT's; our dish counts only inset. Probably leave. |
| M6 | Round cover rotates but its black square base does not | [ours, fixed] | The spinner is NOT ours -- nothing in the tweak rotates an image; it is YT 9.35's mini art. YTMUMiniTree now kills every animation on the art layer each pass (a plain rounded rect re-asserted), and the near-square black containers under the art (<= 72pt) match the tile's radius and drop their fill, so the cover reads as ONE rounded rect on the glass dish ("same rect with rounded"). Not provable from code alone -- if a rotation lives on a container ABOVE the art layer it survives this; verify on device. |
| M7 | Dot-pattern texture on the mini bar and lyrics bg | [ours] | YTMULGApplyDither(.48). Keep or reduce per surface; not all surfaces carry it -- inconsistent by design worth revisiting. |

## Lyrics screen (figures 4/5)

| # | Report | Triage | Notes |
|---|--------|--------|-------|
| L1 | ~185px blank header where tabs should live | [ours] | Our embedded panel header band; tabs were never drawn by us. Either give it YT's tab row or shrink the band. |
| L2 | Blank area hard-cuts against the blurred artwork; cut-y differs between figures (495/507) | [ours, partially] | Layout-order jitter between the pass that clears and the pass that sizes the table header. Needs a stable height (compute once per layout pass, not per tick). |
| L3 | Unsung lyrics very low contrast on the teal blur | SHIPPED (Build 343+) | Distance ladder floor raised: {…0.72, 0.52, 0.28, 0.0} -> {…0.76, 0.62, 0.50, 0.38}. Distant lines stay readable; the active row still pops as the only full-brightness ink. |
| L4 | One wrapped line ("僕もち…") truncated with ellipsis while every other line wraps | [ours] | Truncation is not expected anywhere in the sheet; suspect the fitted-size path producing a max-lines count that turned one row into a clipped label. Reproduce with the same payload before touching. |
| L5 | Line breaks split words (モ/ノトーン, どうす/ればいい) | [native] | UILabel word-wrap has no CJK word segmentation on iOS by default. Real fix = measure-aware own breaking (expensive); leave unless the user insists. |
| L6 | Asymmetric gutters: 157px left vs 105px right | SHIPPED (Build 343, 2cdfd49) | 45/45 at the same sum, so the fitted type size did not move. |
| L7 | Floating button y drifts (770 vs 783) and sits off the text column boundary | [ours] | The retranslate button's y depends on row height; pin it to the text column's trailing edge. |
| L8 | Floating button icon unclear, low contrast | [ours] | Same button; own the ink and a clearer glyph. |
| L9 | Current line sits at 83% (too low, top-heavy) | [ours, pending measured numbers] | AGENTS.md already has the standing note: get real contentOffset/contentSize/bounds from a debug line BEFORE touching the 37% ratio. |
| L10 | Dark shadow around the current line reads dirty | [ours, device check] | 716b99d deleted the dark glow (now the bright ink). If a device still shows a dark box, that is a stale cache or a different shadow -- needs a fresh dump. |
| L11 | Translation grouping unclear (orig->trans 117px vs trans->next 143px) | SHIPPED (Build 343+) | YTMURowPadTop 9 -> 12 (the BETWEEN-groups pad; the translation is the last element inside a cell, so the next cell's top pad IS the group gap). The intra-group gap stays 7pt: taking it down re-opens the "glued into one line" report that raised it. |
| L12 | No bottom fade mask / no safe-area bottom inset | [ours] | Add a gradient mask over the last visible rows and respect the safe area. |
| L13 | No progress bar / time / prev-next in the lyrics screen | [ours, feature] | The landscape toolbar has them; the portrait sheet does not. A feature decision, not a bug. |
| L14 | Per-word highlight cuts mid-glyph ("始" half-filled) | [ours, device check] | The wipe's feather strip width vs the glyph's own advance; needs the [FPS]/wipe debug lines from a device before tuning. |
