local W_FULL, W_EMPTY = '█', '░'
local function bar(p, w)
  p = tonumber(p) or 0; w = tonumber(w) or 20
  if p < 0 then p = 0 elseif p > 100 then p = 100 end
  local n = math.floor(p * w / 100 + 0.5)
  local col = p >= 85 and '${color3}' or '${color1}'
  return col .. W_FULL:rep(n) .. '${color2}' .. W_EMPTY:rep(w - n) .. '${color}'
end
local NCPU
local function ncpu()
  if NCPU then return NCPU end
  NCPU = 0
  for l in io.lines('/proc/stat') do if l:match('^cpu%d') then NCPU = NCPU + 1 end end
  return NCPU
end
function conky_cpubar(core, w) return bar(conky_parse('${cpu cpu' .. core .. '}'), w) end
function conky_membar(w)        return bar(conky_parse('${memperc}'), w) end
function conky_swapbar(w)       return bar(conky_parse('${swapperc}'), w) end
function conky_fsbar(path, w)   return bar(conky_parse('${fs_used_perc ' .. path .. '}'), w) end
function conky_batbar(b, w)     return bar(conky_parse('${battery_percent ' .. b .. '}'), w) end
function conky_cores(w)
  local out = {}
  for i = 1, ncpu() do
    local p = tonumber(conky_parse('${cpu cpu' .. i .. '}')) or 0
    out[#out + 1] = string.format('${color2}│${color}  c%-2d  %s %3d%%  ${freq_g %d}GHz',
                                  i - 1, bar(p, w), p, i)
  end
  return table.concat(out, '\n')
end
