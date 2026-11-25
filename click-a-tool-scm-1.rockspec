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

-- zlib (lua-zlib) is not a dependency here: the Docker images of Tarantool have it, Debian and Ubuntu have
-- the lua-zlib package, and rocks.tarantool.org has no rock of it, see Installation in README.md
dependencies = {
  'lua ~> 5.1',
  'tarantool >= 3.0'
}

build = {
  type    = 'builtin',
  modules = {
    ['ClickHouse'] = 'ClickHouse.lua'
  }
}
