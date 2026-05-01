#!/usr/bin/env bash
# Round-trip a request through Backstage's HTTP API to prove the
# backend + Postgres + catalog plugin all initialized and the read
# path works. Strategy:
#
#   1. `kubectl run` a curl pod inside the cluster.
#   2. GET `http://backstage.backstage.svc.cluster.local:7007/api/catalog/entities`.
#      The catalog API returns a JSON array of all registered
#      entities. The `backstage/backstage:latest` demo image ships
#      with example components / APIs / users baked into its
#      `app-config.yaml`'s `catalog.locations`; once Backstage
#      starts, the catalog plugin reads the locations + populates
#      Postgres via the catalog processing loop. Initial population
#      is async — we poll up to 120s for the entity-list response
#      to become a non-empty JSON array.
#
# Proves: Backstage Deployment + Postgres StatefulSet (data path) +
# the catalog plugin's read API + JSON-over-HTTP serialization
# end-to-end. Not "Backstage pod is up". The chart's readiness probe
# already gates on `/.backstage/health/v1/readiness` — the pod is
# Ready well before catalog ingestion completes, so the smoke's
# poll loop is what actually proves catalog ingestion finished.
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
# (config/backstage-values.yaml). Backstage 1.24+ enforces
# service-to-service auth on backend APIs; the curl pod attaches
# this token to satisfy the check.
SMOKE_TOKEN="smoke-fixture-token-do-not-use-in-prod-12345"

echo "smoke_test: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run backstage-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod backstage-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/backstage-curl --for=condition=Ready --timeout=60s

# Poll the catalog API. The catalog plugin processes its configured
# `locations` asynchronously after backend startup; first ingestion
# pass typically completes within 30-60s of the pod going Ready.
echo "smoke_test: polling Backstage /api/catalog/entities"
deadline=$(( $(date +%s) + 120 ))
resp=""
got_data=""
while (( $(date +%s) < deadline )); do
  resp=$("${KCTL[@]}" -n "$NS" exec backstage-curl -- \
      curl -s -w "\nHTTP %{http_code}\n" \
      -H "Authorization: Bearer ${SMOKE_TOKEN}" \
      "http://${BACKSTAGE_HOST}:7007/api/catalog/entities" 2>/dev/null || true)
  # Successful + non-empty: 200 with a JSON array containing at least
  # one object (ie. body starts with `[{`). An empty catalog returns
  # `[]` (HTTP 200 too) — those are the cases we need to keep polling.
  if grep -q "^HTTP 200\$" <<<"$resp" \
       && grep -q '^\[{' <<<"$resp"; then
    got_data="$resp"
    break
  fi
  sleep 3
done

if [[ -z "$got_data" ]]; then
  echo "smoke_test: FAIL — Backstage never returned a non-empty catalog" >&2
  echo "---- last response ----" >&2
  echo "$resp" >&2
  echo "---- backstage logs (tail) ----" >&2
  "${KCTL[@]}" -n backstage logs deploy/backstage --tail=80 >&2 || true
  echo "---- postgresql logs (tail) ----" >&2
  "${KCTL[@]}" -n backstage logs sts/backstage-postgresql --tail=40 >&2 || true
  exit 1
fi

# Quick sanity assertion: pull one of the canonical demo entities
# Backstage ships in its examples (the `Component:default/example-website`
# always appears in the demo image's bootstrap).
if ! grep -q 'example-website\|example-grpc-service' <<<"$got_data"; then
  echo "smoke_test: WARN — none of the canonical demo entities found" >&2
  echo "  (response was non-empty so the catalog plugin loaded; just" >&2
  echo "   no recognizable demo entity. Probably a Backstage version" >&2
  echo "   that bundles different demo data — non-fatal.)" >&2
fi

echo "smoke_test: OK — Backstage catalog API returned 200 + entities (backend + db + plugin all live)"
