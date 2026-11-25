#!/bin/sh
# Copies the working tree to a Docker host and runs Tests/DockerTest.sh there:
#   Tests/RemoteTest.sh host
# SSH overrides the ssh command; CLICKHOUSE_IMAGE and TARANTOOL_IMAGE go to DockerTest.sh
set -eu

HOST=${1:?usage: Tests/RemoteTest.sh host}
SSH=${SSH:-ssh}
REMOTE=click-a-tool-test

cd "$(dirname "$0")/.."
$SSH "$HOST" "rm -rf $REMOTE && mkdir -p $REMOTE"
COPYFILE_DISABLE=1 tar --no-xattrs --exclude=.git -cf - . | $SSH "$HOST" "tar -xf - -C $REMOTE"
status=0
$SSH "$HOST" "cd $REMOTE && CLICKHOUSE_IMAGE=${CLICKHOUSE_IMAGE:-clickhouse/clickhouse-server:25.3} TARANTOOL_IMAGE=${TARANTOOL_IMAGE:-tarantool/tarantool:3} sh Tests/DockerTest.sh" || status=$?
$SSH "$HOST" "rm -rf $REMOTE"
exit $status
