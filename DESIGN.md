# rules_backstage — design decisions

Hermetic [Backstage](https://backstage.io/) install for Bazel test
compositions. Pure glue over `rules_kubectl` + `rules_helm` — same
shape as `rules_loki` / `rules_grafana` / `rules_harbor` /
`rules_external_secrets` / `rules_kafka` / `rules_tempo` /
`rules_mimir` / `rules_otel`.

## Decided

| # | Decision | Choice | Source |
|---|---|---|---|
| 1 | Bzlmod / WORKSPACE | **Bzlmod-only at v0.1.** | Sibling-family |
| 2 | Module / repo name | `rules_backstage`. | Convention |
| 3 | Architecture | **Layered.** Two macros wrapping `kubectl_apply` / `kubectl_apply_health_check`. | rules_loki precedent |
| 4 | Manifest provisioning | Backstage helm chart **pre-rendered** into `private/manifests/backstage.yaml` via `rules_helm`. Committed. The chart bundles its `postgresql` subchart at `charts/postgresql/` inside the tarball, so `rctx.download_and_extract` of the GitHub release tgz pulls everything we need. | rules_loki pattern |
| 5 | Database | **Chart-bundled PostgreSQL** (`postgresql.enabled: true`). The chart's bitnami `postgresql` subchart is the smallest delta to "Backstage running with a real DB" — no cross-rule dep on `rules_cloudnativepg`. v0.2 candidate: pivot to `rules_cloudnativepg`-managed Postgres for the production-style path. | Smoke pragmatic |
| 6 | Single-version | One pinned chart (`2.6.3`). Multi-version is the rules_cloudnativepg pattern; add it if a real consumer wants two versions side-by-side. | Pragmatic |
| 7 | Render mode | **Smoke fixture.** Single replica each (Backstage + Postgres), persistence off (emptyDir for Postgres), Ingress off, ServiceMonitor off, NetworkPolicy off. README warns the values are not a production starting point. | Smoke pragmatic |
| 8 | Public surface | `backstage_install`, `backstage_health_check`. **No `backstage_catalog_location` / `backstage_app_config` rule** — Backstage's app-config is a deeply structured YAML; v0.1 documents the YAML pattern + ships `examples/`. | Smaller surface |
| 9 | Namespace | `backstage` (default, idempotent create). | Convention |
| 10 | Wait shape | One Deployment (`backstage`) + one StatefulSet (`backstage-postgresql`). Backstage's chart waits internally on Postgres via an init-container (`wait-for-db`), so the order in our wait list is decorative — we wait for both regardless. No CRDs. | Backstage-specific |
| 11 | Image | **`backstage/backstage:latest`** — the upstream demo image. Tagged `latest` because the chart's default is also `latest`; production consumers override `backstage.image.{repository,tag}` to their own custom-built image. The demo image is what carries the example catalog the smoke asserts against. | Smoke pragmatic |
| 12 | Smoke client | **`kubectl run` a curl pod.** GET against Backstage's catalog API from inside the cluster — same approach as rules_grafana / rules_tempo / rules_otel. | Pragmatic |
| 13 | Smoke assertion | Poll `GET /api/catalog/entities` until the response is HTTP 200 and the body is a non-empty JSON array (starts with `[{`). The Backstage demo image's bundled `app-config.yaml` registers example catalog locations; once the backend starts, the catalog plugin's processing loop reads them + writes entities to Postgres. Initial population is async — first-pass typically completes within 30-60s of the pod going Ready. Proves: Backstage backend + Postgres connection + catalog plugin's read API + JSON-over-HTTP serialization end-to-end. | Per the family's "exercise the functionality" rule |
| 14 | Cross-rule deps | `rules_kubectl` public dep. `rules_helm` + `rules_kind` + `rules_itest` + `rules_shell` dev-only. No cert-manager required. | rules_loki precedent |
| 15 | Naming | snake_case rules/macros, `MixedCaseInfo` providers (none in v0.1), `UPPER_SNAKE` constants. | All siblings |
| 16 | Update workflow | `bash tools/render_backstage.sh <chart-version>` → thin shim. | rules_loki precedent |

## Why the chart-bundled Postgres, not rules_cloudnativepg

Two reasonable paths:

- **Chart-bundled Postgres** (v0.1's choice). The Backstage chart's
  `postgresql.enabled: true` toggle stands up a Bitnami Postgres
  StatefulSet alongside Backstage. One `kubectl_apply`, no cross-rule
  composition.
- **`rules_cloudnativepg`-managed Postgres**. CNPG operator + a
  `Cluster` CR; Backstage's `postgresql.enabled: false` + manual
  `appConfig.backend.database.connection` pointing at the CNPG-issued
  Service + Secret. Production-shaped (CNPG handles failover, PITR,
  backups), but adds a cross-rule dep + more moving parts.

v0.1 picks the bundled subchart because:
1. Self-contained — no cross-rule dependency.
2. Backstage chart's auth / connection config wires into the bundled
   subchart automatically. Pivoting to external Postgres requires
   manual `appConfig` plumbing that obscures the smoke.
3. The chart's `postgresql.image.repository: bitnamilegacy/postgresql`
   override is already applied (chart maintainers caught the Bitnami
   registry move — saves us the rules_kafka-style override).

A future `rules_backstage` × `rules_cloudnativepg` composed smoke
would prove the production-style path.

## Image tag = `latest` is a v0.1 sin

The v0.1 render uses `backstage/backstage:latest`. This is a
documented tradeoff:

- The demo image carries the example catalog the smoke asserts
  against. Pinning a specific tag means re-rendering on every
  upstream release if we want to track current Backstage features.
- `latest` is mutable — tomorrow's `latest` may not include the
  same demo catalog.
- Production deployments NEVER use the upstream image. They build
  their own with their plugins / theming / app-config.

For v0.1's smoke fixture, "demo image at `latest`" is acceptable
because consumers are expected to override anyway. A future v0.2
could pin to a specific Backstage release + re-render seasonally.

## What v0.1 doesn't smoke

- **Catalog ingestion (write path).** The smoke only reads. POSTing
  a `Location` and asserting the entity it references gets ingested
  is the v0.2 round-trip.
- **Auth.** The chart's default auth is "guest" (no real auth).
  Production deployments wire OAuth / OIDC / SAML; smoke doesn't.
- **Scaffolder plugin.** Software-template-based component creation —
  Backstage's other major value-add. Needs Git fixtures (or a fake
  `gitea` / `gogs`) to be testable.
- **TechDocs plugin.** Static-site generation for Markdown. Needs
  `mkdocs` + an object-storage fixture.
- **Custom plugins / branding.** Always built into the consumer's
  custom Backstage image; rule set is agnostic.

## v0.1.0 status

| Area | State |
|---|---|
| MODULE.bazel (Bzlmod-only) | done |
| `backstage_install` + `backstage_health_check` macros | done |
| Pinned Backstage chart 2.6.3 (rendered + committed) | done |
| `config/backstage-values.yaml` (exported) | done |
| Maintainer render flow (`bash tools/render_backstage.sh <ver>`) | done |
| Analysis test | done |
| Smoke (kind + Backstage + Postgres + catalog-API GET) | done |
| `examples/` (catalog-info entity, custom appConfig sketch, CNPG compose) | done |

## Deferred (not v0.1.0)

- **Catalog round-trip** — POST a Location, assert ingested. v0.2.
- **`rules_cloudnativepg` compose** — production-style Postgres.
- **Scaffolder smoke** — needs a Git fixture (`gitea` / `gogs`).
- **TechDocs smoke** — needs object storage + mkdocs.
- **OAuth / OIDC smoke** — needs an identity-provider fixture
  (`dex`, `keycloak`).
- **Custom Backstage image** — consumers build their own; rule
  set documents the override pattern but doesn't ship one.
- **Pinned Backstage image tag** — v0.1's `latest` is a known sin.
- **Multi-version chart support** — single pin in v0.1.
