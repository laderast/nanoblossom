-- microshimmer v0.2
--
-- clock-synced bar sampler
-- with three mono slice
-- players and long reverb
--
-- E1: reverb send + delay
-- K3 hold + E1: switch page
--
-- steps page:
-- E2: move step cursor
-- E3: slice at cursor (- = silent)
-- rate page:
-- E2: select row
-- E3: row step rate
--
-- K2 tap: start/stop player
-- K2 hold + E2: player pitch
-- K2 hold + E3: player level
-- K3 tap: record every bar on/off
-- K3 hold + E3: row length
-- K2 hold + K3: clear row
--
-- based on samthree by @laderast

local ControlSpec = require "controlspec"

local NUM_PLAYERS = 3
local MAX_STEPS = 16
local NUM_SLICES = 16
local BEATS_PER_BAR = 4
-- finest step division (a 32nd note), in beats
local TICK_DIV = 1/8
local TICKS_PER_BAR = BEATS_PER_BAR / TICK_DIV
-- step rates per row, as ticks per step (all divide a bar evenly)
local RATES = {
  {name = "1/32", ticks = 1},
  {name = "1/16", ticks = 2},
  {name = "1/8", ticks = 4},
  {name = "1/4", ticks = 8},
  {name = "1/2", ticks = 16},
}
local DEFAULT_RATE = 2
-- seconds reserved per capture region (holds one bar down to 12 bpm)
local REGION_LEN = 20
-- two regions: players read the last full bar while the recorder writes the other
local REGION_START = {1, 1 + REGION_LEN + 1}
local FADE_TIME = 0.005
-- pitch steps in octaves, as semitones from the recorded pitch
local PITCHES = {
  {name = "-2oct", semis = -24},
  {name = "-1oct", semis = -12},
  {name = "0", semis = 0},
  {name = "1oct", semis = 12},
  {name = "2oct", semis = 24},
}
local DEFAULT_PITCH = 3
local DEFAULT_PANS = {-0.5, 0, 0.5}
-- players use voices 1-3, so voice 4 is always free to record
local REC_VOICE = 4
-- voices 5 and 6 are a stereo delay of the players, in their own buffer area
local DELAY_VOICES = {5, 6}
local DELAY_START = REGION_START[2] + REGION_LEN + 1
-- delay time, in steps at the default step rate
local DELAY_STEPS = 4
-- delay level and feedback when the reverb send is all the way up
local DELAY_MAX_LEVEL = 0.6
local DELAY_MAX_FEEDBACK = 0.7
local SCREEN_FRAMERATE = 15
local ROW_Y = {9, 22, 35}
local BOX_W = 8
local BOX_H = 11
local PAGES = {"steps", "rate"}

local page = 1
local slices = {}
local playing = {true, false, false}
local cur_step = {1, 1, 1}
-- whether each player's current step is still sounding, and the clock that ends it
local gate_open = {false, false, false}
local gate_clock = {}
local cursor_p = 1
local cursor_s = 1
local active_region = 1
local captured_dur
local recording = false
local rec_region
local rec_dur
local k2_held = false
local k2_used = false
local k3_held = false
local k3_used = false
local tick_clock_id
local screen_metro
local saved_params = {}

-- Helpers

local function bar_dur()
  return math.min(clock.get_beat_sec() * BEATS_PER_BAR, REGION_LEN)
end

local function loop_dur()
  return captured_dur or bar_dur()
end

local function num_steps(p)
  return params:get("steps_" .. p)
end

local function player_rate(p)
  return 2 ^ (PITCHES[params:get("pitch_" .. p)].semis / 12)
end

local function step_slice(p)
  return slices[p][cur_step[p]] or 0
end

local function amp_to_db(amp)
  if amp <= 0.0001 then return -math.huge end
  return 20 * math.log(amp, 10)
end

-- set a system param, remembering its prior value so cleanup can restore it
local function set_system_param(id, value)
  if params.lookup[id] == nil then return end
  if saved_params[id] == nil then
    saved_params[id] = params:get(id)
  end
  params:set(id, value)
end

local function clear_row(p)
  for s = 1, MAX_STEPS do
    slices[p][s] = 0
  end
end

-- give `count` random steps of a row a random slice from 1..max_slice
local function randomize_row(p, count, max_slice)
  clear_row(p)
  local order = {}
  for s = 1, MAX_STEPS do order[s] = s end
  for i = MAX_STEPS, 2, -1 do
    local j = math.random(i)
    order[i], order[j] = order[j], order[i]
  end
  for i = 1, count do
    slices[p][order[i]] = math.random(max_slice)
  end
end

-- Init

