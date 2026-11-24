#!/bin/bash
# Retry a command up to 5 times with backoff. Exit code 23 (rsync partial) is not retried.
for i in 1 2 3 4 5; do
  "$@" && exit 0
  c=$?
  [ "$c" -eq 23 ] && exit 23
  echo "retry $i/5 after exit $c: $1" >&2
  [ "$i" -lt 5 ] && sleep $((i * 10))
done
exit "$c"
