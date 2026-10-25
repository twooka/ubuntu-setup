-- Cairo orrery + fake shell for conky (original design).
-- Real planet positions: JPL Keplerian mean elements (Standish, valid 1800-2050).
-- View: ecliptic seen from slightly above (tilt), vernal equinox (γ) to the right.
-- Angles true, radii not to scale (evenly spaced; each orbit keeps its real eccentricity).
require 'cairo'
pcall(require, 'cairo_xlib')

------------------------------------------------------------------ settings
local WARP  = 1        -- 1 = real time; 864000 = 10 days/s
local CW    = 960      -- canvas width (px)  — keep in sync with hud.conf minimum_width
local CH    = 430      -- canvas height (px) — keep in sync with ${voffset} in hud.conf
local TILT  = 0.40     -- vertical squash of orbits (0.2 flat … 1.0 top-down)
local FONT  = 'JetBrains Mono'
local GREEN, DIM, AMBER = {0.0, 1.0, 0.4}, {0.04, 0.43, 0.21}, {1.0, 0.69, 0.0}

------------------------------------------------------------------ data
local TAU, D2R = 2 * math.pi, math.pi / 180
--  name, display radius (fraction of CW/2), body radius px, colour, elements, rates/century
local PL = {
  {'mercury',0.15,3.0,{0.62,0.60,0.58},{0.38709927,0.20563593,7.00497902,252.25032350,77.45779628,48.33076593},{0.00000037,0.00001906,-0.00594749,149472.67411175,0.16047689,-0.12534081}},
  {'venus',  0.23,5.0,{0.93,0.84,0.62},{0.72333566,0.00677672,3.39467605,181.97909950,131.60246718,76.67984255},{0.00000390,-0.00004107,-0.00078890,58517.81538729,0.00268329,-0.27769418}},
  {'earth',  0.31,5.5,{0.30,0.58,0.95},{1.00000261,0.01671123,-0.00001531,100.46457166,102.93768193,0.0},{0.00000562,-0.00004392,-0.01294668,35999.37244981,0.32327364,0.0}},
  {'mars',   0.39,4.0,{0.90,0.42,0.25},{1.52371034,0.09339410,1.84969142,-4.55343205,-23.94362959,49.55953891},{0.00001847,0.00007882,-0.00813131,19140.30268499,0.44441088,-0.29257343}},
  {'jupiter',0.57,11.0,{0.85,0.72,0.55},{5.20288700,0.04838624,1.30439695,34.39644051,14.72847983,100.47390909},{-0.00011607,-0.00013253,-0.00183714,3034.74612775,0.21252668,0.20469106}},
  {'saturn', 0.70,9.5,{0.93,0.82,0.55},{9.53667594,0.05386179,2.48599187,49.95424423,92.59887831,113.66242448},{-0.00125060,-0.00050991,0.00193609,1222.49362201,-0.41897216,-0.28867794}},
  {'uranus', 0.83,7.0,{0.55,0.85,0.88},{19.18916464,0.04725744,0.77263783,313.23810451,170.95427630,74.01692503},{-0.00196176,-0.00004397,-0.00242939,428.48202785,0.40805281,0.04240589}},
  {'neptune',0.95,7.0,{0.30,0.45,0.95},{30.06992276,0.00859048,1.77004347,-55.12002969,44.96476227,131.78422574},{0.00026291,0.00005105,0.00035372,218.45945325,-0.32241464,-0.00508664}},
}
local BELT_R = 0.48
local frame = 0
local NOW = 0            -- monotonic seconds; all animation is time-based, so fps only affects smoothness
local function clock()
  local f = io.open('/proc/uptime'); if not f then return os.time() end
  local v = tonumber(f:read('*n')); f:close(); return v or os.time()
end
math.randomseed(5)
local BELT, STARS = {}, {}
for i = 1, 320 do BELT[i] = {a = math.random() * TAU, dr = (math.random() - 0.5) * 0.05, s = 0.4 + math.random() * 0.9, f = 0.5 + math.random() * 2, p = math.random() * TAU} end
for i = 1, 180 do STARS[i] = {x = math.random() * CW, y = math.random() * CH, s = 0.3 + math.random() * 0.9, f = 0.2 + math.random(), p = math.random() * TAU} end

