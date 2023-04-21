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

1.  Pull TANKA_PATH/live_cluster.json from secret argocd/cluster-details,
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
  validate_environment
  validate_arguments "$@"
  set_api_server_in_spec_json
  pull_cluster_json_from_cluster
  use_local_cluster_json
}

validate_environment() {
  for i in kubectl jsonnet; do
    if ! which "$i" > /dev/null 2>&1; then
      errorout "expected kubectl to be installed"
    fi
  done

  if ! [ -f "~/.kube/config" ]; then
    errorout "expected ~/.kube/config to be a file"
  fi
}

validate_arguments() {
  TANKA_PATH="$1"
  KUBECTL_CONTEXT="$2"

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

  if ! kubectl --context "$KUBECTL_CONTEXT" -n argocd \
      get secret cluster-details > /dev/null; then
    errorout "couldn't get secret argocd/cluster-details in $KUBECTL_CONTEXT"
  fi
}

set_api_server_in_spec_json() {
  backup_spec_json
  local kubeconfig=`add_kube_config_to_cwd`
  extract_api_server_from_kube_config "$kubeconfig"
  rm "$kubeconfig"
}

backup_spec_json() {
  if ! [ -f "$TANKA_PATH/spec.json.backup" ]; then
    cp "$TANKA_PATH/spec.json" "$TANKA_PATH/spec.json.backup"
  fi
}

add_kube_config_to_cwd() {
  # A quirk of jsonnet is that it doesn't seem to understand `~` when
  # importing (and of course environment variables are right out). So
  # there's no easy way to import ~/.kube/config directly, but it is
  # easy enough to make a local copy.
  local kubeconfigfilename=`mktemp kube_XXXXXX.yaml`
  cp ~/.kube/config "$kubeconfigfilename"
  echo "$kubeconfigfilename"
}

extract_api_server_from_kube_config() {
  # Parsing yaml with jsonnet is a bit weird, but I'm trying to operate
  # only with tools that are likely to be installed, and tanka requires
  # jsonnet, so I'm not going to add a dependency on jq if I can do
  # everything I need with jsonnet.
  #
  # This imports both the spec.json and the ~/.kube/config in order to
  # work out the cluster's api server url from the given context. The
  # result is a new spec.json file set with the correct url.
  cat <<EOF | jsonnet - > "$TANKA_PATH/spec.json"
(import './$TANKA_PATH/spec.json.backup') +
{
  local kube_config = std.parseYaml(importstr './$1'),
  local context = [x for x in kube_config.contexts if x.name == '$KUBECTL_CONTEXT'][0],
  spec+: {
    apiServer: [x for x in kube_config.clusters if x.name == context.context.cluster][0].cluster.server
  }
}
EOF
}

pull_cluster_json_from_cluster() {
  kubectl --context "$KUBECTL_CONTEXT" -n argocd \
    get secret cluster-details -o jsonpath='{.data.cluster\.json}' \
    | base64 -d > "$TANKA_PATH/live_cluster.json"
}

use_local_cluster_json() {
  find "$TANKA_PATH" -type f -exec sed -i -e \
    "s,import '/etc/cluster.json',import './live_cluster.json'," '{}' +
}

main "$@"
