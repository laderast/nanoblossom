# nanoblossom

A norns script that clones the Mosaic modes of the Hologram Microcosm. A microlooper synced to the clock (MIDI clock by default) captures short fragments of the input, and four mono softcut voices sparsely loop them back at pitched rates through a delay and the norns reverb.

## Controls

| Control | Action |
| --- | --- |
| E1 | Time: fragment subdivision (1/32 to 1 bar) |
| E2 | Activity: number of voices (0–4) and how often they pick up new fragments |
| E3 | Repeats: how many times each fragment repeats (always played in full) |
| K2 hold + E1 | Level |
| K2 hold + E2 | Filter: DJ filter (left is low pass, right is high pass) |
| K2 hold + E3 | Mix: wet/dry between the dry sound (voices and input monitor) and the reverb + delay. Fully right is 100% wet |
| K3 hold + any encoder | Delay time (1–16 sixteenth notes) |
| K2 tap | Next preset (A–D) |
| K3 tap | Reverse on/off |
| K2 hold + K3 | Hold: freeze capture and keep playing the current fragments |

## Presets

- **A**: normal and double speed (octave up)
- **B**: normal and half speed (octave down)
- **C**: double speed only
- **D**: half, normal, double, and quad speed

## Sync

The `Sync` param defaults to **MIDI Clock** and sets the system clock source to MIDI while the script runs. If no clock is arriving, the screen shows "no midi clock". Set `Sync` to **System Clock** to use whatever the norns clock is set to instead.

## Delay time

Hold K3 and turn any encoder (or use the `Delay Time (steps)` param) to set the delay from 1 to 16 sixteenth notes, shown as e.g. `3/16`. It follows the tempo, so echoes stay on the beat.