local function P(s) return conky_parse and conky_parse(s) or '' end

------------------------------------------------------------------ ephemeris
local function helio(p, T)
  local e0, r0 = p[5], p[6]
  local a  = e0[1] + r0[1] * T
  local e  = e0[2] + r0[2] * T
  local I  = (e0[3] + r0[3] * T) * D2R
  local L  = e0[4] + r0[4] * T
  local vp = e0[5] + r0[5] * T
  local Om = (e0[6] + r0[6] * T) * D2R
  local w  = vp * D2R - Om
  local M  = ((L - vp) % 360) * D2R
  local E = M + e * math.sin(M)
  for _ = 1, 6 do E = E - (E - e * math.sin(E) - M) / (1 - e * math.cos(E)) end
  local xp, yp = a * (math.cos(E) - e), a * math.sqrt(1 - e * e) * math.sin(E)
  local cw, sw, cO, sO, cI, sI = math.cos(w), math.sin(w), math.cos(Om), math.sin(Om), math.cos(I), math.sin(I)
  local x = (cw * cO - sw * sO * cI) * xp + (-sw * cO - cw * sO * cI) * yp
  local y = (cw * sO + sw * cO * cI) * xp + (-sw * sO + cw * cO * cI) * yp
  local z = (sw * sI) * xp + (cw * sI) * yp
  return x, y, z, a, e, vp * D2R
end

local S = {}
local function compute(unix)
  local jd = unix / 86400 + 2440587.5
  local d, T = jd - 2451545.0, (jd - 2451545.0) / 36525
  S.jd, S.unix = jd, unix
  for _, p in ipairs(PL) do
    local x, y, z, a, e, vp = helio(p, T)
    p.x, p.y, p.z, p.r = x, y, z, math.sqrt(x * x + y * y + z * z)
    p.lam = math.atan(y, x) % TAU
    p.a, p.e, p.vp = a, e, vp
  end
  local E = PL[3]
  for _, p in ipairs(PL) do
    local dx, dy, dz = p.x - E.x, p.y - E.y, p.z - E.z
    p.delta = math.sqrt(dx * dx + dy * dy + dz * dz)
  end
  local L0 = 218.316 + 13.176396 * d
  local Mm = (134.963 + 13.064993 * d) * D2R
  S.moon = ((L0 + 6.289 * math.sin(Mm)) % 360) * D2R
  S.illum = (1 - math.cos(S.moon - (E.lam + math.pi))) / 2
end

