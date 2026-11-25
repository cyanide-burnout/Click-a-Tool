-- Tests of Click-a-Tool against a live ClickHouse (Tests/DockerTest.sh runs it):
--   CLICKHOUSE_URL=http://host:8123/ tarantool Tests/ClickHouseTest.lua
-- The user, the password and the database are test

local log      = require('log')
local json     = require('json')
local uuid     = require('uuid')
local fiber    = require('fiber')
local pickle   = require('pickle')
local msgpack  = require('msgpack')
local decimal  = require('decimal')
local datetime = require('datetime')
local client   = require('http.client')
local house    = require('ClickHouse')

local URL = os.getenv('CLICKHOUSE_URL') or 'http://localhost:8123/'

local credentials =
{
  ['X-ClickHouse-User'    ] = 'test',
  ['X-ClickHouse-Key'     ] = 'test',
  ['X-ClickHouse-Database'] = 'test'
}

local failures = 0

local function check(name, condition, ...)
  if condition then
    log.info('ok: %s', name)
  else
    failures = failures + 1
    log.error('FAIL: %s %s', name, json.encode({ ... }))
  end
end

local function call(query, data)
  local status, result = house.new(URL, credentials, query)(data)
  if not status then
    error(result, 2)
  end
  return result
end

local function select(query, columns, parameters)
  local list = { }
  house.parse(call(query, parameters), columns, list)
  return list
end

local function wait()
  local http = client.new()
  for _ = 1, 120 do
    local status, result = pcall(http.get, http, URL .. 'ping', { timeout = 1 })
    if status and result.status == 200 then
      return
    end
    fiber.sleep(0.5)
  end
  error('ClickHouse did not start at ' .. URL)
end

-- Helpers --------------------------------------------------------------------------------

local function helpers()
  check('LEB128 0',     house.getLEB128(0)     == '\0')
  check('LEB128 127',   house.getLEB128(127)   == '\127')
  check('LEB128 128',   house.getLEB128(128)   == '\128\1')
  check('LEB128 300',   house.getLEB128(300)   == '\172\2')
  check('LEB128 16384', house.getLEB128(16384) == '\128\128\1')
  check('String',       house.getString('abc') == '\3abc')
  check('Float32 nil',  house.getFloat32(nil)  == '\192')
  check('Float32',      house.getFloat32(1.5) == '\202\63\192\0\0' and house.getFloat32(2):byte(1) == 0xca)
  check('Float64',      msgpack.decode(house.getFloat64(2.5)) == 2.5 and house.getFloat64(2):byte(1) == 0xcb)
  check('Nullable nil', house.getNullable('?', nil) == '\1' and house.getNullable('i', box.NULL) == '\1')
  check('compose',      msgpack.decode('\147' .. house.compose({ 1, 'a', 2 }))[2] == 'a')

  local function fails(name, pattern, call, ...)
    local status, problem = pcall(call, ...)
    check(name, not status and tostring(problem):match(pattern) ~= nil, tostring(problem))
  end
  fails('Decimal32 overflow', 'Decimal32',             house.getDecimal, decimal.new('21474836.48'), 2, 4)
  fails('Int64 overflow',     'does not fit into Int64', house.getDecimal, decimal.new('1e20'), 2, 8)
  fails('Decimal size',       'size is 4, 8 or 16',    house.getDecimal, 1, 2, 2)
  fails('Decimal of nil',     'decimal',               house.getDecimal, nil, 2, 8)
  fails('DateTime64 of nil',  'datetime expected',     house.getDateTime64, nil, 3)
  fails('DateTime64 scale',   'scale is from 0 to 9',  house.getDateTime64, datetime.now(), 10)
  fails('UUID of 3 bytes',    'uuid',                  house.getUUID, 'abc')
  check('Decimal of a number and a string', house.getDecimal(1.5, 2, 8) == house.getDecimal('1.50', 2, 8))
  check('UUID of text', house.getUUID('0b5c1e3a-7f3e-4d39-9a31-6f1c2d3e4f50') ==
    house.getUUID(uuid.fromstr('0b5c1e3a-7f3e-4d39-9a31-6f1c2d3e4f50')))

  local copy = { }
  for name, value in pairs(credentials) do copy[name] = value end
  house.new(URL, copy, 'SELECT 1')
  check('headers of the caller stay as they are', copy['Content-Encoding'] == nil)
end

-- MsgPack and text formats ---------------------------------------------------------------

