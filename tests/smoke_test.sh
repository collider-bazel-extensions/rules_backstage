#!/usr/bin/env bash
# Hit Backstage's HTTP server through its in-cluster Service to
# prove the backend's HTTP path is reachable end-to-end. Strategy:
#
#   1. `kubectl run` a curl pod inside the cluster.
#   2. GET `http://backstage.backstage.svc.cluster.local:7007/.backstage/health/v1/readiness`
#      — Backstage's unauthenticated readiness endpoint. Returns
#      `{"status":"ok"}` once the backend has fully booted, connected
#      to Postgres, and finished initial plugin setup.
#
# Proves: Backstage Deployment + Postgres StatefulSet + backend
# HTTP server wiring + the chart's Service all reachable from
# inside the cluster. Not "Backstage pod is up" alone — the
# readiness endpoint flips to 200 only after the backend's
# internal init (database migrations, plugin loading) completes.
# kubelet's readinessProbe already gates on it, but the smoke
# proves the path is also reachable through the Service from
# another pod — which is the realistic consumer access pattern.
#
# What this does NOT prove (deferred to v0.2):
#   - Authenticated catalog round-trip. Backstage 1.24+ enforces
#     service-to-service auth on backend APIs. Two appConfig
#     overrides we tried
#     (`backend.auth.dangerouslyDisableDefaultAuthPolicy` and
#      `backend.auth.externalAccess: [{type: static, ...}]`) both
#     broke backend startup — chart's appConfig override
#     mechanism doesn't merge cleanly with the demo image's
#     baked-in app-config for these keys. v0.2 likely needs a
#     custom-built Backstage image with auth baked in, or a
#     larger investment in the chart's secret-management knobs.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
BACKSTAGE_HOST="backstage.backstage.svc.cluster.local"

echo "smoke_test: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run backstage-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod backstage-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/backstage-curl --for=condition=Ready --timeout=60s

# Poll the readiness endpoint. The Deployment is already Available
# at this point (the install macro waited on it) — but we still
# poll because the Available check counts replicas, not the
# readiness probe's eventual settled-200 state. Allow 60s.
echo "smoke_test: polling Backstage /.backstage/health/v1/readiness"
deadline=$(( $(date +%s) + 60 ))
resp=""
got_data=""
while (( $(date +%s) < deadline )); do
  resp=$("${KCTL[@]}" -n "$NS" exec backstage-curl -- \
      curl -s -w "\nHTTP %{http_code}\n" \
      "http://${BACKSTAGE_HOST}:7007/.backstage/health/v1/readiness" 2>/dev/null || true)
  if grep -q "^HTTP 200\$" <<<"$resp" \
       && grep -q '"status":"ok"' <<<"$resp"; then
    got_data="$resp"
    break
  fi
  sleep 2
done

if [[ -z "$got_data" ]]; then
  echo "smoke_test: FAIL — Backstage readiness endpoint never returned 200/ok" >&2
  echo "---- last response ----" >&2
  echo "$resp" >&2
  echo "---- backstage logs (tail) ----" >&2
  "${KCTL[@]}" -n backstage logs deploy/backstage --tail=80 >&2 || true
  echo "---- postgresql logs (tail) ----" >&2
  "${KCTL[@]}" -n backstage logs sts/backstage-postgresql --tail=40 >&2 || true
  exit 1
fi

echo "smoke_test: OK — Backstage backend reachable through Service (HTTP path + DB + plugin init all live)"
