# nanoblossom development steps

## v0.1: initial build from spec.md

I've written `nanoblossom.lua`, a Mosaic clone built on microshimmer's structure, and filled in `README.md`. It passes a Lua syntax check and a smoke run with stand-in norns functions, but it hasn't been run on a norns, so it hasn't been heard.

**How it works**
- **Capture:** voice 4 records one fragment per Time subdivision into a ring of 8 buffer slots. It never overwrites a slot a voice is still playing, so a fragment can keep looping while new ones are captured.
- **Playback:** voices 1–3 each loop a fragment at a speed taken from the current preset. To get the "resequencing," each new fragment is drawn at random from the 4 most recent captures.
- **Delay and reverb:** voices 5–6 are the stereo delay carried over from microshimmer, and the norns reverb provides the long tail.

**Controls**

| Spec dial / button | norns |
|---|---|
| Time (1/32 to 1 bar) | E1 |
| Activity | E2: how many voices may play (0–3) and how often a free voice picks up a new fragment |
| Repeats | E3: how much each fragment fades per subdivision. At 0 it plays once; near 100% it keeps looping for a long time |
| Reverb (plus delay) | K2 hold + E3 |
| Filter (DJ style) | K2 hold + E2: left of centre is low-pass, right is high-pass, centre is off |
| Preset A–D | K2 tap |
| Reverse | K3 tap. It also flips voices that are already playing, so you hear it right away |
| Extra: level / hold | K2 hold + E1 / K2 hold + K3 |

**Choices made where the spec left room**
- **Preset D:** it lists four speeds but there are only three voices, so each voice picks one of the preset's speeds at random every time it starts a new fragment.
- **MIDI clock:** the new `Sync` setting switches the norns clock to MIDI by default, and the original source comes back when the script closes. If no clock is arriving, the screen shows "no midi clock" instead of staying silently blank.
- **Hold:** the Microcosm has a hold/freeze and it was cheap to add, but it wasn't in the spec, so it can be dropped.

**Worth checking on hardware**
- **Filter on the delay:** the filter is applied to the delay voices too. If softcut sends audio between voices after the filter, the delayed sound gets filtered twice, which makes the sweep steeper. That's probably fine for a DJ filter, but listen for it.
- **Very short fragments at high speed:** 1/32 notes at 4× speed are only a few milliseconds long and may click or buzz. The crossfade time (`FADE_TIME`) is the setting to adjust.

## v0.2: fixes from spec.md "Fixes (0.2)"

The four 0.2 fixes are in `nanoblossom.lua`, now v0.2, and the README is updated. It passes a syntax check and a smoke run where the voice timers actually run. It still hasn't been heard on a norns.

**1. Sparser, less repetition**
- Each subdivision, at most one voice can start a new fragment. The chance of starting is now 5–40% depending on Activity; before it was 30–100% for every free voice.
- When a voice finishes, it rests for 1–4 subdivisions before it can start again.
- New fragments are chosen from the recent captures that no voice is playing, and the least-played ones come first. Fresh audio gets used before old fragments are reused.
- Repeats now defaults to 40% instead of 60%.

**2. Whole microloop plays every time**
- Before, the fade was timed to the subdivision grid, so a half-speed voice could be cut off halfway through its fragment.
- Now each voice fades once per full pass of its fragment, so a pass takes twice as long at 0.5× and a quarter as long at 4×.
- On the last pass the voice plays to the end of the fragment and stops, rather than being muted partway through.

**3. Wet/dry mix**
- K2 hold + E3 is now **Mix**. At 50% both the dry sound and the reverb + delay are at full level. Turning it down fades out the wet side, and turning it up fades out the dry side.
- **Catch:** fully wet, the dry voices are silent, so the reverb only hears the delay echoes. The tail starts about a dotted eighth late.

**4. Four mono voices**
- There are now 4 playback voices, and Activity sets how many may play (0–4).
- **Trade-off:** softcut only has 6 voices. 4 players plus the recorder leaves room for just one delay voice, so the delay is now mono and centred.
- The four voices sit at fixed pan positions spread across the stereo field, and the random pan per fragment is gone. If "mono" meant everything panned to the centre, that's a one-line change in `VOICE_PANS`.

**Check on hardware:** the mix assumes the signal softcut sends from a voice into the delay is taken before that voice's own level. If it's taken after the level instead, turning the mix fully wet would also silence the delay, and only the reverb tail would be heard. If that happens, the mix wiring needs to change.

## v0.3: fixes from spec.md "Fixes (0.3)"

Both 0.3 fixes are in `nanoblossom.lua`, now v0.3, and the README's mix line is updated. It passes a syntax check and the smoke run. It still hasn't been heard on a norns.

**1. Mix is 100% wet fully right**
- In v0.2 the voices' dry level already reached 0 at full right. The leftover dry sound was the instrument coming through the norns input monitor, which the mix didn't touch.
- The mix now scales the norns `monitor_level` together with the dry voices, so fully right only the reverb and delay are heard.
- The input monitor still feeds the reverb when fully wet. In the norns mixer (crone `MixerClient.cpp`), `monitor_level` only affects the direct path to the outputs, not the reverb send.
- The monitor level is scaled relative to the user's own setting and restored when the script closes.
- **Still true:** at full wet the reverb hears the delay echoes rather than the voices directly. Softcut's reverb send is taken after the softcut master level, so voices can't feed the reverb without also being heard dry.

**2. Chance of starting is 20–60%**
- `MIN_DENSITY` is now 0.2 and `MAX_DENSITY` is 0.6. The other sparseness rules from v0.2 still apply: at most one new voice per subdivision, and a 1–4 subdivision rest after a voice finishes.