function init()
  math.randomseed(os.time())
  for p = 1, NUM_PLAYERS do
    slices[p] = {}
    clear_row(p)
  end
  randomize_row(1, 8, 4)

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

  for v = 1, NUM_PLAYERS do
    softcut.enable(v, 1)
    softcut.buffer(v, 1)
    softcut.level(v, 0)
    -- short slew so blank steps cut to silence cleanly even at fast step rates
    softcut.level_slew_time(v, 0.01)
    softcut.rate(v, 1)
    softcut.rate_slew_time(v, 0)
    softcut.fade_time(v, FADE_TIME)
    softcut.loop(v, 1)
    softcut.rec(v, 0)
    softcut.play(v, 1)
  end
  set_region_loops()

  softcut.enable(REC_VOICE, 1)
  softcut.buffer(REC_VOICE, 1)
  softcut.level(REC_VOICE, 0)
  softcut.rate(REC_VOICE, 1)
  softcut.fade_time(REC_VOICE, FADE_TIME)
  softcut.recpre_slew_time(REC_VOICE, 0.01)
  softcut.rec_level(REC_VOICE, 1)
  -- pre_level 0 overwrites, so each bar replaces (clears) the previous take
  softcut.pre_level(REC_VOICE, 0)
  softcut.rec(REC_VOICE, 0)
  softcut.play(REC_VOICE, 1)

  -- each delay voice records the players and plays back what it wrote one
  -- loop ago, so the loop length is the delay time and pre_level the feedback
  for i, v in ipairs(DELAY_VOICES) do
    softcut.enable(v, 1)
    softcut.buffer(v, i)
    softcut.pan(v, i == 1 and -1 or 1)
    softcut.level(v, 0)
    softcut.rate(v, 1)
    softcut.fade_time(v, FADE_TIME)
    softcut.loop(v, 1)
    softcut.loop_start(v, DELAY_START)
    softcut.position(v, DELAY_START)
    softcut.recpre_slew_time(v, 0.01)
    softcut.rec_level(v, 1)
    softcut.pre_level(v, 0)
    softcut.rec(v, 1)
    softcut.play(v, 1)
  end
  set_delay_time()
end

function init_params()
  params:add_separator("microshimmer")
  params:add {
    id = "record",
    name = "Record Every Bar",
    type = "option",
    options = {"Off", "On"},
    default = 2,
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
    id = "reverb_send",
    name = "Reverb + Delay",
    type = "control",
    controlspec = ControlSpec.new(0, 1, "lin", 0.01, 0.5, ""),
    formatter = function(param) return math.floor(param:get() * 100 + 0.5) .. "%" end,
    action = function(value) set_reverb_send(value) end
  }

  local pitch_names = {}
  for i, pitch in ipairs(PITCHES) do
    pitch_names[i] = pitch.name
  end
  local rate_names = {}
  for i, rate in ipairs(RATES) do
    rate_names[i] = rate.name
  end

  for p = 1, NUM_PLAYERS do
    params:add_separator("player " .. p)
    params:add {
      id = "pitch_" .. p,
      name = "Pitch " .. p,
      type = "option",
      options = pitch_names,
      default = DEFAULT_PITCH,
      action = function() softcut.rate(p, player_rate(p)) end
    }
    params:add {
      id = "rate_" .. p,
      name = "Step Rate " .. p,
      type = "option",
      options = rate_names,
      default = DEFAULT_RATE,
    }
    params:add {
      id = "steps_" .. p,
      name = "Steps " .. p,
      type = "number",
      min = 1,
      max = MAX_STEPS,
      default = MAX_STEPS,
      action = function(value)
        if cursor_p == p then cursor_s = math.min(cursor_s, value) end
      end
    }
    params:add {
      id = "level_" .. p,
      name = "Level " .. p,
      type = "control",
      controlspec = ControlSpec.new(0, 1, "lin", 0.01, 0.8, ""),
      action = function() apply_player_level(p) end
    }
    params:add {
      id = "pan_" .. p,
      name = "Pan " .. p,
      type = "control",
      controlspec = ControlSpec.new(-1, 1, "lin", 0.01, DEFAULT_PANS[p], ""),
      action = function(value)
        softcut.pan(p, value)
        set_delay_send(p, value)
      end
    }
  end
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
    -- derive the tick from the beat count so every row stays aligned to the bar
    on_tick(math.floor(clock.get_beats() / TICK_DIV + 0.5))
  end
end

