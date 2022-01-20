--[[

  Light ClickHouse client for Tarantool
  Artem Prilutskiy, 2022

]]

local ffi     = require('ffi')
local zlib    = require('zlib')
local pickle  = require('pickle')
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

local function makeCall(object, data)
  local body
  if type(data) == 'table'  then body = zlib.deflate(9, 15)(table.concat(data, object.delimiter), 'finish') end
  if type(data) == 'string' then body = zlib.deflate(9, 15)(data, 'finish')                                 end
  local status, result = pcall(object.client.request, object.client, object.method, object.location, body, object.options)
  if not status           then return false, result      end
  if result.status ~= 200 then return false, result.body end
  return true, result.body
end

local function getNew(location, headers, query, delimiter)
  local object =
  {
    method    = 'GET',
    client    = client.new({ max_connections = 1 }),
    options   = { headers = headers, accept_encoding = 'deflate', keepalive_interval = 5 },
    location  = location .. '?query=' .. query:gsub('[^%w]', function (symbol) return string.format('%%%02x', string.byte(symbol)) end),
    delimiter = delimiter or ''
  }
  if query:upper():match('^INSERT ') then
    object.method = 'POST'
    object.options.headers['Content-Encoding'] = 'deflate'
  end
  setmetatable(object, { __call = makeCall })
  return object
end

local function parsePackedData(data, columns, callback, ...)
  local index  = 1
  local header = pickle.pack('bn', 0xdc, columns)
  local length = data:len()
  while index <= data:len() do
    local row, length = msgpack.decode(header .. data:sub(index, index + length - 1))
    length = length - header:len() - 1
    index  = index  + length
    callback(row, ...)
  end
end

return { getFloat32 = getPackedFloat32, getFloat64 = getPackedFloat64, new = getNew, parse = parsePackedData }
