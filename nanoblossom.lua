-- nanoblossom v0.7
--
-- microcosm-style mosaic:
-- a clock-synced microlooper
-- whose fragments bloom
-- through four pitched voices
-- and a delay + long reverb
--
-- E1: time (subdivision)
-- E2: activity
-- E3: repeats
-- K2 hold + E1: level
-- K2 hold + E2: filter
-- K2 hold + E3: wet/dry mix
-- K3 hold + any enc: delay time
--
-- K2 tap: next preset (A-E)
-- K3 tap: reverse on/off
-- K2 hold + K3: hold (freeze)
--
-- syncs to midi clock by
-- default (PARAMS > Sync)
--
-- based on microshimmer

local ControlSpec = require "controlspec"

local NUM_VOICES = 4
-- finest subdivision (a 32nd note), in beats
local TICK_DIV = 1/8
-- time subdivisions, as ticks per fragment
local TIMES = {
  {name = "1/32", ticks = 1},
  {name = "1/16", ticks = 2},
  {name = "1/8", ticks = 4},
  {name = "1/4", ticks = 8},
  {name = "1/2", ticks = 16},
  {name = "1 bar", ticks = 32},
}
local DEFAULT_TIME = 3
-- preset modes: playback rates each voice picks from on every new fragment
local PRESETS = {
  {name = "A", rates = {1, 2}},
  {name = "B", rates = {0.5, 1}},
  {name = "C", rates = {2}},
  {name = "D", rates = {0.5, 1, 2, 4}},
  -- normal, a fifth up (7 semitones), an octave up, and two octaves up
  {name = "E", rates = {1, 2 ^ (7 / 12), 2, 4}},
}
-- fragments are captured into a ring of slots, so a voice can keep looping
-- its fragment while the recorder moves on to fresh ones
local NUM_SLOTS = 8
-- seconds reserved per slot (holds one bar down to 15 bpm)
local SLOT_LEN = 16
local SLOT_START = {}
for i = 1, NUM_SLOTS do
  SLOT_START[i] = 1 + (i - 1) * (SLOT_LEN + 1)
end
-- new fragments are drawn from this many of the most recent captures,
-- which resequences the input rhythmically
local RESEQ_DEPTH = 4
local FADE_TIME = 0.005
-- a sustaining voice stops once its envelope would decay below this
local MIN_ENV = 0.05
-- envelope multiplier per pass with repeats all the way up
local MAX_DECAY = 0.95
-- chance per subdivision that a free voice starts, at no and full activity
local MIN_DENSITY = 0.2
local MAX_DENSITY = 0.6
-- subdivisions a voice rests after it finishes, before it may start again
local MIN_REST = 1
local MAX_REST = 4
local VOICE_PANS = {-0.5, -0.15, 0.15, 0.5}
-- voices 1-4 play fragments, voice 5 records
local REC_VOICE = 5
-- voice 6 is a mono delay fed by the players, in its own buffer area
local DELAY_VOICE = 6
local DELAY_START = SLOT_START[NUM_SLOTS] + SLOT_LEN + 1
-- delay time, in 16th note steps
local DELAY_STEP_BEATS = 1/4
local MAX_DELAY_STEPS = 16
local DEFAULT_DELAY_STEPS = 3
-- longest delay, in seconds (one bar down to 15 bpm)
local DELAY_MAX_SEC = 16
-- delay level and feedback when the mix is fully wet
local DELAY_MAX_LEVEL = 0.7
local DELAY_MAX_FEEDBACK = 0.6
-- the mix at which delay feedback reaches its max, so it builds quickly
local FEEDBACK_FULL_MIX = 0.25
-- dj filter cutoff ranges, in hz
local LP_MAX_FC = 18000
local LP_MIN_FC = 80
local HP_MIN_FC = 20
local HP_MAX_FC = 8000
local FILTER_RQ = 1.2
local FILTER_DEADZONE = 0.02
-- clock_source option for midi in the system clock params
local CLOCK_SOURCE_MIDI = 2
-- seconds without a clock tick before the screen warns about it
local CLOCK_TIMEOUT = 2
local SCREEN_FRAMERATE = 15

local voices = {}
local slot_dur = {}
-- how many times each slot's current fragment has been started by a voice
local slot_plays = {}
-- completed slots, newest first
local history = {}
local next_slot = 1
local recording = false
local rec_slot
local rec_dur
local rec_start_beat
local last_tick_time = 0
local k2_held = false
local k2_used = false
local k3_held = false
local k3_used = false
local tick_clock_id
local screen_metro
local saved_params = {}

