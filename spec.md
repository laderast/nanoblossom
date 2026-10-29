# Nanoblossom: A Microcosm Mosaic Clone

This Norns app builds on the microshimmer code to clone the mosaic modes on the Microcosm pedal. The basis is very similar to microshimmer, but focuses on microloops and sending them through reverb. The implementation should use the softcut library for norns.

Nanoblossom consists of 1 microlooper sync'ed to MIDI clock that captures short snippets of sound that are then played back by three voices. 

## How Mosaic Mode Works

- Real-Time Micro-Looping: It samples your incoming instrument signal (guitar, synth, piano, or violin) on the fly and chops it into tiny fragments or note groups based on the time subdivision.
- Pitch Shifting & Harmonies: It applies pitch shifting and rhythmic resequencing to create lush, shimmering, and melodic accompaniment patterns—even if you only play a single note or a slow drone.
- Reversed Playback: Pressing the mode selector knob lets you reverse the captured granules for a more psychedelic, spacey texture.

## Key Controls & Variations

- *Time* dial controls the subdivision of time based on MIDI clock. 
- *Activity* dial controls the complexity and density of the generated fragments by determining the number of active loopers
- *Repeats* dial governs how long the micro-loops sustain, basically a feedback parameter
- *Reverb* dial: reverb + delay blends seamlessly into the Mosaic algorithm, widening the stereo image and adding depth to the floating particles.
- *Filter* frequency dial is a DJ style filter that ranges from Low Pass to High Pass sweeping through the frequency range
- *Preset* button cycles through the four preset modes
- *Reverse* button reverses playback direction (forward playing by default)

## Preset modes

A: Micro loops play back at normal and double speed for octave up harmonies
B: Loops play back at normal and half speed for an effect one octave below your input
C: All loops play back at double speed
D: Loops play back at half, normal, double, and quad speed. Sounds range from one octave below your input to 2 octaves higher.

## Details

- Code should be based off of `microshimmer.lua` in this repo but be in its separate lua file called `nanoblossom.lua`
- Use the softcut library reference here: https://monome.org/docs/norns/api/modules/softcut.html

## Fixes (0.2)

- Do not play back the loopers all the time - be more sparse, less repetition
- Playback the entire microloop interval
- Make the reverb/delay control a wet/dry one blending the softcut output with the reverb/delay output
- Change the loopers to mono, increase the voices to four

## Fixes (0.3)

- The wet/dry control should be 100% wet all the way to the right
- The chance of starting is now 20–60% depending on Activity

## Fixes (0.4)

- Add delay time as a parameter in terms of time steps from 1 to 16 steps (16th notes)
- Add delay time as a knob by holding K3

## Fixes (0.5)

- Add a preset E that includes a fifth up, an octave up, and two octaves

## Fixes (0.6)

- Include the 1x voice in preset E
- Increase the delay feedback more rapidly with the mix control

## Fixes (0.7)

- Change the bar countdown for each looper to move left to right for forward looping, and right to left for reverse looping

## Fixes (0.8)

- Make the default sync clock MIDI sync. If the MIDI clock does not exist, use the Norns internal default setting (whether it be internal, link, or crow) to sync. 