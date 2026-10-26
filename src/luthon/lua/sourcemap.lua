-- Pure-Lua VLQ Source Map generator for Luthon (Phase 9)
local M = {}
local bit = require("bit")

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local SourceMap = {}
SourceMap.__index = SourceMap

function M.new(file, sources)
  local self = setmetatable({}, SourceMap)
  self.file = file or ""
  self.sources = sources or (file and {file} or {})
  self.mappings = {}
  return self
end

function SourceMap:add(gen_line, gen_col, src_line, src_col, src_file)
  table.insert(self.mappings, {
    gen_line = gen_line,
    gen_col = gen_col,
    src_line = src_line,
    src_col = src_col,
    src_file = src_file or ""
  })
end

function SourceMap:_vlq(value)
  local encoded = (value >= 0) and bit.lshift(value, 1) or bit.bor(bit.lshift(-value, 1), 1)
  local result = ""
  while true do
    local digit = bit.band(encoded, 31)
    encoded = bit.rshift(encoded, 5)
    if encoded > 0 then
      digit = bit.bor(digit, 32)
    end
    local char_idx = digit + 1
    result = result .. B64:sub(char_idx, char_idx)
    if encoded == 0 then
      break
    end
  end
  return result
end

function SourceMap:to_dict()
  local by_gen = {}
  for _, m in ipairs(self.mappings) do
    if not by_gen[m.gen_line] then
      by_gen[m.gen_line] = {}
    end
    table.insert(by_gen[m.gen_line], m)
  end

  local sorted_gen_lines = {}
  for gl in pairs(by_gen) do
    table.insert(sorted_gen_lines, gl)
  end
  table.sort(sorted_gen_lines)

  local lines = {}
  local prev_src_line = 0
  local prev_src_col = 0
  local prev_src_idx = 0
  local prev_gen_col = 0

  for _, gl in ipairs(sorted_gen_lines) do
    local segs = {}
    table.sort(by_gen[gl], function(a, b) return a.gen_col < b.gen_col end)
    for _, m in ipairs(by_gen[gl]) do
      local si = 0
      for idx, src in ipairs(self.sources) do
        if src == m.src_file then
          si = idx - 1
          break
        end
      end
      local seg = self:_vlq(m.gen_col - prev_gen_col)
      seg = seg .. self:_vlq(si - prev_src_idx)
      seg = seg .. self:_vlq(m.src_line - prev_src_line)
      seg = seg .. self:_vlq(m.src_col - prev_src_col)
      table.insert(segs, seg)
      prev_gen_col = m.gen_col
      prev_src_idx = si
      prev_src_line = m.src_line
      prev_src_col = m.src_col
    end
    table.insert(lines, table.concat(segs, ","))
    prev_gen_col = 0
  end

  return {
    version = 3,
    file = self.file,
    sources = self.sources,
    mappings = table.concat(lines, ";")
  }
end

return M