-- Helpers

local function time_ticks()
  return TIMES[params:get("time")].ticks
end

local function frag_dur()
  return math.min(time_ticks() * TICK_DIV * clock.get_beat_sec(), SLOT_LEN)
end

local function reversed()
  return params:get("reverse") == 2
end

local function frozen()
  return params:get("hold") == 2
end

-- activity sets how many voices may play (0-4) and how likely a free voice
-- is to pick up a new fragment each subdivision
local function active_voices()
  return math.ceil(params:get("activity") * NUM_VOICES)
end

local function density()
  return MIN_DENSITY + (MAX_DENSITY - MIN_DENSITY) * params:get("activity")
end

local function decay()
  return params:get("repeats") * MAX_DECAY
end

-- the mix crossfades with both sides at full in the middle
local function dry_amount()
  return math.min(1, 2 * (1 - params:get("mix")))
end

local function wet_amount()
  return math.min(1, 2 * params:get("mix"))
end

local function amp_to_db(amp)
  if amp <= 0.0001 then return -math.huge end
  return 20 * math.log(amp, 10)
end

local function rate_name(rate)
  local r = math.abs(rate)
  local s
  if r == 0.5 then
    s = ".5x"
  elseif r == math.floor(r) then
    s = math.floor(r) .. "x"
  else
    s = string.format("%.1fx", r)
  end
  return rate < 0 and "-" .. s or s
end

-- set a system param, remembering its prior value so cleanup can restore it
local function set_system_param(id, value)
  if params.lookup[id] == nil then return end
  if saved_params[id] == nil then
    saved_params[id] = params:get(id)
  end
  params:set(id, value)
end

local function restore_system_param(id)
  if saved_params[id] ~= nil then
    params:set(id, saved_params[id])
  end
end

local function slot_in_use(slot)
  for v = 1, NUM_VOICES do
    if voices[v].busy and voices[v].slot == slot then return true end
  end
  return false
end

local function remove_from_history(slot)
  for i = #history, 1, -1 do
    if history[i] == slot then table.remove(history, i) end
  end
end

-- Init

function init()
  math.randomseed(os.time())
  for v = 1, NUM_VOICES do
    voices[v] = {busy = false, slot = nil, env = 0, rate = 1, rest = 0}
  end

  init_softcut()
  init_params()
  init_reverb()
  params:bang()

  tick_clock_id = clock.run(tick_loop)

  screen_metro = metro.init()
  screen_metro.event = function() redraw() end
  screen_metro:start(1 / SCREEN_FRAMERATE)
end

function init_softcut()
  set_system_param("cut_input_adc", 0)
  set_system_param("cut_input_eng", -math.huge)
  set_system_param("cut_input_tape", -math.huge)

  softcut.buffer_clear()
  for v = 1, 6 do
    softcut.enable(v, 0)
    softcut.level_input_cut(1, v, 0)
    softcut.level_input_cut(2, v, 0)
    for src = 1, 6 do
      softcut.level_cut_cut(src, v, 0)
    end
  end

  -- mono players, spread a little across the stereo field
  for v = 1, NUM_VOICES do
    softcut.enable(v, 1)
    softcut.buffer(v, 1)
    softcut.level(v, 0)
    -- slew smooths the per-pass envelope steps
    softcut.level_slew_time(v, 0.02)
    softcut.pan(v, VOICE_PANS[v])
    softcut.rate(v, 1)
    softcut.rate_slew_time(v, 0)
    softcut.fade_time(v, FADE_TIME)
    softcut.loop(v, 1)
    softcut.loop_start(v, SLOT_START[1])
    softcut.loop_end(v, SLOT_START[1] + 0.1)
    softcut.position(v, SLOT_START[1])
    softcut.rec(v, 0)
    softcut.play(v, 1)
  end

  softcut.enable(REC_VOICE, 1)
  softcut.buffer(REC_VOICE, 1)
  softcut.level(REC_VOICE, 0)
  softcut.rate(REC_VOICE, 1)
  softcut.fade_time(REC_VOICE, FADE_TIME)
  softcut.recpre_slew_time(REC_VOICE, 0.01)
  softcut.rec_level(REC_VOICE, 1)
  -- pre_level 0 overwrites, so each capture replaces the slot's old fragment
  softcut.pre_level(REC_VOICE, 0)
  softcut.rec(REC_VOICE, 0)
  softcut.play(REC_VOICE, 1)

  -- the delay voice records the players and plays back what it wrote one
  -- loop ago, so the loop length is the delay time and pre_level the feedback
  softcut.enable(DELAY_VOICE, 1)
  softcut.buffer(DELAY_VOICE, 1)
  softcut.pan(DELAY_VOICE, 0)
  softcut.level(DELAY_VOICE, 0)
  softcut.level_slew_time(DELAY_VOICE, 0.02)
  softcut.rate(DELAY_VOICE, 1)
  softcut.fade_time(DELAY_VOICE, FADE_TIME)
  softcut.loop(DELAY_VOICE, 1)
  softcut.loop_start(DELAY_VOICE, DELAY_START)
  softcut.position(DELAY_VOICE, DELAY_START)
  softcut.recpre_slew_time(DELAY_VOICE, 0.01)
  softcut.rec_level(DELAY_VOICE, 1)
  softcut.pre_level(DELAY_VOICE, 0)
  softcut.rec(DELAY_VOICE, 1)
  softcut.play(DELAY_VOICE, 1)