function on_tick(t)
  -- handle the bar first so rows firing on the downbeat read the fresh take
  if t % TICKS_PER_BAR == 0 then
    on_bar()
  end
  for p = 1, NUM_PLAYERS do
    local ticks = RATES[params:get("rate_" .. p)].ticks
    if t % ticks == 0 then
      cur_step[p] = (t // ticks) % num_steps(p) + 1
      if playing[p] then
        play_step(p)
      end
    end
  end
end

local function cancel_gate(p)
  if gate_clock[p] then
    clock.cancel(gate_clock[p])
    gate_clock[p] = nil
  end
end

function play_step(p)
  local slice = step_slice(p)
  if slice == 0 then
    -- blank steps ("-") start nothing; a pitched-up sound still ringing carries on
    if not gate_clock[p] then
      gate_open[p] = false
    end
    apply_player_level(p)
    return
  end
  cancel_gate(p)
  gate_open[p] = true
  local slice_len = loop_dur() / NUM_SLICES
  softcut.position(p, REGION_START[active_region] + (slice - 1) * slice_len)
  -- pitched up, a step sounds for rate x one slice's time (2x at 1oct, 4x at
  -- 2oct), through any blank steps, until it ends or a new slice takes over
  local rate = player_rate(p)
  if rate > 1 then
    gate_clock[p] = clock.run(close_gate, p, slice_len * rate)
  end
  apply_player_level(p)
end

function close_gate(p, dur)
  clock.sleep(dur)
  gate_clock[p] = nil
  gate_open[p] = false
  apply_player_level(p)
end

-- Recording

function on_bar()
  if recording then
    finish_recording()
  end
  if params:get("record") == 2 then
    begin_recording()
  end
  -- keep the delay time in step with tempo changes
  set_delay_time()
end

function begin_recording()
  rec_region = 3 - active_region
  rec_dur = bar_dur()
  local start = REGION_START[rec_region]
  -- loop off: the head stops at loop_end, so we record exactly one bar
  softcut.loop(REC_VOICE, 0)
  softcut.loop_start(REC_VOICE, start)
  softcut.loop_end(REC_VOICE, start + rec_dur)
  softcut.position(REC_VOICE, start)
  softcut.rec(REC_VOICE, 1)
  recording = true
end

function finish_recording()
  softcut.rec(REC_VOICE, 0)
  active_region = rec_region
  captured_dur = rec_dur
  recording = false
  set_region_loops()
end

function set_input_routing(mode)
  softcut.level_input_cut(1, REC_VOICE, mode == 2 and 0.7 or 1)
  softcut.level_input_cut(2, REC_VOICE, mode == 2 and 0.7 or 0)
end

-- Setters

function set_region_loops()
  local start = REGION_START[active_region]
  for v = 1, NUM_PLAYERS do
    softcut.loop_start(v, start)
    softcut.loop_end(v, start + loop_dur())
  end
end

function apply_player_level(p)
  local audible = playing[p] and gate_open[p]
  softcut.level(p, audible and params:get("level_" .. p) or 0)
end

function toggle_player(p)
  playing[p] = not playing[p]
  if playing[p] then
    play_step(p)
  else
    cancel_gate(p)
    gate_open[p] = false
    apply_player_level(p)
  end
end

-- level of softcut's send into the reverb (the dry level is left alone);
-- the delay's level and feedback rise along with it
function set_reverb_send(amp)
  set_system_param("rev_cut_input", amp_to_db(amp))
  for _, v in ipairs(DELAY_VOICES) do
    softcut.level(v, amp * DELAY_MAX_LEVEL)
    softcut.pre_level(v, amp * DELAY_MAX_FEEDBACK)
  end
end

function set_delay_time()
  local step_sec = RATES[DEFAULT_RATE].ticks * TICK_DIV * clock.get_beat_sec()
  for _, v in ipairs(DELAY_VOICES) do
    softcut.loop_end(v, DELAY_START + DELAY_STEPS * step_sec)
  end
end

-- feed a player into the left/right delay voices according to its pan
function set_delay_send(p, pan)
  local angle = (pan + 1) * math.pi / 4
  softcut.level_cut_cut(p, DELAY_VOICES[1], math.cos(angle))
  softcut.level_cut_cut(p, DELAY_VOICES[2], math.sin(angle))
end

-- Interaction

-- move the cursor along a row, wrapping into the next/previous row
function move_cursor(d)
  local p, s = cursor_p, cursor_s + d
  while s > num_steps(p) do
    s = s - num_steps(p)
    p = p % NUM_PLAYERS + 1
  end
  while s < 1 do
    p = (p - 2) % NUM_PLAYERS + 1
    s = s + num_steps(p)
  end
  cursor_p, cursor_s = p, s
end

-- select a row, keeping the step cursor within its length
function select_row(p)
  cursor_p = util.clamp(p, 1, NUM_PLAYERS)
  cursor_s = math.min(cursor_s, num_steps(cursor_p))
end

