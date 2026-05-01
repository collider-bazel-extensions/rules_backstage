#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="cluster"

if [[ -z "${RUNFILES_DIR:-}" ]]; then
  if [[ -d "${0}.runfiles" ]]; then RUNFILES_DIR="${0}.runfiles"
  elif [[ -d "$(dirname "$0").runfiles" ]]; then RUNFILES_DIR="$(dirname "$0").runfiles"
  fi
  export RUNFILES_DIR
fi
INSTALL_BIN="${RUNFILES_DIR}/_main/tests/backstage_install_bin.sh"
[[ -x "$INSTALL_BIN" ]] || { echo "wrapper: backstage_install_bin not at $INSTALL_BIN" >&2; exit 1; }

env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
deadline=$(( $(date +%s) + 60 ))
while [[ ! -f "$env_file" ]]; do
  if (( $(date +%s) >= deadline )); then
    echo "install_wrapper: kind env file never appeared at $env_file" >&2
    exit 1
  fi
  sleep 1
done

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

# v0.1's installs had two CI timeouts on the Backstage Deployment
# Available wait with no useful pod-state output — the kubectl_apply
# launcher only logs "condition not met" until it gives up. This
# trap dumps pod state + Backstage and Postgres logs on install
# failure so future debugging has actual signal to work with.
on_install_fail() {
  local rc=$?
  echo "===== install_wrapper: install_bin exited $rc — dumping cluster state =====" >&2
  echo "---- pods/deployments/statefulsets (-n backstage) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n backstage get pods,deploy,sts -o wide >&2 || true
  echo "---- describe deploy/backstage ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n backstage describe deploy/backstage >&2 || true
  echo "---- backstage logs (--all-containers, --tail=200) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n backstage logs deploy/backstage --all-containers --tail=200 >&2 || true
  echo "---- backstage logs --previous (catches crash-loop crashes) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n backstage logs deploy/backstage --all-containers --previous --tail=200 >&2 || true
  echo "---- postgresql logs (--tail=80) ----" >&2
  "$KUBECTL" --kubeconfig="$KUBECONFIG" -n backstage logs sts/backstage-postgresql --tail=80 >&2 || true
  exit "$rc"
}
trap on_install_fail ERR

# `exec` replaces this shell — the trap won't fire. Run as a child so
# the trap stays active.
"$INSTALL_BIN"
