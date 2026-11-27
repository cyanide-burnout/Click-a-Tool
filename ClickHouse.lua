--[[

  Light ClickHouse client for Tarantool
  Artem Prilutskiy, 2022-2026

  The HTTP interface of ClickHouse through http.client of Tarantool, requests and
  data compressed with deflate. Helpers encode values in the strict forms of MsgPack
  and RowBinary that ClickHouse expects. Tarantool 3, little-endian (amd64, aarch64).
  With Tarantool 3.9 a query can run in an application thread: the compression and
  the HTTP request leave TX, which only passes the data.

]]

local bit      = require('bit')
local ffi      = require('ffi')
local zlib     = require('zlib')
local uuid     = require('uuid')
local pickle   = require('pickle')
local msgpack  = require('msgpack')
local decimal  = require('decimal')
local digest   = require('digest')
local datetime = require('datetime')
local client   = require('http.client')

-- The name the module is required by: a thread requires it by the same name
local MODULE = ... or 'ClickHouse'

ffi.cdef([[
  const decimal_t* box_decimal_to_int64(const decimal_t* decimal, int64_t* number);
]])

-- MessagePack

-- msgpack of Tarantool encodes a cdata float as float 32 and a cdata double as float 64,
-- a Lua number with no fraction would become an integer

local function getPackedFloat32(value)
  if type(value) == 'number' then
    return msgpack.encode(ffi.cast('float', value))
  end
  return '\192'
end

local function getPackedFloat64(value)
  if type(value) == 'number' then
    return msgpack.encode(ffi.cast('double', value))
  end
  return '\192'
end

local function composePackedRow(data)
  local binary = msgpack.encode(data)
  local kind   = binary:byte(1)
  if kind >= 0x90 and kind <= 0x9f then return binary:sub(2) end
  if kind == 0xdc                  then return binary:sub(4) end
  if kind == 0xdd                  then return binary:sub(6) end
end

local function parsePackedData(data, columns, receiver, ...)
  local position = 1
  while position <= data:len() do
    local row = { }
    for column = 1, columns do row[column], position = msgpack.decode(data, position) end
    if type(receiver) == 'table'    then table.insert(receiver, row) end
    if type(receiver) == 'function' then receiver(row, ...)          end
  end
end

-- RowBinary

local function getLEB128(value)
  if value <= 0x0000007f then return string.char(value) end
  if value <= 0x00003fff then return pickle.pack('bb',   0x80 + bit.band(value, 0x7f), bit.rshift(value, 7)) end
  if value <= 0x001fffff then return pickle.pack('bbb',  0x80 + bit.band(value, 0x7f), 0x80 + bit.band(bit.rshift(value, 7), 0x7f), bit.rshift(value, 14)) end
  if value <= 0x0fffffff then return pickle.pack('bbbb', 0x80 + bit.band(value, 0x7f), 0x80 + bit.band(bit.rshift(value, 7), 0x7f), 0x80 + bit.band(bit.rshift(value, 14), 0x7f), bit.rshift(value, 21)) end
  return pickle.pack('bbbbb', 0x80 + bit.band(value, 0x7f), 0x80 + bit.band(bit.rshift(value, 7), 0x7f), 0x80 + bit.band(bit.rshift(value, 14), 0x7f), 0x80 + bit.band(bit.rshift(value, 21), 0x7f), bit.rshift(value, 28))
end

local function getNativeUUID(value)
  if type(value) == 'string' and value:len() == 36 then value = uuid.fromstr(value) end
  if uuid.is_uuid(value) then value = value:bin('b') end
  if type(value) ~= 'string' or value:len() ~= 16 then
    error('getUUID: a uuid, a UUID string or 16 bytes expected', 2)
  end
  return value:sub(1, 8):reverse() .. value:sub(9, 16):reverse()
end

local function getNativeString(value)
  return getLEB128(value:len()) .. value
end

-- A decimal as the integer ClickHouse stores, the fraction floored: Int64 at most
local function getScaledInteger(value, scale, name)
  local buffer = ffi.new('int64_t[1]')
  if ffi.C.box_decimal_to_int64(value * math.pow(10, scale), buffer) == nil then
    error(string.format('%s: %s does not fit into Int64 with the scale %d', name, tostring(value), scale), 3)
  end
  return buffer
