--[[

  Light ClickHouse client for Tarantool
  Artem Prilutskiy, 2022

]]

local bit     = require('bit')
local ffi     = require('ffi')
local zlib    = require('zlib')
local pickle  = require('pickle')
local msgpack = require('msgpack')
local client  = require('http.client')

ffi.cdef([[
  char* mp_encode_float(char* data, float value);
  char* mp_encode_double(char* data, double value);
]])

local UUID = ffi.typeof('struct tt_uuid')

-- MessagePack

local function getPackedFloat32(value)
  if type(value) == 'number' then
    local buffer = ffi.new('char[5]')
    ffi.C.mp_encode_float(buffer, value)
    return ffi.string(buffer, 5)
  end
  return '\192'
end

local function getPackedFloat64(value)
  if type(value) == 'number' then
    local buffer = ffi.new('char[9]')
    ffi.C.mp_encode_double(buffer, value)
    return ffi.string(buffer, 9)
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
  if ffi.istype(UUID, value) then value = value:bin('b') end
  return value:sub(1, 8):reverse() .. value:sub(9, 16):reverse()
end

local function getNativeString(value)
  return getLEB128(value:len()) .. value
end

local function getNativeNullable(format, value, ...)
  if type(format) == 'string' and type(value) == 'nil'    then return '\000' .. getNativeString(format)         end
  if type(value)  == 'number' or  type(value) == 'string' then return '\000' .. pickle.pack(format, value, ...) end
  return '\001'
end

-- Query

local function getEscapedString(value)
  return tostring(value):gsub('[^%w]', function (symbol) return string.format('%%%02x', string.byte(symbol)) end)
end

local function makeCall(object, data)
  local location, body
  if not object.body then
    if type(data) == 'table'  then body = zlib.deflate(9, 15)(table.concat(data, object.delimiter), 'finish') end
    if type(data) == 'string' then body = zlib.deflate(9, 15)(data, 'finish')                                 end
  end
  if object.body and type(data) == 'table' then
    local query = { }
    for name, value in pairs(data) do table.insert(query, string.format('param_%s=%s', name, getEscapedString(value))) end
    location = object.location .. '?' .. table.concat(query, '&')
  end
  local status, result = pcall(object.client.post, object.client, location or object.location, object.body or body, object.options)
  if not status           then return false, result      end
  if result.status ~= 200 then return false, result.body end
  return true, result.body
end

local function getNew(location, headers, query, delimiter)
  local object =
  {
    client  = client.new({ max_connections = 1 }),
    options = { headers = headers, accept_encoding = 'deflate', keepalive_interval = 5 }
  }
  if query:upper():match('^INSERT ') then
    object.location  = location .. '?query=' .. getEscapedString(query)
    object.delimiter = delimiter or ''
    object.options.headers['Content-Encoding'] = 'deflate'
  else
    object.location = location
    object.body     = query
  end
  setmetatable(object, { __call = makeCall })
  return object
end

return {
  -- MessagePack
  getFloat32   = getPackedFloat32,
  getFloat64   = getPackedFloat64,
  compose      = composePackedRow,
  parse        = parsePackedData,
  -- RowBinary
  getLEB128    = getLEB128,
  getUUID      = getNativeUUID,
  getString    = getNativeString,
  getNullable  = getNativeNullable,
  -- Query
  new          = getNew
}
