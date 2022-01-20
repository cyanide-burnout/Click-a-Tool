--[[

  Light ClickHouse client for Tarantool
  Artem Prilutskiy, 2022

]]

local ffi    = require('ffi')
local zlib   = require('zlib')
local client = require('http.client')

ffi.cdef[[
  char* mp_encode_float(char* data, float value); 
  char* mp_encode_double(char* data, double value); 
]]

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
  local method, body
  if type(data) == 'table' then
    method = 'POST'
    body   = zlib.deflate(9, 15)(table.concat(data, object.delimiter), 'finish')
  end
  if type(data) == 'string' then
    method = 'POST'
    body   = zlib.deflate(9, 15)(data, 'finish')
  end
  local status, result = pcall(object.client.request, object.client, method or 'GET', object.location, body, object.options)
  if status and result.status ~= 200 then
    status = false
    result = result.body
  end
  return status, result
end

local function getNew(location, headers, query, delimiter)
  headers['Content-Encoding'] = 'deflate'
  local object =
  {
    client    = client.new({ max_connections = 1 }),
    options   = { headers = headers, accept_encoding = 'deflate', keepalive_interval = 5 },
    location  = location .. '?query=' .. query:gsub('[^%w]', function (symbol) return string.format('%%%02x', string.byte(symbol)) end),
    delimiter = delimiter or ''
  }
  setmetatable(object, { __call = makeCall })
  return object
end

return { getFloat32 = getPackedFloat32, getFloat64 = getPackedFloat64, new = getNew }
