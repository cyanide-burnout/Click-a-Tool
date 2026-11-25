package = 'click-a-tool'
version = 'scm-1'

source = {
  url    = 'git+https://github.com/cyanide-burnout/Click-a-Tool.git',
  branch = 'main'
}

description = {
  summary  = 'A light ClickHouse client for Tarantool',
  detailed = [[
Click-a-Tool talks to ClickHouse over its HTTP interface from Tarantool:
INSERT in MsgPack, RowBinary or any text format, SELECT with or without
parameters, requests and data compressed with deflate. Helpers encode the
values ClickHouse wants in a strict form: Float32 and Float64 in MsgPack,
String, UUID, Decimal, DateTime64 and Nullable in RowBinary.
]],
  homepage = 'https://github.com/cyanide-burnout/Click-a-Tool',
  license  = 'Apache-2.0'
}

dependencies = {
  'lua >= 5.1',
  'lua-zlib >= 1.2'
}

build = {
  type    = 'builtin',
  modules = {
    ['ClickHouse'] = 'ClickHouse.lua'
  }
}