end

local INT32_MIN = -0x80000000
local INT32_MAX =  0x7fffffff

local function getNativeDecimal(value, scale, size)
  if type(value) == 'number' or type(value) == 'string' then value = decimal.new(value) end
  if not decimal.is_decimal(value) then
    error('getDecimal: a decimal, a number or a string expected', 2)
  end
  local buffer = getScaledInteger(value, scale, 'getDecimal')
  if size == 4 then
    if buffer[0] < INT32_MIN or buffer[0] > INT32_MAX then
      error(string.format('getDecimal: %s does not fit into Decimal32 with the scale %d', tostring(value), scale), 2)
    end
    return ffi.string(buffer, 4)
  end
  if size == 8 then
    return ffi.string(buffer, 8)
  end
  if size == 16 then
    -- Decimal128: the sign extends the 64 bits
    return ffi.string(buffer, 8) .. string.rep(buffer[0] < 0 and '\255' or '\0', 8)
  end
  error('getDecimal: the size is 4, 8 or 16', 2)
end

local function getNativeDateTime64(value, scale)
  if not datetime.is_datetime(value) then
    error('getDateTime64: a datetime expected', 2)
  end
  if type(scale) ~= 'number' or scale < 0 or scale > 9 then
    error('getDateTime64: the scale is from 0 to 9', 2)
  end
  local ticks  = decimal.new(value.epoch) + decimal.new(value.nsec) / 1e9
  local buffer = getScaledInteger(ticks, scale, 'getDateTime64')
  return ffi.string(buffer, 8)
end

local function getNativeNullable(format, value, ...)
  if value  == nil then return '\001'                                    end
  if format == '*' then return '\000' .. value                           end
  if format == '-' then return '\000' .. getNativeUUID(value)            end
  if format == '?' then return '\000' .. getNativeString(value)          end
  if format == '!' then return '\000' .. getNativeDecimal(value, ...)    end
  if format == '+' then return '\000' .. getNativeDateTime64(value, ...) end
  return '\000' .. pickle.pack(format, value, ...)
end

-- Query

local function getEscapedString(value)
  return (tostring(value):gsub('[^%w]', function (symbol) return string.format('%%%02x', string.byte(symbol)) end))
end

local function getCompressedData(data)
  return zlib.deflate(9, 15)(data, 'finish')
end

local function makeCall(object, data)
  local location, body
  if not object.body then
    if type(data) == 'table'  then body = getCompressedData(table.concat(data, '')) end
    if type(data) == 'string' then body = getCompressedData(data)                   end
  end
  if object.body and type(data) == 'table' then
    local query = { }
    for name, value in pairs(data) do table.insert(query, string.format('param_%s=%s', name, getEscapedString(value))) end
    location = object.location .. object.separator .. table.concat(query, '&')
  end
  local status, result = pcall(object.client.post, object.client, location or object.location, object.body or body, object.options)
  if not status then return false, result or 'HTTP request failed without error details' end
  if type(result) ~= 'table' or not result.status then return false, 'HTTP request returned no response' end
  if result.status ~= 200 then
    local reason = result.body or result.errmsg or result.reason
    if reason then return false, string.format('HTTP %s: %s', result.status, reason) end
    return false, string.format('HTTP %s', result.status)
  end
  return true, result.body
end

local function getLocalQuery(location, headers, query, timeout)
  -- A copy of the headers: the table of the caller stays as it is
  local list      = { ['Content-Encoding'] = 'deflate' }
  local separator = location:find('?', 1, true) and '&' or '?'
  for name, value in pairs(headers or { }) do list[name] = value end
  local object =
  {
    client    = client.new({ max_connections = 1 }),
    separator = separator,
    options   = { headers = list, accept_encoding = 'deflate', keepalive_interval = 5, timeout = timeout }
  }
  if query:upper():match('^%s*INSERT%s') then
    object.location = location .. separator .. 'query=' .. getEscapedString(query)
  else
    object.location = location
    object.body     = getCompressedData(query)
  end
  setmetatable(object, { __call = makeCall })
  return object
end

-- Threads

