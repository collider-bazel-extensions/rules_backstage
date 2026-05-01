#!/usr/bin/env bash
# Authenticated catalog WRITE + READ round-trip through Backstage's
# HTTP API.
# Strategy:
#
#   1. `kubectl run` a curl pod inside the cluster.
#   2. GET /.backstage/health/v1/readiness — sanity check that
#      Backstage is reachable through the Service. No auth required.
#   3. POST /api/catalog/locations with `{type: url, target: <raw
#      github URL of tests/fixtures/smoke-component.yaml>}` —
#      Backstage's `url` reader fetches the YAML server-side, parses
#      it, and writes the Component entity into Postgres.
#   4. Poll GET /api/catalog/entities until the freshly-ingested
#      `rules-backstage-smoke` Component shows up. Catalog ingestion
#      is async after location registration.
#   5. Both calls carry the static-token Bearer auth wired through
#      `appConfig.backend.auth.externalAccess`
#      (config/backstage-values.yaml).
#
# Proves: Backstage backend HTTP path + Postgres data path + catalog
# plugin's location-processor + entity-ingestor + the read API +
# service-to-service auth + JSON-over-HTTP serialization end-to-end.
# Exercises BOTH documented catalog API surfaces (POST /locations
# and GET /entities), not just the read path.
#
# Hermeticity note: Backstage fetches the fixture YAML from
# raw.githubusercontent.com server-side. Same network shape as
# rules_argocd's example-apps fetch. Local maintainer flow needs
# outbound HTTPS to github.
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
# Pinned to `main` — the smoke runs in CI after the push, so the
# fixture file is already visible at this URL by the time the smoke
# fires. Local maintainer runs use whatever's currently on `main`.
FIXTURE_URL="https://raw.githubusercontent.com/collider-bazel-extensions/rules_backstage/main/tests/fixtures/smoke-component.yaml"
ENTITY_NAME="rules-backstage-smoke"

echo "smoke_test: launching curl pod"
"${KCTL[@]}" create namespace "$NS" --dry-run=client -o yaml | "${KCTL[@]}" apply -f - >/dev/null
"${KCTL[@]}" -n "$NS" run backstage-curl --restart=Never --image=curlimages/curl:8.10.1 \
    --command -- sleep 600
trap '"${KCTL[@]}" -n "$NS" delete pod backstage-curl --ignore-not-found --wait=false >/dev/null 2>&1 || true' EXIT
"${KCTL[@]}" -n "$NS" wait pod/backstage-curl --for=condition=Ready --timeout=60s

# Sanity: readiness should be 200 already since the install wait
# gated on the Deployment being Available.
echo "smoke_test: sanity-check Backstage readiness"
ready_resp=$("${KCTL[@]}" -n "$NS" exec backstage-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    "http://${BACKSTAGE_HOST}:7007/.backstage/health/v1/readiness" 2>/dev/null || true)
if ! grep -q "^HTTP 200\$" <<<"$ready_resp"; then
  echo "smoke_test: FAIL — readiness endpoint not 200" >&2
  echo "$ready_resp" >&2
  exit 1
fi

# Register the location. Backstage fetches the YAML, parses it, and
# kicks off ingestion. POST returns 201 with the parsed entities; we
# don't assert on the response body shape here — the GET poll below
# is the authoritative round-trip check.
echo "smoke_test: POST /api/catalog/locations (target=${FIXTURE_URL})"
post_body=$(printf '{"type":"url","target":"%s"}' "$FIXTURE_URL")
post_resp=$("${KCTL[@]}" -n "$NS" exec backstage-curl -- \
    curl -s -w "\nHTTP %{http_code}\n" \
    -X POST \
    -H "Authorization: Bearer ${SMOKE_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$post_body" \
    "http://${BACKSTAGE_HOST}:7007/api/catalog/locations" 2>/dev/null || true)
# Accept 201 (created) or 409 (already exists from a flaky retry —
# shouldn't happen in fresh CI but defensive).
if ! grep -qE "^HTTP (201|409)\$" <<<"$post_resp"; then
  echo "smoke_test: FAIL — POST /api/catalog/locations did not return 201/409" >&2
  echo "$post_resp" >&2
  echo "---- backstage logs (tail) ----" >&2
  "${KCTL[@]}" -n backstage logs deploy/backstage --tail=80 >&2 || true
  exit 1
fi

# Poll the catalog until our entity shows up. Ingestion after
# location registration is async — typically completes within
# 10-30s in a cold cluster, but allow up to 180s for slow CI
# runners + the GitHub fetch.
echo "smoke_test: polling /api/catalog/entities for Component '${ENTITY_NAME}'"
deadline=$(( $(date +%s) + 180 ))
resp=""
got_entity=""
while (( $(date +%s) < deadline )); do
  resp=$("${KCTL[@]}" -n "$NS" exec backstage-curl -- \
      curl -s -w "\nHTTP %{http_code}\n" \
      -H "Authorization: Bearer ${SMOKE_TOKEN}" \
      "http://${BACKSTAGE_HOST}:7007/api/catalog/entities" 2>/dev/null || true)
  if grep -q "^HTTP 200\$" <<<"$resp" \
       && grep -q "\"name\":\"${ENTITY_NAME}\"" <<<"$resp"; then
    got_entity="$resp"
    break
  fi
  sleep 3
done

if [[ -z "$got_entity" ]]; then
  echo "smoke_test: FAIL — Component '${ENTITY_NAME}' never appeared in /api/catalog/entities" >&2
  echo "---- last response ----" >&2
  echo "$resp" >&2
  echo "---- backstage logs (tail) ----" >&2
  "${KCTL[@]}" -n backstage logs deploy/backstage --tail=120 >&2 || true
  echo "---- postgresql logs (tail) ----" >&2
  "${KCTL[@]}" -n backstage logs sts/backstage-postgresql --tail=40 >&2 || true
  exit 1
fi

echo "smoke_test: OK — Component '${ENTITY_NAME}' round-tripped through POST /api/catalog/locations + GET /api/catalog/entities (auth + DB + catalog plugin all live)"