local function messagepack()
  call('DROP TABLE IF EXISTS SomeData')
  call([[
    CREATE TABLE SomeData
    (
      `ID`      UInt32,
      `Date`    DateTime('UTC'),
      `Name`    String,
      `Quality` Nullable(Float32),
      `Ratio`   Float64
    )
    ENGINE = MergeTree()
    ORDER BY `ID`]])

  local time = 1764073496 -- 2025-11-25 12:24:56 UTC

  call('INSERT INTO SomeData (ID, Date, Name, Quality, Ratio) FORMAT MsgPack',
    {
      msgpack.encode(1) .. msgpack.encode(time) .. msgpack.encode('Test 1') .. house.getFloat32(1.5) .. house.getFloat64(0.1),
      msgpack.encode(2) .. msgpack.encode(time) .. msgpack.encode('Test 2') .. house.getFloat32(nil) .. house.getFloat64(-2)
    })
  call('INSERT INTO SomeData (ID, Date, Name) FORMAT MsgPack',
    {
      house.compose({ 3, time, 'Test 3' })
    })
  call('INSERT INTO SomeData (ID, Date, Name, Quality, Ratio) FORMAT TabSeparated',
    {
      '4\t2025-11-25 12:24:56\tTest 4\t4.25\t4\n',
      '5\t2025-11-25 12:24:56\tTest\\t5\t\\N\t5\n'
    })
  -- A raw string, and an INSERT after spaces and a new line
  call('\n  INSERT INTO SomeData (ID, Date, Name, Ratio) FORMAT TabSeparated', '6\t2025-11-25 12:24:56\tTest 6\t6\n')

  local list = select('SELECT ID, toUnixTimestamp(Date), Name, Quality, Ratio FROM SomeData ORDER BY ID FORMAT MsgPack', 5)
  check('MsgPack rows', #list == 6, #list)
  check('MsgPack row 1', list[1][1] == 1 and list[1][2] == time and list[1][3] == 'Test 1' and list[1][4] == 1.5 and
    list[1][5] == 0.1, list[1])
  check('MsgPack NULL', list[2][4] == nil and list[2][5] == -2, list[2])
  check('compose', list[3][3] == 'Test 3' and list[3][4] == nil and list[3][5] == 0, list[3])
  check('TabSeparated', list[4][4] == 4.25 and list[5][3] == 'Test\t5' and list[5][4] == nil, list[4], list[5])
  check('raw string after spaces', list[6][1] == 6 and list[6][3] == 'Test 6', list[6])

  -- A callback with arguments
  local seen = { }
  house.parse(call('SELECT ID FROM SomeData WHERE ID < 3 ORDER BY ID FORMAT MsgPack'), 1,
    function (row, store) table.insert(store, row[1]) end, seen)
  check('parse with a callback', #seen == 2 and seen[1] == 1 and seen[2] == 2, seen)

  -- Parameters, escaped in the URL
  list = select('SELECT Name FROM SomeData WHERE ID > {id:UInt32} ORDER BY ID FORMAT MsgPack', 1, { id = 4 })
  check('parameter UInt32', #list == 2 and list[1][1] == 'Test\t5', list)
  local text = 'a b&c=d/e?f%g+h#i\'j"k ü'
  list = select('SELECT {text:String} FORMAT MsgPack', 1, { text = text })
  check('parameter String', list[1][1] == text, list)

  -- Settings of ClickHouse in the URL already
  local status, result = house.new(URL .. '?max_result_rows=1000', credentials,
    'SELECT count() FROM SomeData WHERE ID > {id:UInt32} FORMAT MsgPack')({ id = 0 })
  check('URL with settings, parameters', status and msgpack.decode(result) == 6, result)
  status, result = house.new(URL .. '?max_result_rows=1000', credentials,
    'INSERT INTO SomeData (ID, Date, Name) FORMAT TabSeparated')('7\t2025-11-25 12:24:56\tTest 7\n')
  check('URL with settings, INSERT', status, result)
  check('URL with settings, rows', select('SELECT count() FROM SomeData FORMAT MsgPack', 1)[1][1] == 7)
end

-- RowBinary ------------------------------------------------------------------------------

local function rowbinary()
  call('DROP TABLE IF EXISTS BinaryData')
  call([[
    CREATE TABLE BinaryData
    (
      `ID`     UInt32,
      `Name`   String,
      `Key`    UUID,
      `Amount` Decimal64(4),
      `Small`  Decimal32(2),
      `Moment` DateTime64(3, 'UTC'),
      `Note`   Nullable(String),
      `Tag`    Nullable(UUID),
      `Count`  Nullable(Int64),
      `Price`  Nullable(Decimal64(2)),
      `When`   Nullable(DateTime64(6, 'UTC')),
      `Flag`   Nullable(UInt8),
      `Raw`    Nullable(FixedString(3)),
      `Large`  Decimal128(6)
    )
    ENGINE = MergeTree()
    ORDER BY `ID`]])

  local key    = uuid.fromstr('0b5c1e3a-7f3e-4d39-9a31-6f1c2d3e4f50')
  local tag    = uuid.fromstr('f47ac10b-58cc-4372-a567-0e02b2c3d479')
  local moment = datetime.new({ year = 2026, month = 11, day = 25, hour = 12, min = 34, sec = 56, nsec = 789123456 })
  local short  = string.rep('x', 300)    -- two bytes of LEB128
  local long   = string.rep('y', 20000)  -- three bytes of LEB128

  call('INSERT INTO BinaryData FORMAT RowBinary',
    {
      pickle.pack('i', 1) .. house.getString('Test 1') .. house.getUUID(key) ..
      house.getDecimal(decimal.new('12.3456'), 4, 8) .. house.getDecimal(decimal.new('-1.25'), 2, 4) ..
      house.getDateTime64(moment, 3) ..
      house.getNullable('?', 'note') .. house.getNullable('-', tag) .. house.getNullable('l', -42) ..
      house.getNullable('!', decimal.new('9.99'), 2, 8) .. house.getNullable('+', moment, 6) ..
      house.getNullable('b', 1) .. house.getNullable('*', 'abc') .. house.getDecimal(decimal.new('-123456789012.345678'), 6, 16),

      pickle.pack('i', 2) .. house.getString(short) .. house.getUUID(key:bin('b')) ..
      house.getDecimal(decimal.new('-0.0001'), 4, 8) .. house.getDecimal(decimal.new('0'), 2, 4) ..
      house.getDateTime64(moment, 3) ..
      house.getNullable('?', nil) .. house.getNullable('-', nil) .. house.getNullable('l', box.NULL) ..
      house.getNullable('!', nil) .. house.getNullable('+', nil) .. house.getNullable('b', nil) ..
      house.getNullable('*', nil) .. house.getDecimal(decimal.new('9223372036854.775807'), 6, 16),

      pickle.pack('i', 3) .. house.getString(long) .. house.getUUID(key) ..
      house.getDecimal(decimal.new('123456789.1234'), 4, 8) .. house.getDecimal(decimal.new('99.999'), 2, 4) ..
      house.getDateTime64(datetime.new({ year = 1970, month = 1, day = 1 }), 3) ..
      house.getNullable('?', '') .. house.getNullable('-', nil) .. house.getNullable('l', 0) ..
      house.getNullable('!', decimal.new('-0.01'), 2, 8) .. house.getNullable('+', nil) .. house.getNullable('b', 0) ..
      house.getNullable('*', nil) .. house.getDecimal(0, 6, 16)
    })

  local list = select('SELECT ID, length(Name), toString(Key), toString(Amount), toString(Small), toString(Moment),' ..
    ' Note, toString(Tag), Count, toString(Price), toString(When), Flag, Raw, toString(Large) FROM BinaryData ORDER BY ID FORMAT MsgPack', 14)
  check('RowBinary rows', #list == 3, #list)

  local row = list[1]
  check('RowBinary UUID', row[3] == key:str(), row[3])
  check('RowBinary Decimal64', row[4] == '12.3456', row[4])
  check('RowBinary Decimal32', row[5] == '-1.25', row[5])
  check('RowBinary DateTime64(3)', row[6] == '2026-11-25 12:34:56.789', row[6])
  check('RowBinary Nullable values', row[7] == 'note' and row[8] == tag:str() and row[9] == -42 and
    row[10] == '9.99' and row[11] == '2026-11-25 12:34:56.789123' and row[12] == 1 and row[13] == 'abc', row)

  check('RowBinary negative Decimal128', row[14] == '-123456789012.345678', row[14])

  row = list[2]
  check('RowBinary largest Decimal128', row[14] == '9223372036854.775807', row[14])
  check('RowBinary String of 300', row[2] == 300, row[2])
  check('RowBinary UUID from binary', row[3] == key:str(), row[3])
  check('RowBinary small negative Decimal', row[4] == '-0.0001' and row[5] == '0', row[4], row[5])
  check('RowBinary NULLs', row[7] == nil and row[8] == nil and row[9] == nil and row[10] == nil and
    row[11] == nil and row[12] == nil and row[13] == nil, row)

  row = list[3]
  check('RowBinary String of 20000', row[2] == 20000, row[2])
  check('RowBinary large Decimal', row[4] == '123456789.1234', row[4])
  check('RowBinary Decimal floors extra digits', row[5] == '99.99', row[5])
  check('RowBinary epoch', row[6] == '1970-01-01 00:00:00.000', row[6])
  check('RowBinary empty, zero and negative', row[7] == '' and row[9] == 0 and row[10] == '-0.01' and row[12] == 0, row)
end

-- Failures -------------------------------------------------------------------------------

local function failures_()
  local status, result = house.new(URL, credentials, 'SELECT * FROM Missing FORMAT MsgPack')()
  check('unknown table', status == false and tostring(result):match('^HTTP 404: .*UNKNOWN_TABLE') ~= nil, result)

  status, result = house.new(URL, { ['X-ClickHouse-User'] = 'test', ['X-ClickHouse-Key'] = 'wrong' }, 'SELECT 1')()
  check('wrong password', status == false and tostring(result):match('^HTTP %d+: ') ~= nil, result)

  -- A connection that fails, in a fiber of its own as the plug-ins call it
  local worker = fiber.new(function ()
    return house.new('http://127.0.0.1:1/', credentials, 'SELECT 1', 2)()
  end)
  worker:set_joinable(true)
  local joined, answer, problem = worker:join()
  check('no connection', joined and answer == false and type(problem) ~= 'nil', joined, answer, tostring(problem))
end

wait()
for _, test in ipairs({ helpers, messagepack, rowbinary, failures_ }) do
  local status, problem = pcall(test)
  check('no error', status, tostring(problem))
end

if failures > 0 then
  log.error('%d failures', failures)
  os.exit(1)
end
log.info('all tests passed')
os.exit(0)
