--[[

  Light ClickHouse client for Tarantool
  Artem Prilutskiy, 2022

]]

local ffi     = require('ffi')
local zlib    = require('zlib')
local msgpack = require('msgpack')
local client  = require('http.client')

ffi.cdef([[
  char* mp_encode_float(char* data, float value);
  char* mp_encode_double(char* data, double value);
]])

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

local function parsePackedData(data, columns, callback, ...)
  local position = 1
  while position <= data:len() do
    local row = { }
    for column = 1, columns do row[column], position = msgpack.decode(data, position) end
    callback(row, ...)
  end
end

return { getFloat32 = getPackedFloat32, getFloat64 = getPackedFloat64, new = getNew, parse = parsePackedData }