## v0.4: fixes from spec.md "Fixes (0.4)"

The 0.4 fixes are in `nanoblossom.lua`, now v0.4, and the README's controls table and Delay time section are updated. It passes a syntax check, the smoke run, and a check of the delay lengths and K3 behaviour. It still hasn't been heard on a norns.

This section was revised after spec.md's 0.4 section changed. The first pass measured steps in the current Time subdivision; the spec now says 16th notes and asks for a K3 knob.

**Delay time in 16th note steps**
- New param `Delay Time (steps)`, 1 to 16 sixteenth notes, shown as e.g. `3/16`.
- It follows the tempo but not the Time setting: at 120 bpm, 1 step is 0.125 s and 16 steps (one bar) is 2 s.
- The default is 3 steps, a dotted eighth, the same as the fixed delay from earlier versions.
- The longest allowed delay is 16 s, enough for one bar down to 15 bpm.

**Delay time knob on K3**
- Hold K3 and turn any encoder to change the delay time. While K3 is held, the bottom of the screen shows `delay time` and its value.
- A plain K3 tap still toggles reverse. If an encoder was turned while K3 was held, releasing K3 doesn't toggle reverse.
- If K2 is also held, the encoders control K2's layer (level, filter, mix) instead.

## v0.5: fixes from spec.md "Fixes (0.5)"

The 0.5 fix is in `nanoblossom.lua`, now v0.5, and the README's controls table and preset list are updated. It passes a syntax check, the smoke run, and a check that K2 taps cycle A through E. It still hasn't been heard on a norns.

**Preset E**
- Each voice picks one of three speeds per fragment: a fifth up (7 semitones, about 1.5×), an octave up (2×), or two octaves up (4×).
- Unlike A–D, it has no normal-speed (1×) voice, since the spec lists only those three intervals. Adding 1× is a one-number change in the `PRESETS` table.
- K2 taps now cycle A → B → C → D → E → A, and the header comment and README say A–E.

**Screen labels for the fifth**
- The voice lanes used to round speeds down to whole numbers, so a fifth would have shown as `1x`. Speeds that aren't whole numbers now show one decimal place, e.g. `1.5x` (`-1.5x` reversed). Half speed still shows as `.5x`.
- The voice lanes are 4 pixels narrower to make room for the longer label.

## v0.6: fixes from spec.md "Fixes (0.6)"

Both 0.6 fixes are in `nanoblossom.lua`, now v0.6, and the README's preset list is updated. It passes a syntax check, the smoke run, and a check of the delay feedback at several mix settings. It still hasn't been heard on a norns.

**1. Preset E includes 1×**
- Each voice now picks from four speeds per fragment: normal (1×), a fifth up (about 1.5×), an octave up (2×), or two octaves up (4×).

**2. Delay feedback rises faster with the mix**
- Before, feedback rose in a straight line from 0 at 0% mix to its maximum (0.6) at 50% mix.
- Now it reaches 0.6 at 25% mix, so it climbs twice as fast: 0.24 at 10% mix and 0.6 from 25% up.
- The maximum is unchanged, so the echoes don't sustain any longer at high mix settings. To get longer tails, raise `DELAY_MAX_FEEDBACK`; values close to 1 make the echoes ring almost indefinitely.
- Only feedback changed. The delay's volume and the reverb send still reach full at 50% mix.

## v0.7: fixes from spec.md "Fixes (0.7)"

The 0.7 fix is in `nanoblossom.lua`, now v0.7. It passes a syntax check. It still hasn't been seen on a norns screen.

This section was revised after spec.md's 0.7 section was corrected. The first pass changed only reverse, because the spec then said "right to left" for both directions.

**Bar countdown follows the play direction**
- Going forward, each voice's bar is now pinned to the right and shrinks left to right as the loop fades, moving the same way as the `fwd>` arrow.
- In reverse, the bar is pinned to the left and shrinks right to left, matching `<rev`. This is how every bar moved before v0.7.
- Pressing reverse flips bars that are already counting down, not just new ones.

## v0.8: fixes from spec.md "Fixes (0.8)"

The 0.8 fix is in `nanoblossom.lua`, now v0.8, and the README's Sync section is updated. It passes a syntax check and a stubbed run of the clock switching, starting from each of the four norns clock sources. It still hasn't been run on a norns with a real MIDI clock.

This section was revised after spec.md's 0.8 section changed. The first pass always fell back to the internal clock; the spec now says to use the norns clock setting, whether internal, link, or crow.

**MIDI clock by default, the norns clock setting when none is arriving**
- `Sync` still defaults to **MIDI Clock**. Before, that forced the system clock source to MIDI, so with no MIDI clock connected the loops never started and the screen showed "no midi clock".
- The script now listens on all 16 MIDI ports for clock ticks. While they're arriving, the clock source is MIDI. If none arrive for 2 seconds, it switches back to the clock source the norns was set to before the script started (internal, link, or crow). It switches to MIDI again as soon as ticks return.
- If the norns was already set to MIDI, the fallback is internal, since MIDI clock isn't arriving.
- The script starts on the fallback source and moves to MIDI within a frame of the first tick, so a connected MIDI clock takes over right away.
- The screen header shows the tempo followed by the source in use: `midi`, `int`, `link`, or `crow`. "no clock" now only appears if the clock itself stops ticking, for example with crow selected and no crow clock input.
- `Sync` set to **System Clock** works as before: the script uses whatever clock source the norns was set to. That setting is restored when the script exits.
- Many MIDI devices keep sending clock while their transport is stopped. In that case the script stays on MIDI clock.