------------------------------------------------------------------ fake shell state
local LOG, LOGN = {}, 8
local sh = {cmd = nil, n = 0, hold = 0, idx = 0, focus = 4}
local function deg(r) return r / D2R end
local function lt(au) local s = au * 499.004784; return string.format('%dm%02ds', math.floor(s / 60), math.floor(s % 60)) end
local function push(s) LOG[#LOG + 1] = s; while #LOG > LOGN do table.remove(LOG, 1) end end
local JOBS = {}
for i, p in ipairs(PL) do
  if i ~= 3 then
    JOBS[#JOBS + 1] = {cmd = 'ephem --body ' .. p[1], focus = i, out = function()
      return {string.format('  λ %7.3f°   r %7.4f AU   e %.4f', deg(p.lam), p.r, p.e),
              string.format('  Δearth %7.4f AU   light-time %s', p.delta, lt(p.delta))} end}
  else
    JOBS[#JOBS + 1] = {cmd = 'phase --moon', focus = 3, out = function()
      return {string.format('  λ %7.3f°   illuminated %5.1f%%', deg(S.moon), S.illum * 100)} end}
  end
  if i == 4 then
    JOBS[#JOBS + 1] = {cmd = 'date -u +%FT%TZ', focus = 3, out = function()
      return {'  ' .. os.date('!%Y-%m-%dT%H:%M:%SZ'), string.format('  JD %.5f', S.jd)} end}
  end
  if i == 6 then
    JOBS[#JOBS + 1] = {cmd = 'uptime', focus = 3, out = function()
      return {'  up ' .. P('${uptime_short}') .. ',  load ' .. P('${loadavg}')} end}
  end
end
local function prompt() return '${color1}' .. (os.getenv('USER') or 'user') .. '@' .. P('${nodename}') .. '${color2}:~$$ ${color}' end

------------------------------------------------------------------ drawing helpers
local TOP = 9             -- y of the top border line
local cx, cy = CW / 2, CH / 2 + 12
local RX = CW / 2 - 40
local function proj(R, lam) return cx + R * math.cos(lam), cy - R * TILT * math.sin(lam) end
local function rgba(cr, c, a) cairo_set_source_rgba(cr, c[1], c[2], c[3], a or 1) end

local function orbit_point(p, nu)          -- display coords for true anomaly nu
  local rr = (1 - p.e * p.e) / (1 + p.e * math.cos(nu))
  return proj(p[2] * RX * rr, nu + p.vp)
end

local function draw_orbit(cr, p, focus)
  local n = 220
  cairo_new_path(cr)
  for k = 0, n do
    local x, y = orbit_point(p, k / n * TAU)
    if k == 0 then cairo_move_to(cr, x, y) else cairo_line_to(cr, x, y) end
  end
  cairo_close_path(cr)
  cairo_set_line_width(cr, focus and 1.3 or 0.8)
  rgba(cr, focus and GREEN or DIM, focus and 0.55 or 0.55)
  cairo_stroke(cr)
end

local function draw_trail(cr, p)            -- fading arc behind the planet (motion is +λ)
  local nu0 = p.lam - p.vp
  local bands, sub, span = 6, 5, 0.35
  cairo_set_line_width(cr, 2.0)
  for k = 0, bands - 1 do
    cairo_new_path(cr)
    for j = 0, sub do
      local x, y = orbit_point(p, nu0 - span * (k + j / sub) / bands)
      if j == 0 then cairo_move_to(cr, x, y) else cairo_line_to(cr, x, y) end
    end
    rgba(cr, p[4], 0.55 * (1 - k / bands)); cairo_stroke(cr)
  end
end

local function disc(cr, x, y, r, col, lx, ly)   -- shaded sphere, lit from (lx,ly)
  local d = math.sqrt((lx - x) ^ 2 + (ly - y) ^ 2) + 1e-6
  local hx, hy = x + (lx - x) / d * r * 0.45, y + (ly - y) / d * r * 0.45
  local pat = cairo_pattern_create_radial(hx, hy, r * 0.1, x, y, r * 1.05)
  cairo_pattern_add_color_stop_rgba(pat, 0, math.min(1, col[1] * 1.35), math.min(1, col[2] * 1.35), math.min(1, col[3] * 1.35), 1)
  cairo_pattern_add_color_stop_rgba(pat, 0.65, col[1], col[2], col[3], 1)
  cairo_pattern_add_color_stop_rgba(pat, 1, col[1] * 0.25, col[2] * 0.25, col[3] * 0.25, 1)
  cairo_set_source(cr, pat)
  cairo_arc(cr, x, y, r, 0, TAU); cairo_fill(cr)
  cairo_pattern_destroy(pat)
end

local function ring(cr, x, y, rx, ry, a0, a1, col, alpha, w)
  cairo_save(cr); cairo_translate(cr, x, y); cairo_rotate(cr, -0.18); cairo_scale(cr, 1, ry / rx)
  cairo_new_path(cr); cairo_arc(cr, 0, 0, rx, a0, a1); cairo_restore(cr)
  cairo_set_line_width(cr, w); rgba(cr, col, alpha); cairo_stroke(cr)
end

local function planet(cr, p, i, focus)
  local x, y, r = p.sx, p.sy, p[3]
  if i == 6 then   -- saturn: back half of rings, body, front half
    for _, R in ipairs({{2.25, 0.35, 2.2}, {1.85, 0.55, 2.8}, {1.55, 0.25, 1.4}}) do
      ring(cr, x, y, r * R[1], r * R[1] * 0.32, math.pi, TAU, {0.85, 0.76, 0.55}, R[2], R[3])
    end
  elseif i == 7 then
    ring(cr, x, y, r * 1.9, r * 1.9 * 0.9, math.pi, TAU, {0.6, 0.85, 0.9}, 0.25, 0.8)
  end
  disc(cr, x, y, r, p[4], cx, cy)
  if i == 6 then
    for _, R in ipairs({{2.25, 0.35, 2.2}, {1.85, 0.55, 2.8}, {1.55, 0.25, 1.4}}) do
      ring(cr, x, y, r * R[1], r * R[1] * 0.32, 0, math.pi, {0.85, 0.76, 0.55}, R[2], R[3])
    end
  elseif i == 7 then
    ring(cr, x, y, r * 1.9, r * 1.9 * 0.9, 0, math.pi, {0.6, 0.85, 0.9}, 0.25, 0.8)
  end
  if i == 5 then   -- jupiter bands
    cairo_save(cr); cairo_arc(cr, x, y, r, 0, TAU); cairo_clip(cr)
    for _, b in ipairs({-0.45, -0.1, 0.3}) do
      cairo_rectangle(cr, x - r, y + b * r, 2 * r, r * 0.16); rgba(cr, {0.55, 0.38, 0.25}, 0.45); cairo_fill(cr)
    end
    cairo_restore(cr)
  end
  if i == focus then
    cairo_set_line_width(cr, 1); rgba(cr, AMBER, 0.9)
    local rr = r + 5 + 1.5 * math.sin(NOW * 2.5)
    cairo_arc(cr, x, y, rr, 0, TAU); cairo_stroke(cr)
  end
end

local function text(cr, x, y, s, size, col, alpha, bold)
  cairo_select_font_face(cr, FONT, CAIRO_FONT_SLANT_NORMAL, bold and CAIRO_FONT_WEIGHT_BOLD or CAIRO_FONT_WEIGHT_NORMAL)
  cairo_set_font_size(cr, size); rgba(cr, col, alpha); cairo_move_to(cr, x, y); cairo_show_text(cr, s)
end



-- HUD frame (like the ASCII version): rounded box, tabs cut into the border, separator above the shell
local function tab(cr, x, y, parts, dry)     -- parts = {{text, colour, bold}, ...}; returns x after the tab
  local size, cwid = 11, 11 * 0.6
  local n = 4; for _, q in ipairs(parts) do n = n + utf8.len(q[1]) end
  if dry then return x + n * cwid end
  rgba(cr, {0, 0, 0}, 1); cairo_rectangle(cr, x - 2, y - 8, n * cwid + 4, 14); cairo_fill(cr)
  text(cr, x, y + 4, '[ ', size, DIM, 1)
  local px = x + 2 * cwid
  for _, q in ipairs(parts) do text(cr, px, y + 4, q[1], size, q[2], 1, q[3]); px = px + utf8.len(q[1]) * cwid end
  text(cr, px, y + 4, ' ]', size, DIM, 1)
  return px + 2 * cwid
end

-- HUD brackets: one tall [ on the left and ] on the right, vertically centred on the orrery
local ARM = 16         -- length of the bracket arms (px)
local function draw_frame(cr, w, h)
  local m = 1.5
  local rgt = w - m
  local half = RX * TILT + 26                -- bracket half-height: orbit extent + margin
  local y0, y1 = cy - half, cy + half
  cairo_set_line_width(cr, 1.4); rgba(cr, DIM, 1)
  cairo_new_path(cr)
  cairo_move_to(cr, m + ARM, y0); cairo_line_to(cr, m, y0); cairo_line_to(cr, m, y1); cairo_line_to(cr, m + ARM, y1)
  cairo_move_to(cr, rgt - ARM, y0); cairo_line_to(cr, rgt, y0); cairo_line_to(cr, rgt, y1); cairo_line_to(cr, rgt - ARM, y1)
  cairo_stroke(cr)
  -- centre notches + small ticks along the bars
  cairo_set_line_width(cr, 1.0)
  for k = -4, 4 do
    local y = cy + k * half / 5
    local L = (k == 0) and 10 or 4
    cairo_move_to(cr, m, y); cairo_line_to(cr, m + L, y)
    cairo_move_to(cr, rgt, y); cairo_line_to(cr, rgt - L, y)
  end
  cairo_stroke(cr)
  -- header tabs, centred above the orrery
  local tabs = {{{'HELIOCENTRIC', GREEN, true}}, {{'ecliptic', DIM}},
                {{os.date('!%Y-%m-%d %H:%M', math.floor(S.unix)) .. ' UTC', GREEN}}}
  if WARP ~= 1 then tabs[#tabs + 1] = {{string.format('x%d', WARP), AMBER}} end
  tabs[#tabs + 1] = {{'up ' .. P('${uptime_short}'), GREEN}}
  local width = 0; for _, t in ipairs(tabs) do width = tab(cr, width, 0, t, true) + 10 end
  local x = (w - width + 10) / 2
  for _, t in ipairs(tabs) do x = tab(cr, x, TOP, t) + 10 end
end

-- static layer: redrawn only when the focused planet or the minute changes
local STATIC = {key = nil, surf = nil}
local function static_layer(focus)
  local key = focus .. '|' .. os.date('!%Y%m%d%H%M', math.floor(S.unix))
  if key == STATIC.key then return end
  if not STATIC.surf then STATIC.surf = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, CW, CH) end
  local cr = cairo_create(STATIC.surf)
  cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR); cairo_paint(cr); cairo_set_operator(cr, CAIRO_OPERATOR_OVER)
  cairo_set_line_width(cr, 0.6); rgba(cr, DIM, 0.6)
  cairo_move_to(cr, cx, cy); cairo_line_to(cr, cx + RX + 6, cy); cairo_stroke(cr)
  text(cr, cx + RX - 2, cy - 5, 'γ', 13, GREEN, 0.8)
  for i, p in ipairs(PL) do draw_orbit(cr, p, i == focus) end
  local ft = 'angles true · radii not to scale · γ vernal equinox'
  text(cr, (CW - utf8.len(ft) * 6) / 2, CH - 6, ft, 10, DIM, 1)
  cairo_destroy(cr)
  STATIC.key = key
end

local NB = 5
local function scene(cr, t)
  local focus = sh.focus
  -- stars
  for b = 0, NB - 1 do
    cairo_new_path(cr)
    for _, s in ipairs(STARS) do
      local v = (math.sin(t * s.f + s.p) + 1) / 2
      if math.min(NB - 1, math.floor(v * NB)) == b then cairo_new_sub_path(cr); cairo_arc(cr, s.x, s.y, s.s, 0, TAU) end
    end
    rgba(cr, {0.8, 1, 0.9}, 0.08 + 0.35 * (b + 0.5) / NB); cairo_fill(cr)
  end
  -- static layer (orbits, axis, labels) — cached, see conky_draw
  cairo_set_source_surface(cr, STATIC.surf, 0, 0); cairo_paint(cr)
  for k = 0, NB - 1 do
    cairo_new_path(cr)
    for _, b in ipairs(BELT) do
      local v = (math.sin(t * b.f + b.p) + 1) / 2
      if math.min(NB - 1, math.floor(v * NB)) == k then
        local x, y = proj((BELT_R + b.dr) * RX, b.a + t * 0.004)
        cairo_new_sub_path(cr); cairo_arc(cr, x, y, b.s, 0, TAU)
      end
    end
    rgba(cr, {0.7, 0.8, 0.7}, 0.15 + 0.3 * (k + 0.5) / NB); cairo_fill(cr)
  end
  -- positions + trails
  for _, p in ipairs(PL) do p.sx, p.sy = proj(p[2] * RX * p.r / p.a, p.lam); draw_trail(cr, p) end
  -- bodies behind the sun (far side), sun, bodies in front
  local function bodies(far)
    for i, p in ipairs(PL) do if (p.sy < cy) == far then planet(cr, p, i, focus) end end
  end
  bodies(true)
  local pulse = 0.5 + 0.5 * math.sin(t * 1.7)
  local g = cairo_pattern_create_radial(cx, cy, 4, cx, cy, 70 + 8 * pulse)
  cairo_pattern_add_color_stop_rgba(g, 0, 1, 0.85, 0.4, 0.55)
  cairo_pattern_add_color_stop_rgba(g, 0.25, 1, 0.6, 0.1, 0.18)
  cairo_pattern_add_color_stop_rgba(g, 1, 1, 0.5, 0, 0)
  cairo_set_source(cr, g); cairo_arc(cr, cx, cy, 80, 0, TAU); cairo_fill(cr); cairo_pattern_destroy(g)
  local s = cairo_pattern_create_radial(cx - 4, cy - 4, 2, cx, cy, 15)
  cairo_pattern_add_color_stop_rgba(s, 0, 1, 1, 0.85, 1)
  cairo_pattern_add_color_stop_rgba(s, 0.6, 1, 0.75, 0.2, 1)
  cairo_pattern_add_color_stop_rgba(s, 1, 0.9, 0.4, 0.0, 1)
  cairo_set_source(cr, s); cairo_arc(cr, cx, cy, 14, 0, TAU); cairo_fill(cr); cairo_pattern_destroy(s)
  bodies(false)
  -- moon around earth
  local E = PL[3]
  local mx, my = E.sx + 13 * math.cos(S.moon), E.sy - 13 * TILT * math.sin(S.moon)
  disc(cr, mx, my, 1.8, {0.8, 0.8, 0.8}, cx, cy)
  -- callout for focused planet
  local f = PL[focus]
  local LW = 120                                   -- label block width
  local dir = (f.sx >= cx) and 1 or -1
  if f.sx + dir * (34 + LW) > CW - 12 then dir = -1 elseif f.sx + dir * (34 + LW) < 12 then dir = 1 end
  local up = (f.sy - 26 - 16 > TOP + 6) and -1 or 1
  local ex, ey = f.sx + dir * 34, f.sy + up * 26
  cairo_set_line_width(cr, 0.8); rgba(cr, AMBER, 0.8)
  cairo_move_to(cr, f.sx + dir * (f[3] + 6) * 0.7, f.sy + up * (f[3] + 6) * 0.7); cairo_line_to(cr, ex, ey)
  cairo_line_to(cr, ex + dir * 70, ey); cairo_stroke(cr)
  local tx = dir > 0 and ex + 4 or ex - LW + 50
  text(cr, tx, ey - 4, f[1]:upper(), 11, AMBER, 0.95, true)
  text(cr, tx, ey + 12, string.format('%.1f°  %.2f AU', deg(f.lam), f.r), 10, GREEN, 0.8)
end

------------------------------------------------------------------ conky entry points
local T0, T0c = os.time(), clock()
local function tick()
  frame = frame + 1
  NOW = clock()
  local t = NOW
  compute((WARP == 1) and os.time() or (T0 + (t - T0c) * WARP))
  return t
end

local FRAME
function conky_draw()
  if conky_window == nil then return end
  local t = tick()
  -- render everything client-side into one image, then send it to the X server in a single paint
  -- (hundreds of small XRender ops made Xwayland do all the work)
  if not FRAME then FRAME = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, CW, CH) end
  static_layer(sh.focus)
  local ic = cairo_create(FRAME)
  cairo_set_operator(ic, CAIRO_OPERATOR_CLEAR); cairo_paint(ic); cairo_set_operator(ic, CAIRO_OPERATOR_OVER)
  scene(ic, t)
  cairo_destroy(ic)
  local cs = cairo_xlib_surface_create(conky_window.display, conky_window.drawable, conky_window.visual,
                                       conky_window.width, conky_window.height)
  local cr = cairo_create(cs)
  cairo_set_source_surface(cr, FRAME, 0, 0); cairo_paint(cr)
  draw_frame(cr, conky_window.width, conky_window.height)
  cairo_destroy(cr); cairo_surface_destroy(cs)
end

function conky_shell()
  if not S.jd then tick() end
  if not sh.cmd then sh.idx = sh.idx % #JOBS + 1; sh.cmd = JOBS[sh.idx]; sh.n = 0; sh.hold = 0; sh.t0 = NOW; sh.focus = sh.cmd.focus end
  local c, live = sh.cmd.cmd, nil
  if sh.n < #c then
    sh.n = math.min(#c, math.floor((NOW - sh.t0) * 20)); live = prompt() .. c:sub(1, sh.n) .. '▌'
  else
    if sh.hold == 0 then sh.hold = NOW; push(prompt() .. c); for _, l in ipairs(sh.cmd.out()) do push('${color2}' .. l .. '${color}') end end
    if NOW - sh.hold > 2.2 then sh.cmd = nil end
    live = prompt() .. (math.floor(NOW * 2.5) % 2 == 0 and '▌' or ' ')
  end
  local o = {}
  for i = 1, LOGN do o[#o + 1] = '${offset 14}' .. (LOG[i] or '') end
  o[#o + 1] = '${offset 14}' .. live
  o[#o + 1] = ''
  return table.concat(o, '\n')
end