-- The function a thread exports: (key, specification, data)
local EXPORT = 'clickhouse.call'

-- What TX evaluates in a thread once: (path, cpath, module)
local BOOT = [[
local path, cpath, module = ...
if package.loaded[module] == nil then
  package.path, package.cpath = path, cpath
end
require(module).serve()
]]

local threads        -- require('threads'), loaded with the first query in a thread
local queries = { }  -- In a thread: its query objects by key
local booted  = { }  -- In TX: the threads that serve queries, by group and id

-- One key per query: location, query, timeout and headers
local function getQueryKey(location, headers, query, timeout)
  local names = { }
  for name in pairs(headers) do table.insert(names, name) end
  table.sort(names)
  local list = { location, query, tostring(timeout) }
  for _, name in ipairs(names) do table.insert(list, name .. ':' .. tostring(headers[name])) end
  return digest.sha256(table.concat(list, '\0'))
end

-- In a thread: the call of a query, its object made once
local function runQuery(key, specification, data)
  local object = queries[key]
  if object == nil then
    object       = getLocalQuery(unpack(specification, 1, 4))
    queries[key] = object
  end
  return object(data)
end

-- In a thread: exports runQuery, once
local function serveThread()
  threads = threads or require('threads')
  local status, problem = pcall(threads.export, EXPORT, runQuery)
  if not status and not (type(problem) == 'cdata' and problem.name == 'FUNCTION_EXISTS') then
    error(problem, 0)
  end
end

-- In TX: the call goes to the thread, the module is loaded there with the first one
local function makeThreadCall(object, data)
  local thread = object.thread .. '/' .. object.thread_id
  if not booted[thread] then
    local status, problem = pcall(threads.eval, object.thread, BOOT,
      { package.path, package.cpath, MODULE }, { target = object.thread_id })
    if not status then return false, tostring(problem) end
    booted[thread] = true
  end
  local status, result = pcall(threads.call, object.thread, EXPORT,
    { object.key, object.specification, data }, { target = object.thread_id })
  if not status then return false, tostring(result) end
  return result[1][1], result[1][2]
end

local function getThreadQuery(location, headers, query, timeout, group, thread_id)
  if threads == nil then
    local status, module = pcall(require, 'threads')
    if not status then
      error('ClickHouse: a query in a thread needs application threads of Tarantool 3.9 or later', 3)
    end
    threads = module
  end
  local size
  for _, item in ipairs(threads.info().groups) do
    if item.name == group then size = item.size end
  end
  if size == nil then
    error(string.format('ClickHouse: there is no group of threads %s', group), 3)
  end
  if type(thread_id) ~= 'number' or thread_id < 1 or thread_id > size or thread_id ~= math.floor(thread_id) then
    error(string.format('ClickHouse: the group %s has threads 1 to %d', group, size), 3)
  end
  -- A copy of the headers, as the thread gets them
  local list = { }
  for name, value in pairs(headers or { }) do list[name] = value end
  local object =
  {
    thread        = group,
    thread_id     = thread_id,
    key           = getQueryKey(location, list, query, timeout),
    specification = { location, list, query, timeout }
  }
  setmetatable(object, { __call = makeThreadCall })
  return object
end

-- options: a timeout in seconds, or a table { timeout, thread, thread_id }
local function getNew(location, headers, query, options)
  if type(options) ~= 'table' then
    options = { timeout = options }
  end
  local timeout = options.timeout or 30
  if options.thread ~= nil then
    return getThreadQuery(location, headers, query, timeout, options.thread, options.thread_id or 1)
  end
  return getLocalQuery(location, headers, query, timeout)
end

return {
  -- MessagePack
  getFloat32    = getPackedFloat32,
  getFloat64    = getPackedFloat64,
  compose       = composePackedRow,
  parse         = parsePackedData,
  -- RowBinary
  getLEB128     = getLEB128,
  getUUID       = getNativeUUID,
  getString     = getNativeString,
  getDecimal    = getNativeDecimal,
  getDateTime64 = getNativeDateTime64,
  getNullable   = getNativeNullable,
  -- Query
  new           = getNew,
  -- Threads: what a thread runs, TX evaluates it there
  serve         = serveThread
}