function enc(n, d)
  local p = cursor_p
  if n == 1 then
    if k3_held then
      k3_used = true
      page = util.clamp(page + d, 1, #PAGES)
    else
      params:delta("reverb_send", d)
    end
  elseif k2_held then
    k2_used = true
    params:delta((n == 2 and "pitch_" or "level_") .. p, d)
  elseif k3_held then
    if n == 3 then
      k3_used = true
      params:delta("steps_" .. p, d)
    end
  elseif PAGES[page] == "rate" then
    if n == 2 then
      select_row(p + d)
    else
      params:delta("rate_" .. p, d)
    end
  elseif n == 2 then
    move_cursor(d)
  else
    slices[p][cursor_s] = util.clamp(slices[p][cursor_s] + d, 0, NUM_SLICES)
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
        toggle_player(cursor_p)
      end
    end
  elseif n == 3 then
    if z == 1 then
      k3_held = true
      k3_used = false
      if k2_held then
        k2_used = true
        k3_used = true
        clear_row(cursor_p)
      end
    else
      k3_held = false
      if not k3_used then
        params:set("record", 3 - params:get("record"))
      end
    end
  end
end

-- Screen

function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  draw_header()
  if PAGES[page] == "rate" then
    draw_rate_page()
  else
    draw_steps_page()
  end
  draw_footer()
  screen.update()
end

-- tempo, reverb mix, record state
function draw_header()
  screen.level(4)
  screen.move(0, 6)
  screen.text(math.floor(clock.get_tempo() + 0.5) .. " bpm")
  screen.move(64, 6)
  screen.text_center("rev/dly " .. params:string("reverb_send"))
  screen.move(128, 6)
  local rec_on = params:get("record") == 2
  if recording then
    screen.level(15)
    screen.text_right(rec_on and "REC" or "REC END")
  else
    screen.level(rec_on and 15 or 4)
    screen.text_right(rec_on and "REC NEXT" or "HOLD")
  end
end

-- three rows of slice boxes with the playhead highlighted
function draw_steps_page()
  for p = 1, NUM_PLAYERS do
    local y = ROW_Y[p]
    for s = 1, num_steps(p) do
      local x = (s - 1) * BOX_W
      local is_playhead = playing[p] and s == cur_step[p]
      screen.level(is_playhead and 12 or (playing[p] and 2 or 1))
      screen.rect(x, y, BOX_W - 1, BOX_H)
      screen.fill()
      if p == cursor_p and s == cursor_s then
        screen.level(15)
        screen.rect(x + 0.5, y + 0.5, BOX_W - 2, BOX_H - 1)
        screen.stroke()
      end
      local slice = slices[p][s]
      if is_playhead then
        screen.level(0)
      else
        screen.level(slice == 0 and 4 or 15)
      end
      screen.move(x + 4, y + 8)
      screen.text_center(slice == 0 and "-" or slice)
    end
  end
end

-- each row's step rate, with a strip of cells showing how fast it moves
function draw_rate_page()
  local cell_w = 5
  local strip_x = 128 - MAX_STEPS * cell_w
  for p = 1, NUM_PLAYERS do
    local y = ROW_Y[p]
    local selected = p == cursor_p
    if selected then
      screen.level(15)
      screen.rect(0.5, y + 0.5, 127, BOX_H - 1)
      screen.stroke()
    end
    screen.level(selected and 15 or 4)
    screen.move(3, y + 8)
    screen.text("P" .. p)
    screen.move(18, y + 8)
    screen.text(params:string("rate_" .. p))
    for s = 1, num_steps(p) do
      local is_playhead = playing[p] and s == cur_step[p]
      screen.level(is_playhead and 15 or (playing[p] and 3 or 1))
      screen.rect(strip_x + (s - 1) * cell_w, y + 3, cell_w - 1, BOX_H - 6)
      screen.fill()
    end
  end
end

-- selected player's settings, plus page indicator dots
function draw_footer()
  local p = cursor_p
  screen.level(10)
  screen.move(0, 56)
  screen.text("P" .. p .. " " .. (playing[p] and "play" or "stop") .. "  "
    .. params:string("pitch_" .. p) .. "  " .. params:string("rate_" .. p)
    .. "  x" .. num_steps(p))
  screen.level(4)
  screen.move(0, 63)
  local level_text = "lvl " .. math.floor(params:get("level_" .. p) * 100 + 0.5) .. "%"
  if PAGES[page] == "rate" then
    screen.text(level_text)
  else
    local slice = slices[p][cursor_s]
    screen.text(level_text .. "  step " .. cursor_s .. "  slice " .. (slice == 0 and "-" or slice))
  end
  for i = 1, #PAGES do
    screen.level(i == page and 15 or 3)
    screen.rect(128 - (#PAGES - i + 1) * 4, 60, 2, 2)
    screen.fill()
  end
end

-- Cleanup

function cleanup()
  if tick_clock_id then
    clock.cancel(tick_clock_id)
    tick_clock_id = nil
  end
  for p, id in pairs(gate_clock) do
    clock.cancel(id)
    gate_clock[p] = nil
  end
  if screen_metro then
    metro.free(screen_metro.id)
    screen_metro = nil
  end
  for id, value in pairs(saved_params) do
    params:set(id, value)
  end
end
