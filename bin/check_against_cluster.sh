#!/bin/sh
set -e
PROG="$0"
USAGE="[-h] TANKA_PATH KUBECTL_CONTEXT"

errorout() {
  echo "usage: $PROG $USAGE" >&2
  [ -n "$1" ] && echo "${PROG}: error: $@" >&2
  exit 1
}

printhelp() {
  cat <<EOF
usage: $PROG $USAGE

Alter local tanka files in order to make tk diff possible against a real
cluster.

We've injected all specific cluster details into a kubernetes secret
that presents itself to argocd as /etc/cluster.json, so our tanka code
imports that file. That's all well and good for argocd, but it's
worthless when operating from a workstation.

This script does three things with a KUBECTL_CONTEXT and TANKA_PATH:

1.  Pull TANKA_PATH/live_cluster.json from repo-server:/etc/cluster.json,
2.  Import ./live_cluster.json instead of /etc/cluster.json, and
3.  Set the apiServer in spec.json based on KUBECTL_CONTEXT.

positional arguments:
 TANKA_PATH       Path to the environment to alter
 KUBECTL_CONTEXT  Context to pass to kubectl et al.

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
  TANKA_PATH="$1"
  KUBECTL_CONTEXT="$2"

  validate_environment
  validate_arguments "$@"
  set_api_server_in_spec_json
  pull_cluster_json_from_cluster
  use_local_cluster_json
}

validate_environment() {
  for i in kubectl jsonnet; do
    if ! which "$i" > /dev/null 2>&1; then
      errorout "expected $i to be installed"
    fi
  done
}

validate_arguments() {
  if ! [ -d "$TANKA_PATH" ]; then
    errorout "expected TANKA_PATH to be a directory"
  fi

  if ! [ -f "$TANKA_PATH/spec.json" ]; then
    errorout "expected TANKA_PATH/spec.json to be a file"
  fi

  if [ -z "$KUBECTL_CONTEXT" ]; then
    errorout "expected KUBECTL_CONTEXT"
  fi

  if ! kubectl config get-contexts "$KUBECTL_CONTEXT" > /dev/null 2>&1; then
    errorout "couldn't find context $KUBECTL_CONTEXT in ~/.kube/config"
  fi

  KUBECTL_CLUSTER_SERVER="`get_cluster_server`"
  if [ -z "$KUBECTL_CLUSTER_SERVER" ]; then
    errorout "couldn't extract cluster server from context $KUBECTL_CONTEXT"
  fi

  if [ -z "`get_repo_server_pod`" ]; then
    errorout "couldn't find argocd-repo-server pod in context $KUBECTL_CONTEXT"
  fi

  if ! run_in_argocd_repo_server test -s /etc/cluster.json; then
    errorout "couldn't access cluster.json from $repo_server in context $KUBECTL_CONTEXT"
  fi
}

get_cluster_server() {
  kubectl config view -o jsonpath="{.clusters[?(@.name == \"`get_cluster_name`\")].cluster.server}"
}

get_cluster_name() {
  kubectl config view -o jsonpath="{.contexts[?(@.name == \"$KUBECTL_CONTEXT\")].context.cluster}"
}

set_api_server_in_spec_json() {
  backup_spec_json
  inject_cluster_server_into_spec_json
}

backup_spec_json() {
  if ! [ -f "$TANKA_PATH/spec.json.backup" ]; then
    cp "$TANKA_PATH/spec.json" "$TANKA_PATH/spec.json.backup"
  fi
}

inject_cluster_server_into_spec_json() {
  cat <<EOF | jsonnet - > "$TANKA_PATH/spec.json"
(import './$TANKA_PATH/spec.json.backup') + {
  spec+: { apiServer: '$KUBECTL_CLUSTER_SERVER' }
}
EOF
}

pull_cluster_json_from_cluster() {
  run_in_argocd_repo_server cat /etc/cluster.json \
    > "$TANKA_PATH/live_cluster.json"
}

run_in_argocd_repo_server() {
  kubectl --context "$KUBECTL_CONTEXT" -n argocd \
    exec `get_repo_server_pod` -c tanka-cmp -- "$@"
}

get_repo_server_pod() {
  kubectl --context "$KUBECTL_CONTEXT" -n argocd \
    get pods -l app.kubernetes.io/name=argocd-repo-server -o name \
    | head -n 1
}

use_local_cluster_json() {
  find "$TANKA_PATH" -type f -exec sed -i -e \
    "s,import '/etc/cluster.json',import './live_cluster.json'," '{}' +
}

main "$@"