end

function init_params()
  params:add_separator("nanoblossom")

  local time_names = {}
  for i, t in ipairs(TIMES) do
    time_names[i] = t.name
  end
  local preset_names = {}
  for i, p in ipairs(PRESETS) do
    preset_names[i] = p.name
  end
  local percent = function(param) return math.floor(param:get() * 100 + 0.5) .. "%" end

  params:add {
    id = "time",
    name = "Time",
    type = "option",
    options = time_names,
    default = DEFAULT_TIME,
  }
  params:add {
    id = "activity",
    name = "Activity",
    type = "control",
    controlspec = ControlSpec.new(0, 1, "lin", 0.01, 0.5, ""),
    formatter = percent,
  }
  params:add {
    id = "repeats",
    name = "Repeats",
    type = "control",
    controlspec = ControlSpec.new(0, 1, "lin", 0.01, 0.4, ""),
    formatter = percent,
  }
  params:add {
    id = "mix",
    name = "Mix (Reverb + Delay)",
    type = "control",
    controlspec = ControlSpec.new(0, 1, "lin", 0.01, 0.5, ""),
    formatter = function(param)
      return math.floor(param:get() * 100 + 0.5) .. "% wet"
    end,
    action = function() apply_mix() end
  }
  params:add {
    id = "delay_steps",
    name = "Delay Time (steps)",
    type = "number",
    min = 1,
    max = MAX_DELAY_STEPS,
    default = DEFAULT_DELAY_STEPS,
    formatter = function(param) return param:get() .. "/16" end,
    action = function() set_delay_time() end
  }
  params:add {
    id = "filter",
    name = "Filter",
    type = "control",
    controlspec = ControlSpec.new(-1, 1, "lin", 0.01, 0, ""),
    formatter = function(param) return filter_string(param:get()) end,
    action = function(value) set_filter(value) end
  }
  params:add {
    id = "level",
    name = "Level",
    type = "control",
    controlspec = ControlSpec.new(0, 1, "lin", 0.01, 0.8, ""),
    formatter = percent,
    action = function()
      for v = 1, NUM_VOICES do apply_voice_level(v) end
    end
  }
  params:add {
    id = "preset",
    name = "Preset",
    type = "option",
    options = preset_names,
    default = 1,
  }
  params:add {
    id = "reverse",
    name = "Reverse",
    type = "option",
    options = {"Off", "On"},
    default = 1,
    action = function() apply_direction() end
  }
  params:add {
    id = "hold",
    name = "Hold (Freeze)",
    type = "option",
    options = {"Off", "On"},
    default = 1,
  }
  params:add {
    id = "input_mode",
    name = "Input",
    type = "option",
    options = {"Left", "Sum L+R"},
    default = 2,
    action = function(value) set_input_routing(value) end
  }
  params:add {
    id = "sync",
    name = "Sync",
    type = "option",
    options = {"System Clock", "MIDI Clock"},
    default = 2,
    action = function(value)
      if value == 2 then
        set_system_param("clock_source", CLOCK_SOURCE_MIDI)
      else
        restore_system_param("clock_source")
      end
    end
  }
end

