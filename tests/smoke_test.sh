#!/usr/bin/env bash
# Authenticated catalog round-trip through Backstage's HTTP API.
# Strategy:
#
#   1. `kubectl run` a curl pod inside the cluster.
#   2. GET /.backstage/health/v1/readiness — sanity check that
#      Backstage is reachable through the Service. No auth required.
#   3. Bearer-auth GET /api/catalog/entities — Backstage 1.24+
#      enforces service-to-service auth on backend APIs. The token
#      below is wired into the backend's app-config via the chart's
#      `appConfig.backend.auth.externalAccess: [{type: static, ...}]`
#      (config/backstage-values.yaml).
#   4. Assert the response is HTTP 200 with a non-empty JSON array.
#      The `backstage/backstage:latest` demo image's bundled
#      app-config registers example catalog locations; the catalog
#      plugin's processing loop reads them + writes entities to
#      Postgres after backend startup.
#
# Proves: Backstage backend HTTP path + Postgres data path +
# catalog plugin's ingestion loop + the read API + service-to-service
# auth + JSON-over-HTTP serialization end-to-end.
set -euo pipefail

CLUSTER_NAME="cluster"
env_file="$TEST_TMPDIR/${CLUSTER_NAME}.env"
[[ -f "$env_file" ]] || { echo "missing kind env file" >&2; exit 1; }
# shellcheck disable=SC1090
source "$env_file"

KCTL=("$KUBECTL" --kubeconfig="$KUBECONFIG")

NS="smoke"
BACKSTAGE_HOST="backstage.backstage.svc.cluster.local"
# Bearer token wired in via `appConfig.backend.auth.externalAccess`
# (config/backstage-values.yaml). Production consumers replace this
# hardcoded value with a Secret-mounted env var.
SMOKE_TOKEN="smoke-fixture-token-do-not-use-in-prod-12345"

echo "smoke_test: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run backstage-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod backstage-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/backstage-curl --for=condition=Ready --timeout=60s

# Sanity: the readiness endpoint should be 200 already since the
# install wait gated on the Deployment being Available. If this
# fails we know the Service / DNS / pod readiness is the issue
# (not the catalog plugin specifically).
echo "smoke_test: sanity-check Backstage readiness"
ready_resp=$("${KCTL[@]}" -n "$NS" exec backstage-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    "http://${BACKSTAGE_HOST}:7007/.backstage/health/v1/readiness" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$ready_resp"; then
  echo "smoke_test: FAIL — readiness endpoint not 200" >&2
  echo "$ready_resp" >&2
  exit 1
fi

# Poll the catalog API. Catalog ingestion is async after backend
# startup; first-pass typically completes within 30-60s of the pod
# going Ready. Allow up to 180s (the locations include GitHub-hosted
# YAMLs which the demo image fetches at runtime — slow CI runners
# can take a while on the first fetch).
echo "smoke_test: polling Backstage /api/catalog/entities (Bearer auth)"
deadline=$(( $(date +%s) + 180 ))
resp=""
got_data=""
while (( $(date +%s) < deadline )); do
  resp=$("${KCTL[@]}" -n "$NS" exec backstage-curl -- \
      curl -s -w "\nHTTP %{http_code}\n" \
      -H "Authorization: Bearer ${SMOKE_TOKEN}" \
      "http://${BACKSTAGE_HOST}:7007/api/catalog/entities" 2>/dev/null || true)
  # Successful + non-empty: HTTP 200 with body that starts with `[{`
  # (a JSON array containing at least one object). HTTP 200 + `[]`
  # means catalog plugin ingestion hasn't run yet — keep polling.
  if grep -q "^HTTP 200\$" <<<"$resp" \
       && grep -q '^\[{' <<<"$resp"; then
    got_data="$resp"
    break
  fi
  sleep 3
done

if [[ -z "$got_data" ]]; then
  echo "smoke_test: FAIL — Backstage catalog never returned a non-empty entity list" >&2
  echo "---- last response ----" >&2
  echo "$resp" >&2
  echo "---- backstage logs (tail) ----" >&2
  "${KCTL[@]}" -n backstage logs deploy/backstage --tail=80 >&2 || true
  echo "---- postgresql logs (tail) ----" >&2
  "${KCTL[@]}" -n backstage logs sts/backstage-postgresql --tail=40 >&2 || true
  exit 1
fi

echo "smoke_test: OK — Backstage catalog API returned 200 + entities (auth + DB + catalog plugin all live)"
