# Click-a-Tool
A light ClickHouse client for Tarantool

Artem Prilutskiy, 2022

Client library uses HTTP interface of ClickHouse to interact with. It is more preferable to use MessagePack format to pass data to. Since ClickHouse uses strict form of data, there are helper functions to make some data fields in strict format. Most of [types](https://clickhouse.com/docs/en/interfaces/formats/#msgpack) can be encoded directly by [Tarantool's msgpack library](https://www.tarantool.io/en/doc/latest/reference/reference_lua/msgpack/).

The library also provides support of RowBinary. Most of scalar types can be encoded by the [pickle library](https://www.tarantool.io/en/doc/latest/reference/reference_lua/pickle/), that is why these are not implemeted by the library. Please read [RowBinary format description](https://clickhouse.com/docs/en/interfaces/formats/#rowbinary) for details. You can use if when you really understand what are you doing or have a need such as for example to pass UUIDs or Decimals, because in case of RowBinary ClickHouse doesn't do type check.

Typical use of the library is a batch propagation of data that is accomulated in Tarantool to ClickHouse. Due to lack of supported MessagePack types we moved our code to use RowBinary. SELECT queries can use MessagePack by using converting functions on ClickHouse side.


Please read details of HTTP interface here: https://clickhouse.com/docs/en/interfaces/http/ \
And supported formats: https://clickhouse.com/docs/en/interfaces/formats/

About UUIDs over MessagePack in ClickHouse: https://github.com/ClickHouse/ClickHouse/issues/33756 \
Also about UUIDs in Native and Binary formats: https://github.com/ClickHouse/ClickHouse/issues/33910

Please note, the library written in Lua and intensively uses Tarantool Lua libraries (pickle, msgpack, decimal, http.client) and C functions via [FFI](https://luajit.org/ext_ffi.html). It cannot run in a pure Lua environment.

## Requirements

* Tarantool 2.x
* lua-zlib (can be installed from the standard Linux distribuion)

## API

* **MessagePack**
  * *house.getFloat32(value)* and *house.getFloat64(value)* - encode strictly formated float value in MessagePack
  * *house.compose({ array, of, values, ... })* - encode set of fields in MessagePack (compatible to ClickHouse)
  * *house.parse(repoonse, count_of_columns, table_to_save)* - parse MessagePack-formatted response into a table variable
  * *house.parse(repoonse, count_of_columns, callback [, arguments])* - parse MessagePack-formatted response and call a *callback(row [, arguments])* on each row 
* **RowBinary**
  * *getLEB128(value)* - encode LEB128 unisgned integer value
  * *getUUID(value)* - encode UUID. *value* can be a string with binary UUID in network byte order or Tarantool's *uuid* object.
  * *getString(value)* - encode String of variable length
  * *getDecimal(value, scale, size)* - encode Taranool's decimal as ClickHouse's Decimal. *size* is a target size in bytes, 4 for Decimal32, 8 for Decimal64. At this moment this function is suitable only when Tarantool runs on little-endian architectures (i386, amd64, aarch64 :)).
  * *getNullable(format, value [, ...])* - encode Nullable value, where *format* is '?' for a String of variable length, '!' for Decimal (see above), '\*' for a plain data or a Tarantool's *picle.pack()* format specifier for scalar types.
* **Query**
  * *house.new(url, credentials, query [, delimiter])* - create a new query object. *credentials* is a KV set of HTTP headers to use (see examples bellow).
  * *query(table_of_rows)* - make an INSERT query and pass a set of rows in proper format (see examples bellow)
  * *query(raw_string)* - make an INSERT query and pass a raw data string
  * *query({ param1=value1, param2=value2, ... })* - make a parameterized query
  * *query()* - make a non-parameterized query

You are able to create a query object at once and call it many times with differect parameters (data to insert or parameters to query).

## Usage

```SQL
CREATE TABLE SomeData
(
  `ID`       UInt32,
  `Date`     DateTime,
  `Name`     String,
  `Quality`  Nullable(Float32)
)
ENGINE = MergeTree()
ORDER BY `Date`;
```

```Lua
local log     = require('log')
local fiber   = require('fiber')
local pickle  = require('pickle')
local msgpack = require('msgpack')
local house   = require('ClickHouse')

local credentials =
{
  ['X-ClickHouse-User'    ] = 'user',
  ['X-ClickHouse-Key'     ] = 'password',
  ['X-ClickHouse-Database'] = 'database'
}

local query, status, result, list

-- INSERT data in strict form of MessagePack
query = house.new('http://localhost:8123/', credentials, 'INSERT INTO SomeData (ID, Date, Name, Quality) FORMAT MsgPack')
status, result = query(
  {
    msgpack.encode(1) .. msgpack.encode(math.floor(fiber.time())) .. msgpack.encode('Test 1') .. house.getFloat32(1.01),
    msgpack.encode(2) .. msgpack.encode(math.floor(fiber.time())) .. msgpack.encode('Test 2') .. house.getFloat32(2.02)
  })
log.info('ClickHouse call result of query using MessagePack: %s', result)

-- INSERT data in TabSeparated format
query = house.new('http://localhost:8123/', credentials, 'INSERT INTO SomeData (ID, Date, Name, Quality) FORMAT TabSeparated')
status, result = query(
  {
    '3\t2021-01-01 00:00:00\tTest 3\t3.03\n',
    '4\t2021-01-01 00:00:00\tTest 5\t4.04\n'
  })
log.info('ClickHouse call result of query using TabSeparated: %s', result)

-- INSERT data in RowBinary format
query = house.new('http://localhost:8123/', credentials, 'INSERT INTO SomeData (ID, Date, Name, Quality) FORMAT RowBinary')
status, result = query(
  {
    pickle.pack('ii', 5, math.floor(fiber.time())) .. house.getString('Test 5') .. house.getNullable('f', 5.05),
    pickle.pack('ii', 6, math.floor(fiber.time())) .. house.getString('Test 6') .. house.getNullable('f', 6.06)
  })
log.info('ClickHouse call result of query using RowBinary: %s', result)

-- INSERT data in simplified form of MessagePack
query = house.new('http://localhost:8123/', credentials, 'INSERT INTO SomeData (ID, Date, Name) FORMAT MsgPack')
status, result = query(
  {
    house.compose({ 7, math.floor(fiber.time()), 'Test 7' }),
    house.compose({ 8, math.floor(fiber.time()), 'Test 8' })
  })

-- SELECT data using non-parameterized query
query = house.new('http://localhost:8123/', credentials, 'SELECT ID, Date, Name, Quality FORMAT MsgPack')
status, result = query()
if status then
  log.info('Data of non-parameterized query:')
  house.parse(result, 4, log.info)
end

-- SELECT data using parameterized query
query = house.new('http://localhost:8123/', credentials, 'SELECT ID, Date, Name, Quality WHERE ID > {id:UInt32} FORMAT MsgPack')
status, result = query({ id = 3 })
if status then
  list = { }
  house.parse(result, 4, list)
  log.info('Data of parameterized query:')
  log.info(list)
end
```