function init_reverb()
  -- use the built-in norns reverb with as long a tail as it allows
  -- (params:set clamps to each param's max)
  set_system_param("reverb", 2)
  set_system_param("rev_return_level", 0)
  set_system_param("rev_low_time", 16)
  set_system_param("rev_mid_time", 16)
end

-- Clock

function tick_loop()
  while true do
    clock.sync(TICK_DIV)
    last_tick_time = util.time()
    -- derive the tick from the beat count so subdivisions stay on the grid
    local t = math.floor(clock.get_beats() / TICK_DIV + 0.5)
    if t % time_ticks() == 0 then
      on_division()
    end
  end
end

function on_division()
  -- capture first so a voice starting now can pick up the fresh fragment
  if recording then
    finish_recording()
  end
  if not frozen() then
    begin_recording()
  end
  maybe_start_voice()
  -- keep the delay time in step with tempo changes
  set_delay_time()
end

-- Recording

function begin_recording()
  -- take the next slot no voice is looping (4 voices, 8 slots: one is free)
  local slot = next_slot
  while slot_in_use(slot) do
    slot = slot % NUM_SLOTS + 1
  end
  next_slot = slot % NUM_SLOTS + 1
  remove_from_history(slot)

  rec_slot = slot
  rec_dur = frag_dur()
  rec_start_beat = clock.get_beats()
  local start = SLOT_START[slot]
  -- loop off: the head stops at loop_end, so we record exactly one fragment
  softcut.loop(REC_VOICE, 0)
  softcut.loop_start(REC_VOICE, start)
  softcut.loop_end(REC_VOICE, start + rec_dur)
  softcut.position(REC_VOICE, start)
  softcut.rec(REC_VOICE, 1)
  recording = true
end

function finish_recording()
  softcut.rec(REC_VOICE, 0)
  recording = false
  -- if time got shorter mid-capture, only keep what was actually written
  local elapsed = (clock.get_beats() - rec_start_beat) * clock.get_beat_sec()
  local dur = math.min(rec_dur, elapsed)
  if dur < FADE_TIME * 4 then return end
  slot_dur[rec_slot] = dur
  slot_plays[rec_slot] = 0
  table.insert(history, 1, rec_slot)
  while #history > NUM_SLOTS do
    table.remove(history)
  end
end

function set_input_routing(mode)
  softcut.level_input_cut(1, REC_VOICE, mode == 2 and 0.7 or 1)
  softcut.level_input_cut(2, REC_VOICE, mode == 2 and 0.7 or 0)
end

-- Voices

-- once per subdivision, at most one free, rested voice may start a fragment,
-- which keeps the texture sparse
function maybe_start_voice()
  local candidates = {}
  for v = 1, NUM_VOICES do
    local voice = voices[v]
    if not voice.busy then
      if voice.rest > 0 then
        voice.rest = voice.rest - 1
      elseif v <= active_voices() then
        table.insert(candidates, v)
      end
    end
  end
  if #candidates > 0 and math.random() < density() then
    trigger_voice(candidates[math.random(#candidates)])
  end
end

-- pick among the most recent captures no voice is playing, preferring the
-- ones played least, so fragments get resequenced without repeating much
local function pick_slot()
  local best, fewest = {}, math.huge
  for i = 1, math.min(RESEQ_DEPTH, #history) do
    local slot = history[i]
    if not slot_in_use(slot) then
      local plays = slot_plays[slot]
      if plays < fewest then
        best, fewest = {slot}, plays
      elseif plays == fewest then
        table.insert(best, slot)
      end
    end
  end
  if #best == 0 then return nil end
  return best[math.random(#best)]
end

function trigger_voice(v)
  local slot = pick_slot()
  if not slot then return end
  local voice = voices[v]
  local rates = PRESETS[params:get("preset")].rates
  voice.rate = rates[math.random(#rates)]
  voice.slot = slot
  voice.env = 1
  voice.busy = true
  slot_plays[slot] = slot_plays[slot] + 1

  local start = SLOT_START[slot]
  local stop = start + slot_dur[slot]
  local rate = reversed() and -voice.rate or voice.rate
  softcut.loop_start(v, start)
  softcut.loop_end(v, stop)
  softcut.loop(v, 1)
  softcut.rate(v, rate)
  softcut.position(v, rate < 0 and stop or start)
  apply_voice_level(v)

  -- one pass plays the whole fragment at this voice's rate
  voice.clock = clock.run(sustain_voice, v, slot_dur[slot] / voice.rate)
end

-- repeat the fragment pass by pass, fading by repeats each time; the last
-- pass runs to the end of the fragment and stops, so it is never cut short
function sustain_voice(v, pass_sec)
  local voice = voices[v]
  while true do
    local last = voice.env * decay() < MIN_ENV
    if last then
      softcut.loop(v, 0)
    end
    clock.sleep(pass_sec)
    if last then
      voice.clock = nil
      release_voice(v)
      return
    end
    voice.env = voice.env * decay()
    apply_voice_level(v)
  end
end

function release_voice(v)
  local voice = voices[v]
  if voice.clock then
    clock.cancel(voice.clock)
    voice.clock = nil
  end
  voice.busy = false
  voice.slot = nil
  voice.env = 0
  voice.rest = math.random(MIN_REST, MAX_REST)
  apply_voice_level(v)
end

-- the dry level goes straight out; the delay send is set separately (it is
-- taken before the voice level), and follows the same envelope
function apply_voice_level(v)
  local voice = voices[v]
  local amp = voice.busy and voice.env * params:get("level") or 0
  softcut.level(v, amp * dry_amount())
  softcut.level_cut_cut(v, DELAY_VOICE, amp * wet_amount())
end

-- flip sounding voices too, so the reverse button is heard right away
function apply_direction()
  for v = 1, NUM_VOICES do
    local voice = voices[v]
    if voice.busy then
      softcut.rate(v, reversed() and -voice.rate or voice.rate)
    end
  end
end

-- Setters

-- wet/dry: the dry side is the players' direct output and the input monitor,
-- the wet side is the delay plus the reverb send (rising together). fully
-- right, nothing dry is heard: the monitor level is applied after the
-- reverb's monitor send, so muting it doesn't change what the reverb hears
function apply_mix()
  local wet = wet_amount()
  if params.lookup["monitor_level"] then
    -- scale relative to the user's own monitor level, restored on cleanup
    local base = saved_params["monitor_level"] or params:get("monitor_level")
    set_system_param("monitor_level", base + amp_to_db(dry_amount()))
  end
  set_system_param("rev_cut_input", amp_to_db(wet))
  softcut.level(DELAY_VOICE, wet * DELAY_MAX_LEVEL)
  local feedback = math.min(1, params:get("mix") / FEEDBACK_FULL_MIX)
  softcut.pre_level(DELAY_VOICE, feedback * DELAY_MAX_FEEDBACK)
  for v = 1, NUM_VOICES do
    apply_voice_level(v)
  end
end

-- the delay is a whole number of 16th notes, following the tempo
function set_delay_time()
  local step_sec = DELAY_STEP_BEATS * clock.get_beat_sec()
  local sec = math.min(params:get("delay_steps") * step_sec, DELAY_MAX_SEC)
  softcut.loop_end(DELAY_VOICE, DELAY_START + sec)
end

-- dj filter: left of center is low pass closing down, right is high pass
-- opening up, center is off
local function filter_fc(x)
  if x < 0 then
    return LP_MAX_FC * (LP_MIN_FC / LP_MAX_FC) ^ (-x)
  end
  return HP_MIN_FC * (HP_MAX_FC / HP_MIN_FC) ^ x
end

function filter_string(x)
  if math.abs(x) < FILTER_DEADZONE then return "off" end
  local fc = filter_fc(x)
  local hz = fc >= 1000 and string.format("%.1fk", fc / 1000) or math.floor(fc + 0.5)
  return (x < 0 and "LP " or "HP ") .. hz
end

function set_filter(x)
  local off = math.abs(x) < FILTER_DEADZONE
  for v = 1, NUM_VOICES + 2 do
    if v ~= REC_VOICE then
      softcut.post_filter_dry(v, off and 1 or 0)
      softcut.post_filter_lp(v, (not off and x < 0) and 1 or 0)
      softcut.post_filter_hp(v, (not off and x > 0) and 1 or 0)
      softcut.post_filter_bp(v, 0)
      softcut.post_filter_br(v, 0)
      softcut.post_filter_rq(v, FILTER_RQ)
      softcut.post_filter_fc(v, filter_fc(x))
    end
  end
end

-- Interaction

function enc(n, d)
  if k2_held then
    k2_used = true
    local ids = {"level", "filter", "mix"}
    params:delta(ids[n], d)
  elseif k3_held then
    k3_used = true
    params:delta("delay_steps", d)
  else
    local ids = {"time", "activity", "repeats"}
    params:delta(ids[n], d)
  end
end

function key(n, z)
  if n == 2 then
    if z == 1 then
      k2_held = true
      k2_used = false
    else
      k2_held = false
      if not k2_used then
        params:set("preset", params:get("preset") % #PRESETS + 1)
      end
    end
  elseif n == 3 then
    k3_held = z == 1
    if z == 1 then
      if k2_held then
        k2_used = true
        k3_used = true
        params:set("hold", 3 - params:get("hold"))
      else
        k3_used = false
      end
    elseif not k3_used then
      params:set("reverse", 3 - params:get("reverse"))
    end
  end
end

-- Screen

function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  draw_header()
  draw_preset()
  draw_voices()
  draw_slots()
  draw_footer()
  screen.update()
end

-- tempo (or a missing clock warning), sync source, capture state
function draw_header()
  screen.move(0, 6)
  if util.time() - last_tick_time > CLOCK_TIMEOUT then
    screen.level(15)
    screen.text(params:get("sync") == 2 and "no midi clock" or "no clock")
  else
    screen.level(4)
    screen.text(math.floor(clock.get_tempo() + 0.5) .. " bpm"
      .. (params:get("sync") == 2 and " midi" or ""))
  end
  screen.move(128, 6)
  if frozen() then
    screen.level(15)
    screen.text_right("HOLD")
  else
    screen.level(recording and 10 or 4)
    screen.text_right("rec")
  end
end

-- big preset letter with play direction underneath
function draw_preset()
  screen.level(15)
  screen.font_size(16)
  screen.move(2, 26)
  screen.text(PRESETS[params:get("preset")].name)
  screen.font_size(8)
  screen.level(reversed() and 15 or 4)
  screen.move(0, 37)
  screen.text(reversed() and "<rev" or "fwd>")
end

-- one lane per voice: envelope bar and playback rate.
-- the bar shrinks left to right going forward, right to left in reverse
function draw_voices()
  local x0, w = 26, 76
  local active = active_voices()
  for v = 1, NUM_VOICES do
    local y = 10 + (v - 1) * 7
    local voice = voices[v]
    screen.level(v <= active and 2 or 1)
    screen.rect(x0, y, w, 5)
    screen.fill()
    if voice.busy then
      screen.level(12)
      local fill = math.max(1, math.floor(w * voice.env + 0.5))
      screen.rect(reversed() and x0 or x0 + w - fill, y, fill, 5)
      screen.fill()
      screen.level(15)
      screen.move(128, y + 5)
      screen.text_right(rate_name(reversed() and -voice.rate or voice.rate))
    end
  end
end

-- the slot ring: recording, recent captures, and slots voices are looping
function draw_slots()
  local x0 = 26
  for s = 1, NUM_SLOTS do
    local level = 1
    if recording and s == rec_slot then
      level = 15
    elseif slot_in_use(s) then
      level = 10
    else
      for i = 1, math.min(RESEQ_DEPTH, #history) do
        if history[i] == s then level = 4 end
      end
    end
    screen.level(level)
    screen.rect(x0 + (s - 1) * 10, 40, 8, 2)
    screen.fill()
  end
end

-- the three dials on the current layer (K2 held shows the second layer)
function draw_footer()
  if k3_held and not k2_held then
    screen.level(4)
    screen.move(64, 52)
    screen.text_center("delay time")
    screen.level(15)
    screen.move(64, 62)
    screen.text_center(params:string("delay_steps"))
    return
  end
  local labels, values
  if k2_held then
    labels = {"level", "filter", "mix"}
    values = {params:string("level"), params:string("filter"), params:string("mix")}
  else
    labels = {"time", "activity", "repeats"}
    values = {params:string("time"), params:string("activity"), params:string("repeats")}
  end
  local xs = {21, 64, 107}
  for i = 1, 3 do
    screen.level(4)
    screen.move(xs[i], 52)
    screen.text_center(labels[i])
    screen.level(15)
    screen.move(xs[i], 62)
    screen.text_center(values[i])
  end
end

-- Cleanup

function cleanup()
  if tick_clock_id then
    clock.cancel(tick_clock_id)
    tick_clock_id = nil
  end
  for v = 1, NUM_VOICES do
    if voices[v].clock then
      clock.cancel(voices[v].clock)
      voices[v].clock = nil
    end
  end
  if screen_metro then
    metro.free(screen_metro.id)
    screen_metro = nil
  end
  for id, value in pairs(saved_params) do
    params:set(id, value)
  end
end
