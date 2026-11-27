# Click-a-Tool

A light ClickHouse client for Tarantool

Artem Prilutskiy, 2022-2026

Click-a-Tool is one Lua module, `ClickHouse`, that sends queries and data from Tarantool to ClickHouse over the [HTTP interface](https://clickhouse.com/docs/en/interfaces/http/) of ClickHouse. It works in fibers: requests go through `http.client` of Tarantool and do not block the event loop. Queries and data are compressed with deflate. With Tarantool 3.9 a query can run in an application thread, so the compression and the request take no CPU of TX.

The typical task is a batch export: Tarantool accumulates records (calls, sessions, events), and a fiber sends them to ClickHouse every few seconds in one INSERT. Helper functions encode values in the strict forms that ClickHouse expects from MessagePack and RowBinary, the binary formats it takes without parsing text.

## Contents

* [Requirements](#requirements)
* [Installation](#installation)
* [Quick start](#quick-start)
* [Queries](#queries)
* [Which format](#which-format)
* [MessagePack](#messagepack)
* [RowBinary](#rowbinary)
* [Reading results](#reading-results)
* [A batch export from a space](#a-batch-export-from-a-space)
* [API](#api)
* [Limitations](#limitations)
* [Tests](#tests)

## Requirements

* Tarantool 3.x; 3.9 or later for queries in an application thread
* lua-zlib (`require('zlib')`): built into the Docker images of Tarantool; elsewhere the `lua-zlib` package of Debian and Ubuntu, or the rock of luarocks.org
* A little-endian machine: amd64 or aarch64
* ClickHouse with the HTTP interface (port 8123 by default); the tests run against ClickHouse 25.3

The module uses the Lua libraries of Tarantool (`http.client`, `msgpack`, `pickle`, `decimal`, `datetime`, `uuid`) and a C function of Tarantool through [FFI](https://luajit.org/ext_ffi.html), so it does not run in plain Lua.

## Installation

Copy `ClickHouse.lua` to a directory of `package.path` of your application, or install the rock from a
clone of the repository:

```sh
tt rocks make click-a-tool-scm-1.rockspec
```

The rock depends on Tarantool 3 only. lua-zlib is not on the rock server of Tarantool, so it is not
a dependency of the rock: the Docker images of Tarantool have it, on Debian and Ubuntu it is a package,
elsewhere it is a rock of luarocks.org (built with the headers of zlib, `git` and `unzip` at hand):

```sh
apt-get install lua-zlib                                 # Debian, Ubuntu
tt rocks install lua-zlib --server=https://luarocks.org   # elsewhere
```

Then:

```lua
local house = require('ClickHouse')
```

## Quick start

```sql
CREATE TABLE SomeData
(
  `ID`      UInt32,
  `Date`    DateTime,
  `Name`    String,
  `Quality` Nullable(Float32)
)
ENGINE = MergeTree()
ORDER BY `Date`;
```

```lua
local log    = require('log')
local fiber  = require('fiber')
local pickle = require('pickle')
local house  = require('ClickHouse')

local headers =
{
  ['X-ClickHouse-User'    ] = 'user',
  ['X-ClickHouse-Key'     ] = 'password',
  ['X-ClickHouse-Database'] = 'database'
}

local insert = house.new('http://localhost:8123/', headers,
  'INSERT INTO SomeData (ID, Date, Name, Quality) FORMAT RowBinary')

local now = math.floor(fiber.time())
local status, result = insert(
  {
    pickle.pack('ii', 1, now) .. house.getString('First')  .. house.getNullable('f', 0.5),
    pickle.pack('ii', 2, now) .. house.getString('Second') .. house.getNullable('f', nil)
  })

if not status then
  log.error('ClickHouse: %s', result)
end
```

## Queries

### A query object

```lua
local query = house.new(url, headers, query_text [, timeout])
local query = house.new(url, headers, query_text, { timeout = 30, thread = 'app', thread_id = 1 })
```

* `url` is the address of the HTTP interface, `http://host:8123/`. Settings of ClickHouse can follow in the query string of the URL, for example `http://host:8123/?async_insert=1&wait_for_async_insert=0`.
* `headers` is a table of HTTP headers. The credentials go here: `X-ClickHouse-User`, `X-ClickHouse-Key` and `X-ClickHouse-Database`. The module copies the table and adds `Content-Encoding: deflate` to its copy; the table of the caller does not change. `nil` means no headers.
* `query_text` is the text of the query. A query that starts with `INSERT` (spaces before it are fine) is an INSERT: its text goes in the URL, and each call sends data in the body. Any other query goes in the body itself, and each call can pass parameters for it in the URL.
* `timeout` is the timeout of each request in seconds, 30 by default. It goes as a number or in a table of options.
* `thread` and `thread_id` in the table of options run the query in an application thread, see [In a thread](#in-a-thread).

The object keeps its HTTP client with one connection alive between calls. Create it once and call it as many times as needed.

### Calls

```lua
local status, result = query(rows)        -- INSERT: a table of rows, each row a string in the format of the query
local status, result = query(raw)         -- INSERT: one string with all the data
local status, result = query(parameters)  -- other queries: { name = value, ... } for {name:Type} in the text
local status, result = query()            -- other queries without parameters
```

The rows of a table are concatenated as they are, so each row has to be complete in the format of the query: a row of RowBinary, a row of MessagePack, or a line of TabSeparated with its `\n`.

Parameters are the [query parameters](https://clickhouse.com/docs/en/interfaces/cli#cli-queries-with-parameters) of ClickHouse: the text has `{name:Type}`, the call passes `{ name = value }`. The values are converted with `tostring()` and escaped in the URL, so a string may contain any characters.

### In a thread

With `thread`, the heavy part of a call runs in an application thread of Tarantool 3.9 or later: the compression of the data and the HTTP request. TX makes the rest as before, the URL with the parameters, the headers and the rows concatenated in one string, and passes them to the thread, so a large INSERT no longer takes the CPU of TX for deflate.

```lua
box.cfg({ app_threads = 1 })  -- the group app of one thread; or threads.groups of the config

local insert = house.new(url, headers, 'INSERT INTO SomeData FORMAT RowBinary', { thread = 'app' })
local status, result = insert(rows)  -- called in TX, as before
```

* `thread` is the name of a group of threads, `thread_id` the thread of it, 1 by default. `house.new()` raises an error when the group or the thread does not exist, or Tarantool has no application threads.
* The first query loads the module in the thread with `threads.eval()` under the name it was required by in TX, with `package.path` and `package.cpath` of TX: keep the paths absolute. The thread then serves the calls through one exported function, `clickhouse.send`.
* The thread sends the requests of all the queries with one HTTP client of its own, which keeps the connections alive, so a query created anew for each batch reuses the connection there.
* The URL, the data as one string, the options of the request and the result cross between TX and the thread as MessagePack.
* Everything else is the same: the calls, the results and the errors. An error of the threads themselves comes as `false, error`.

### Results

A call returns `true, body` on success, where `body` is the response of ClickHouse: empty for an INSERT, the data of a SELECT in its format.

On failure it returns `false, error`:

* `HTTP <status>: <message>` when ClickHouse answers with an error, for example `HTTP 404: Code: 60. DB::Exception: ... (UNKNOWN_TABLE)`;
* `HTTP <status>: <reason>` with a status of `http.client` (595 and so on) when the request could not connect or timed out;
* the text of a Lua error raised while sending.

A call does not raise errors itself, so a loop that sends data can log the error and retry later. The helpers of MessagePack and RowBinary below do raise errors on values they cannot encode.

## Which format

| Format | Use it for | Type checks of ClickHouse |
|---|---|---|
| RowBinary | INSERT of large batches, UUID, Decimal, DateTime64 | none: a wrong type shifts the rest of the row |
| MessagePack (`FORMAT MsgPack`) | INSERT of simple types; the results of SELECT | yes |
| TabSeparated, JSONEachRow and other text formats | small or occasional data, debugging | yes |

RowBinary is the fastest and the most precise, but ClickHouse reads it blindly: the encoding of each value has to match the type of its column exactly, in the order of the columns of the INSERT. A mistake either fails the whole INSERT or, worse, writes wrong values. Write the encoding of a row once, next to the list of columns, and test it against a real table.

MessagePack lets ClickHouse check the types, but not every type of ClickHouse has a form in MessagePack: see the [description of the format](https://clickhouse.com/docs/en/interfaces/formats/MsgPack), and the issues about [UUID in MessagePack](https://github.com/ClickHouse/ClickHouse/issues/33756) and [UUID in binary formats](https://github.com/ClickHouse/ClickHouse/issues/33910). That is why inserts with UUIDs and Decimals moved to RowBinary.

## MessagePack

`msgpack.encode()` of Tarantool encodes most values as ClickHouse expects them. The exceptions are floats and whole rows.

| Column | Encode with |
|---|---|
| Int*, UInt* | `msgpack.encode(value)` |
| Float32 | `house.getFloat32(value)` |
| Float64 | `house.getFloat64(value)` |
| String, FixedString | `msgpack.encode(value)` |
| DateTime | `msgpack.encode(seconds)`, an integer of the Unix time |
| Date | `msgpack.encode(days)`, days since 1970-01-01 |
| Nullable(T) | `msgpack.encode(box.NULL)` for NULL, the value otherwise; `getFloat32(nil)` and `getFloat64(nil)` give NULL too |

`msgpack.encode()` turns a Lua number without a fraction, like `2`, into an integer of MessagePack, which a Float column does not take. `getFloat32()` and `getFloat64()` always encode float 32 and float 64.

A row of MessagePack is its values one after another, without the header of an array. Concatenate the encoded values, or let `house.compose()` encode a whole row:

```lua
local insert = house.new(url, headers, 'INSERT INTO SomeData (ID, Date, Name, Quality) FORMAT MsgPack')

insert(
  {
    msgpack.encode(1) .. msgpack.encode(now) .. msgpack.encode('First') .. house.getFloat32(1),
    house.compose({ 2, now, 'Second', box.NULL })
  })
```

`house.compose()` uses `msgpack.encode()` for each value, so it suits rows without Float columns. Put `box.NULL` for NULL, not `nil`: a `nil` in the middle of a Lua table can turn the table into a map.

## RowBinary

A row of RowBinary is the binary forms of its values one after another. Most of them are scalars that [`pickle.pack()`](https://www.tarantool.io/en/doc/latest/reference/reference_lua/pickle/) of Tarantool encodes; the module encodes the rest. All the numbers are little-endian.

| Column | Encode with |
|---|---|
| UInt8, Int8, Bool, Enum8 | `pickle.pack('b', value)` |
| UInt16, Int16, Enum16, Date (days) | `pickle.pack('s', value)` |
| UInt32, Int32, DateTime (seconds) | `pickle.pack('i', value)` |
| UInt64, Int64 | `pickle.pack('l', value)` |
| Float32 | `pickle.pack('f', value)` |
| Float64 | `pickle.pack('d', value)` |
| String, LowCardinality(String) | `house.getString(value)` |
| FixedString(N) | the N bytes of the value as they are |
| UUID | `house.getUUID(value)` |
| Decimal32(S) | `house.getDecimal(value, S, 4)` |
| Decimal64(S) | `house.getDecimal(value, S, 8)` |
| Decimal128(S) | `house.getDecimal(value, S, 16)` |
| DateTime64(P) | `house.getDateTime64(value, P)` |
| Nullable(T), LowCardinality(Nullable(T)) | `house.getNullable(format, value, ...)`, see below |

Several scalars can share one `pickle.pack()`: `pickle.pack('iib', id, time, kind)`.

* `house.getString(value)` is the length of the string in LEB128 and its bytes.
* `house.getUUID(value)` takes a `uuid` object, a UUID as text (`'f47ac10b-58cc-4372-a567-0e02b2c3d479'`) or its 16 bytes in network byte order. ClickHouse stores a UUID as two 64-bit halves, each little-endian; the function swaps them.
* `house.getDecimal(value, scale, size)` takes a `decimal`, a number or a string. It multiplies the value by 10 to the power of the scale, floors the digits beyond the scale and writes the integer in `size` bytes. A value that does not fit raises an error, so does a size other than 4, 8 and 16. For Decimal128 the integer has to fit into Int64 as well, which covers 18 digits.
* `house.getDateTime64(value, precision)` takes a `datetime` object and writes its ticks since the Unix epoch, `precision` from 0 to 9 digits of a second: 3 for milliseconds, 6 for microseconds. The digits beyond the precision are floored. The time zone of the column is only how ClickHouse shows the value; the stored ticks are UTC.

### Nullable

`house.getNullable(format, value, ...)` writes the byte of NULL, `1`, when `value` is `nil` or `box.NULL`. Otherwise it writes `0` and the value in the form `format` names:

| format | Value | The same as |
|---|---|---|
| a letter of `pickle.pack()`: `'b'`, `'s'`, `'i'`, `'l'`, `'f'`, `'d'` | a number | `pickle.pack(format, value)` |
| `'?'` | String | `house.getString(value)` |
| `'-'` | UUID | `house.getUUID(value)` |
| `'!'` | Decimal, then `scale, size` | `house.getDecimal(value, scale, size)` |
| `'+'` | DateTime64, then `precision` | `house.getDateTime64(value, precision)` |
| `'*'` | a value encoded already, or a FixedString | the string as it is |

```lua
house.getNullable('i', count)              -- Nullable(UInt32)
house.getNullable('?', name)               -- Nullable(String), LowCardinality(Nullable(String))
house.getNullable('-', aggregate)          -- Nullable(UUID)
house.getNullable('!', price, 2, 8)        -- Nullable(Decimal64(2))
house.getNullable('+', updated, 3)         -- Nullable(DateTime64(3))
```

## Reading results

Ask for `FORMAT MsgPack` and parse the response with `house.parse()`. A response of MessagePack is the values of all the rows one after another, so `parse()` needs the number of columns:

```lua
local query = house.new(url, headers,
  'SELECT ID, Name, Quality FROM SomeData WHERE ID > {id:UInt32} ORDER BY ID FORMAT MsgPack')

local status, result = query({ id = 100 })
if status then
  local rows = { }
  house.parse(result, 3, rows)                -- rows[1] = { 101, 'Name', 0.5 }, ...
end
```

or call a function on each row, with extra arguments if needed:

```lua
house.parse(result, 3, function (row, space)
  space:replace(row)
end, box.space.SomeCopy)
```

NULL comes as `box.NULL`. Convert the types MessagePack has no form for on the side of ClickHouse:

| Column | In SELECT | Comes as |
|---|---|---|
| UUID | `toString(Key)` | a string |
| Decimal | `toString(Amount)` | a string, for `decimal.new()` |
| DateTime64(3) | `toUnixTimestamp64Milli(Moment)` | an integer of milliseconds |
| DateTime | `toUnixTimestamp(Date)` | an integer of seconds |

Any other format works as well: the body is the response as ClickHouse sent it, and the lines of `FORMAT JSONEachRow` can go to `json.decode()` one by one.

## A batch export from a space

This is how the module runs in production: a record is encoded in RowBinary as soon as it is final, waits in a space, and a fiber sends the waiting rows in batches. When ClickHouse is not available, the rows stay in the space until the next attempt.

```lua
local log    = require('log')
local fiber  = require('fiber')
local pickle = require('pickle')
local house  = require('ClickHouse')

-- From the configuration of the application
local address = 'http://localhost:8123/'
local headers = { ['X-ClickHouse-User'] = 'user', ['X-ClickHouse-Key'] = 'password', ['X-ClickHouse-Database'] = 'database' }

box.schema.space.create('ExportCache', { if_not_exists = true })
box.space.ExportCache:create_index('Key', { if_not_exists = true, parts = { 1, 'string' } })

-- Called when a record is final
local function put(record)
  local row =
    pickle.pack('i', record.instance) .. house.getUUID(record.session) ..
    house.getDateTime64(record.created, 3) .. house.getDateTime64(record.updated, 3) ..
    pickle.pack('ii', record.source, record.destination) ..
    house.getNullable('?', record.name) .. house.getNullable('l', record.count)
  box.space.ExportCache:replace({ record.key, row })
end

local function post()
  local set   = box.space.ExportCache:select(nil, { fullscan = true, limit = 8192 })
  local data  = { }
  local query = house.new(address, headers,
    'INSERT INTO Records (Instance, Session, Created, Updated, SourceID, DestinationID, Name, Count) FORMAT RowBinary')

  for _, tuple in ipairs(set) do
    table.insert(data, tuple[2])
  end

  local status, result = query(data)
  if not status then
    log.error('Error posting data to ClickHouse: %s', result)
    return
  end

  -- Only after ClickHouse took them
  for _, tuple in ipairs(set) do
    box.space.ExportCache:delete(tuple[1])
  end
end

fiber.create(function ()
  local worker
  while not fiber.testcancel() do
    if box.space.ExportCache:len() > 0 and (worker == nil or worker:status() == 'dead') then
      -- Each attempt in a fiber of its own: a failure of the request never stops this loop
      worker = fiber.create(post)
    end
    fiber.sleep(10)
  end
end)
```

A few notes from production:

* The limit of `select()` keeps an INSERT in a size ClickHouse takes in one go, even after a long outage.
* A version of the row format next to each cached row lets an update of the code skip rows encoded for the old list of columns.
* ClickHouse prefers fewer, bigger INSERTs: sending every 10 seconds or so is better than every row. With many small writers, `?async_insert=1` in the URL lets ClickHouse batch them.

## API

### Queries

| Function | Description |
|---|---|
| `house.new(url, headers, query [, timeout])` | Creates a query object, see [Queries](#queries) |
| `house.new(url, headers, query, options)` | The same with `{ timeout, thread, thread_id }`, see [In a thread](#in-a-thread) |
| `house.serve()` | Exports the function of the module in a thread; the first query in the thread calls it |
| `query(rows)`, `query(raw)` | Runs an INSERT with the data |
| `query(parameters)`, `query()` | Runs another query, with or without parameters |

### MessagePack

| Function | Description |
|---|---|
| `house.getFloat32(value)` | A float 32 of MessagePack, `nil` gives NULL |
| `house.getFloat64(value)` | A float 64 of MessagePack, `nil` gives NULL |
| `house.compose({ values })` | A row of MessagePack from a Lua table |
| `house.parse(response, columns, table)` | Appends the rows of a response to a table |
| `house.parse(response, columns, function [, ...])` | Calls `function(row, ...)` on each row of a response |

### RowBinary

| Function | Description |
|---|---|
| `house.getLEB128(value)` | An unsigned integer in LEB128 |
| `house.getString(value)` | A String |
| `house.getUUID(value)` | A UUID from a `uuid`, its text or its 16 bytes |
| `house.getDecimal(value, scale, size)` | A Decimal32, Decimal64 or Decimal128 (size 4, 8, 16) |
| `house.getDateTime64(value, precision)` | A DateTime64 from a `datetime` |
| `house.getNullable(format, value [, ...])` | A Nullable, see [Nullable](#nullable) |

## Limitations

* Little-endian machines only: RowBinary is little-endian, and the module writes the memory of integers as it is.
* Decimal128 only within the range of Int64 after the scale. The helpers do not encode Decimal256, Int128 and Int256.
* RowBinary has no type checks: test the encoding of a row against a real table.
* The response of a SELECT is held in memory as one string: use LIMIT or several queries for large results.

## Tests

`Tests/ClickHouseTest.lua` checks every helper and every form of a query against a live ClickHouse: MessagePack, TabSeparated and RowBinary with all the forms of Nullable, UUID, Decimal32, Decimal64 and Decimal128, DateTime64, long strings, parameters with special characters, settings in the URL, errors of ClickHouse and a refused connection. With `THREAD=1` every query runs in an application thread, and fibers call one query object there at once.

* `Tests/DockerTest.sh` runs it with ClickHouse and Tarantool in Docker.
* `Tests/RemoteTest.sh host` does the same on another Docker host over ssh.
* `CLICKHOUSE_IMAGE` and `TARANTOOL_IMAGE` choose the images, `clickhouse/clickhouse-server:25.3` and `tarantool/tarantool:3` by default.
* `THREAD=1` runs the queries in a thread: `TARANTOOL_IMAGE=tarantool/tarantool:3.9.0 THREAD=1 Tests/DockerTest.sh`.

## License

Apache License 2.0, see [LICENSE](LICENSE).
