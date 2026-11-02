--[[
  Native sqlite3 FFI shim for LuaJIT (src/luthon/lua/native/sqlite3.lua)
--]]
local ffi = require("ffi")

local M = {}

ffi.cdef[[
  typedef struct sqlite3 sqlite3;
  typedef struct sqlite3_stmt sqlite3_stmt;

  int sqlite3_open(const char *filename, sqlite3 **ppDb);
  int sqlite3_close(sqlite3 *db);
  int sqlite3_prepare_v2(sqlite3 *db, const char *zSql, int nByte, sqlite3_stmt **ppStmt, const char **pzTail);
  int sqlite3_step(sqlite3_stmt *pStmt);
  int sqlite3_finalize(sqlite3_stmt *pStmt);
  int sqlite3_column_count(sqlite3_stmt *pStmt);
  int sqlite3_column_type(sqlite3_stmt *pStmt, int iCol);
  const char *sqlite3_column_name(sqlite3_stmt *pStmt, int iCol);
  int64_t sqlite3_column_int64(sqlite3_stmt *pStmt, int iCol);
  double sqlite3_column_double(sqlite3_stmt *pStmt, int iCol);
  const unsigned char *sqlite3_column_text(sqlite3_stmt *pStmt, int iCol);
  const char *sqlite3_errmsg(sqlite3 *db);
]]

local sqlite = nil
local candidates = {"libsqlite3.so.0", "libsqlite3.so", "sqlite3"}
for _, name in ipairs(candidates) do
  local ok, lib = pcall(ffi.load, name)
  if ok and lib then
    sqlite = lib
    break
  end
end

if not sqlite then
  error("libsqlite3 dynamic library could not be loaded")
end

local SQLITE_OK = 0
local SQLITE_ROW = 100
local SQLITE_DONE = 101

local SQLITE_INTEGER = 1
local SQLITE_FLOAT = 2
local SQLITE_TEXT = 3
local SQLITE_BLOB = 4
local SQLITE_NULL = 5

local Cursor = {}
Cursor.__index = Cursor

function Cursor:fetchall()
  local rows = {}
  if not self.stmt then
    return rows
  end
  while true do
    local rc
    if self.first_row then
      rc = self.first_row
      self.first_row = nil
    else
      rc = sqlite.sqlite3_step(self.stmt)
    end
    if rc == SQLITE_ROW then
      local row = {}
      local n = sqlite.sqlite3_column_count(self.stmt)
      for i = 0, n - 1 do
        local col_type = sqlite.sqlite3_column_type(self.stmt, i)
        if col_type == SQLITE_INTEGER then
          table.insert(row, tonumber(sqlite.sqlite3_column_int64(self.stmt, i)))
        elseif col_type == SQLITE_FLOAT then
          table.insert(row, tonumber(sqlite.sqlite3_column_double(self.stmt, i)))
        elseif col_type == SQLITE_TEXT or col_type == SQLITE_BLOB then
          local txt = sqlite.sqlite3_column_text(self.stmt, i)
          table.insert(row, txt ~= nil and ffi.string(txt) or "")
        else
          table.insert(row, nil)
        end
      end
      table.insert(rows, row)
    elseif rc == SQLITE_DONE then
      break
    else
      local err = ffi.string(sqlite.sqlite3_errmsg(self.db))
      error("sqlite3 step error: " .. err)
    end
  end
  sqlite.sqlite3_finalize(self.stmt)
  self.stmt = nil
  return rows
end

local Conn = {}
Conn.__index = Conn

function Conn:execute(sql)
  local ppStmt = ffi.new("sqlite3_stmt*[1]")
  local rc = sqlite.sqlite3_prepare_v2(self.db, sql, #sql, ppStmt, nil)
  if rc ~= SQLITE_OK then
    local err = ffi.string(sqlite.sqlite3_errmsg(self.db))
    error("sqlite3 prepare error: " .. err)
  end
  local stmt = ppStmt[0]
  local step_rc = sqlite.sqlite3_step(stmt)
  if step_rc == SQLITE_DONE then
    sqlite.sqlite3_finalize(stmt)
    return setmetatable({db = self.db, stmt = nil}, Cursor)
  elseif step_rc == SQLITE_ROW then
    return setmetatable({db = self.db, stmt = stmt, first_row = step_rc}, Cursor)
  else
    local err = ffi.string(sqlite.sqlite3_errmsg(self.db))
    sqlite.sqlite3_finalize(stmt)
    error("sqlite3 step error: " .. err)
  end
end

function Conn:close()
  if self.db then
    sqlite.sqlite3_close(self.db)
    self.db = nil
  end
end

function M.connect(path)
  local ppDb = ffi.new("sqlite3*[1]")
  local rc = sqlite.sqlite3_open(path, ppDb)
  if rc ~= SQLITE_OK then
    error("sqlite3 could not open database: " .. tostring(path))
  end
  return setmetatable({db = ppDb[0]}, Conn)
end

return M
