#!/bin/sh
# Runs Tests/ClickHouseTest.lua in Tarantool against ClickHouse, both in Docker:
#   Tests/DockerTest.sh
# CLICKHOUSE_IMAGE and TARANTOOL_IMAGE choose the images, THREAD=1 runs the queries in a thread
set -eu

CLICKHOUSE_IMAGE=${CLICKHOUSE_IMAGE:-clickhouse/clickhouse-server:25.3}
TARANTOOL_IMAGE=${TARANTOOL_IMAGE:-tarantool/tarantool:3}
NAME=click-a-tool-test-$$

cd "$(dirname "$0")/.."

cleanup() {
  docker rm -f -v "$NAME-clickhouse" >/dev/null 2>&1 || true
  docker network rm "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker network create "$NAME" >/dev/null
docker run -d --name "$NAME-clickhouse" --network "$NAME" --network-alias clickhouse \
  -e CLICKHOUSE_DB=test -e CLICKHOUSE_USER=test -e CLICKHOUSE_PASSWORD=test \
  --ulimit nofile=262144:262144 "$CLICKHOUSE_IMAGE" >/dev/null

# lua-zlib of Ubuntu (the images of Tarantool 3) is built for Lua 5.1 and loads in LuaJIT
docker run --rm --network "$NAME" --user 0 -v "$PWD:/src:ro" -w /src \
  -e CLICKHOUSE_URL=http://clickhouse:8123/ -e THREAD="${THREAD:-}" --entrypoint sh "$TARANTOOL_IMAGE" -c '
    apt-get -qq update >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y lua-zlib >/dev/null
    # The image names an instance of a cluster config, a plain script has none
    unset TT_APP_NAME TT_INSTANCE_NAME
    export LUA_CPATH="/usr/lib/$(uname -m)-linux-gnu/lua/5.1/?.so;;"
    exec tarantool Tests/ClickHouseTest.lua'
