# Shed's look, from Sunburst

References made with `gpt-image-2.6-sunburst`; the app implements them in SwiftUI and Core Animation.

- `stills/`: component sheets (sidebar, controls, transcript, composer, new session, panels, states, home, mobile).
  The mobile sheet puts the context bar above the composer; the app keeps the composer as it was on iPhone.
- `motion/`: 512×512 GIF references for each animation, frame sheets in `motion/sheets/`.
- `redo/`: real screenshots of the app (`shots/`) and Sunburst's cleaned-up redraws of them (`out/`), used to find gaps.

Scripts (need `OPENAI_API_KEY` in the environment): `still.py <name>`, `motion.py <name>`, `redo.py <name> <shot> [notes]`.

## Background

`Views/Dither.swift` renders the ground once per size, off the main thread, cached: square dots on a 2 pt grid with
a one-pixel gap. A curved beam sweeps through a corner (not across the middle): a thin red-orange warm edge with a
soft fringe, cream, then cyan and blue thinning out into scattered dots. Everywhere else, dim dots in grey, red, green
or blue. `Backdrop(beam:anchor:grain:)` sets its strength, where it passes, and how busy the dark noise is (lower
behind text). Glass cards (`.card`) blur what's behind them, so text never sits on raw dots; the transcript has a
dark reading band. Core Animation adds a 7 s breath and a glint gliding along the curve; Reduce Motion keeps it still.

## Motion

| Animation | Spec |
| --- | --- |
| Running | ripple ring out of the agent mark, 1.4 s |
| Needs you | orange pulse, 1.6 s |
| Selection | glides on a spring (response 0.4, damping 0.8) |
| Tool expand | chevron turns, spring opens the row, lines fade in staggered |
| Send → stop | send dips, stop appears as a glass circle with a spinning blue arc |
| Question card | rises from the composer, options 60 ms apart, dot pulses |
| Home cards | rise 12 pt, 80 ms apart; contribution columns light up in turn |
| Thinking / compacting | shimmer in blue / violet |
