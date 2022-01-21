# Click-a-Tool
A light ClickHouse client for Tarantool

Artem Prilutskiy, 2022

Client library uses HTTP interface of ClickHouse to interact with. It is more preferable to use MessagePack format to pass data to. The library uses zlib compression. Since ClickHouse uses strict form of data, there are helper functions to make some data fields in strict format.

Please read details of HTTP interface here: https://clickhouse.com/docs/en/interfaces/http/

About UUIDs over MessagePack in ClickHouse: https://github.com/ClickHouse/ClickHouse/issues/33756

## Requirements

* lua-zlib

## API

* **house.getFloat32(value)** and **house.getFloat64(value)** - get strictly formated float value in MessagePack
* **house.compose({ array, of, values, ... })** - convert set of field to MessagePack (compatible to ClickHouse)
* **house.parse(repoonse, count_of_columns, table_to_save)** - parse MessagePack-formatted response into a table variable
* **house.parse(repoonse, count_of_columns, callback [, arguments])** - parse MessagePack-formatted response and call a *callback(row [, arguments])* on each row 
* **house.new(url, credentials, query [, delimiter])** - create a new query object. *credentials* is a KV set of HTTP headers to use (see examples bellow). *delimiter* is a raw delimiter used to concatinate rows
* **query(table_of_rows)** - make an INSERT query and pass a set of rows formated in proper format (see example bellow)
* **query(raw_string)** - make an INSERT query and pass a raw data string
* **query({ param1=value1, param2=value2, ... })** - make a parameterized query
* **query()** - make a non-parameterized query

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

-- INSERT data in TSV format
query = house.new('http://localhost:8123/', credentials, 'INSERT INTO SomeData (ID, Date, Name, Quality) FORMAT TabSeparated', '\n')
status, result = query(
  {
    '3\t2021-01-01 00:00:00\tTest 3\t3.03',
    '4\t2021-01-01 00:00:00\tTest 5\t4.04'
  })
log.info('ClickHouse call result of query using TSV: %s', result)

-- INSERT data in simplified form of MessagePack
query = house.new('http://localhost:8123/', credentials, 'INSERT INTO SomeData (ID, Date, Name) FORMAT MsgPack')
status, result = query(
  {
    house.compose({ 5, math.floor(fiber.time()), 'Test 5' }),
    house.compose({ 6, math.floor(fiber.time()), 'Test 6' })
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
