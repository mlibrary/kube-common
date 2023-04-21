#!/bin/sh
set -e
PROG="$0"
USAGE="[-h] TANKA_PATH"

errorout() {
  echo "usage: $PROG $USAGE" >&2
  [ -n "$1" ] && echo "${PROG}: error: $@" >&2
  exit 1
}

printhelp() {
  cat <<EOF
usage: $PROG $USAGE

Undo check_against_cluster.sh

This does three things with a TANKA_PATH:

1.  Delete TANKA_PATH/live_cluster.json,
2.  Import /etc/cluster.json instead of ./live_cluster.json, and
3.  Restore the original spec.json with an empty apiServer.

positional arguments:
 TANKA_PATH       Path to the environment to restore

optional arguments:
 -h               Show this help message and exit
EOF
}

while getopts ':h' opt; do
  case "$opt" in
    h)
      printhelp
      exit 0
      ;;

    ?)
      errorout "unrecognized argument: \`-$opt'"
      ;;
  esac
done
shift $((OPTIND - 1))

main() {
  validate_arguments "$@"
  rm -f "$TANKA_PATH/live_cluster.json"
  find "$TANKA_PATH" -type f -exec sed -i -e \
    "s,import './live_cluster.json',import '/etc/cluster.json'," '{}' +
  if [ -f "$TANKA_PATH/spec.json.backup" ]; then
    mv "$TANKA_PATH/spec.json.backup" "$TANKA_PATH/spec.json"
  fi
}

validate_arguments() {
  TANKA_PATH="$1"

  if ! [ -d "$TANKA_PATH" ]; then
    errorout "expected TANKA_PATH to be a directory"
  fi

  if ! [ -f "$TANKA_PATH/spec.json" ]; then
    errorout "expected TANKA_PATH/spec.json to be a file"
  fi
}

main "$@"
