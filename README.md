# Click-a-Tool
A light ClickHouse client for Tarantool

Artem Prilutskiy, 2022-2026

The library talks to ClickHouse over its [HTTP interface](https://clickhouse.com/docs/en/interfaces/http/). Requests and data go compressed with deflate. MessagePack is the preferable format to pass data in. Since ClickHouse takes data in a strict form, there are helper functions to encode some fields that way. Most of the [types](https://clickhouse.com/docs/en/interfaces/formats/#msgpack) can be encoded directly by [the msgpack library of Tarantool](https://www.tarantool.io/en/doc/latest/reference/reference_lua/msgpack/).

The library also supports RowBinary. Most of the scalar types can be encoded by [the pickle library](https://www.tarantool.io/en/doc/latest/reference/reference_lua/pickle/), that is why they are not implemented here. Please read [the description of RowBinary](https://clickhouse.com/docs/en/interfaces/formats/#rowbinary) for details. Use it when you really understand what you are doing, or when you need it, for example to pass UUIDs or Decimals: with RowBinary ClickHouse does not check the types.

A typical use of the library is a batch propagation of data accumulated in Tarantool to ClickHouse. Because of the MessagePack types ClickHouse lacks, our code moved to RowBinary. SELECT queries can use MessagePack with conversion functions on the side of ClickHouse for the types it does not support.

Please read the details of the HTTP interface here: https://clickhouse.com/docs/en/interfaces/http/ \
And the supported formats: https://clickhouse.com/docs/en/interfaces/formats/

About UUIDs over MessagePack in ClickHouse: https://github.com/ClickHouse/ClickHouse/issues/33756 \
Also about UUIDs in Native and Binary formats: https://github.com/ClickHouse/ClickHouse/issues/33910

Please note, the library is written in Lua and uses [the Lua libraries of Tarantool](https://www.tarantool.io/en/doc/latest/reference/reference_lua/) (pickle, msgpack, decimal, datetime, http.client) and C functions of Tarantool via [FFI](https://luajit.org/ext_ffi.html) intensively. It cannot run in a pure Lua environment.

## Requirements

* Tarantool 2.11 or later (datetime and the C API of decimal)
* lua-zlib (`lua-zlib` in Debian and Ubuntu, or the rock of the same name)

## Installation

Copy `ClickHouse.lua` to a directory of `package.path`, or install the rock:

```sh
tt rocks install --server=https://luarocks.org click-a-tool --dev
```

or from a clone of the repository:

```sh
tt rocks make click-a-tool-scm-1.rockspec
```

## API

* **MessagePack**
  * *house.getFloat32(value)* and *house.getFloat64(value)* - encode a float value in the strict form of MessagePack, `nil` becomes NULL
  * *house.compose({ array, of, values, ... })* - encode a set of fields in MessagePack (compatible with ClickHouse)
  * *house.parse(response, count_of_columns, table_to_save)* - parse a response in MessagePack into a table
  * *house.parse(response, count_of_columns, callback [, arguments])* - parse a response in MessagePack and call *callback(row [, arguments])* on each row
* **RowBinary**
  * *house.getLEB128(value)* - encode an unsigned integer value in LEB128
  * *house.getUUID(value)* - encode a UUID. *value* is a string with a binary UUID in network byte order or a *uuid* object of Tarantool.
  * *house.getString(value)* - encode a String of variable length
  * *house.getDecimal(value, scale, size)* - encode a decimal of Tarantool as a Decimal of ClickHouse. *size* is the size in bytes, 4 for Decimal32, 8 for Decimal64. Digits beyond *scale* are floored. For now the function is suitable only when Tarantool runs on little-endian architectures (i386, amd64, aarch64 :)).
  * *house.getDateTime64(value, scale)* - encode a datetime of Tarantool as a DateTime64 of ClickHouse
  * *house.getNullable(format, value [, ...])* - encode a Nullable value, `nil` and `box.NULL` become NULL. *format* is '?' for a String of variable length, '-' for a UUID, '!' for a Decimal (see above), '+' for a DateTime64 (see above), '\*' for data encoded already, or a format of *pickle.pack()* for scalar types.
* **Query**
  * *house.new(url, headers, query [, timeout])* - create a new query object. *headers* is a key-value set of HTTP headers, the credentials among them (see the examples below); the table is copied. *timeout* is the timeout of an HTTP request in seconds, 30 by default. A *query* that starts with INSERT sends its data in the body, any other query is sent in the body itself.
  * *query(table_of_rows)* - make an INSERT query and pass a set of rows in the proper format (see the examples below)
  * *query(raw_string)* - make an INSERT query and pass a raw data string
  * *query({ param1=value1, param2=value2, ... })* - make a parameterized query
  * *query()* - make a non-parameterized query

  Each call returns *true, body of the response* or *false, error*, the error is `HTTP <status>: <message of ClickHouse>` when ClickHouse answers.

You can create a query object once and call it many times with different parameters (data to insert or parameters of a query).

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

## Tests

`Tests/ClickHouseTest.lua` checks the library against a live ClickHouse. `Tests/DockerTest.sh` runs it with ClickHouse and Tarantool in Docker, `Tests/RemoteTest.sh host` does the same on another Docker host over ssh. `CLICKHOUSE_IMAGE` and `TARANTOOL_IMAGE` choose the images.
