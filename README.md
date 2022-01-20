# Click-a-Tool
A light ClickHouse client for Tarantool
Artem Prilutskiy, 2022

Client library uses HTTP interface of ClickHouse to interact with. It is more preferable to use MessagePack format to pass data to.
I didn't implement (yet) parsing of responses containing a data because we use it only for batch insertion. The library uses zlib compression.

Since ClickHouse uses strict form of data, there are helper functions to make some data fields in strict format:
* getFloat32
* getFloat64

Also I am going to add passing of UUIDs over MessagePack when it will be implemented in ClickHouse (https://github.com/ClickHouse/ClickHouse/issues/33756)


## Requirements

* lua-zlib

## Usage

...
CREATE TABLE SomeData
(
  `ID`       UInt32,
  `Date`     DateTime,
  `Name`     String,
  `Quality`  Nullable(Float32)
)
ENGINE = MergeTree()
ORDER BY `Created`;
...

...
local log     = require('log')
local fiber   = require('fiber')
local msgpack = require('msgpack')
local house   = require('ClickHouse')

local credentials = { ['X-ClickHouse-User'] = 'user', ['X-ClickHouse-Key'] = 'password', ['X-ClickHouse-Database'] = 'database' }

local query, status, result

query = house.new('http://localhost:8123/', credentials, 'INSERT INTO SomeData (ID, Date, Name, Quality) FORMAT MsgPack')
status, result = query(
  {
    msgpack.encode(1) .. msgpack.encode(math.floor(fiber.time())) .. msgpack.encode('Test 1') .. house.getFloat32(1.01),
    msgpack.encode(2) .. msgpack.encode(math.floor(fiber.time())) .. msgpack.encode('Test 2') .. house.getFloat32(2.02)
  })

log.info('ClickHouse call result of query using MessagePack: %s', result)

query = house.new('http://localhost:8123/', credentials, 'INSERT INTO SomeData (ID, Date, Name, Quality) FORMAT TabSeparated', '\n')
status, result = query2(
  {
    '3\t2021-01-01 00:00:00\tTest 3\t3.03',
    '4\t2021-01-01 00:00:00\tTest 5\t4.04'
  })

log.info('ClickHouse call result of query using TSV: %s', result)
...
