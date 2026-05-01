# rules_backstage

Hermetic [Backstage](https://backstage.io/) install for Bazel test
compositions. Pure glue layer over
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl) —
`backstage_install` is a macro emitting a `kubectl_apply` target
pre-configured with Backstage's pinned manifest and the right wait
shape (Backstage Deployment + chart-bundled PostgreSQL StatefulSet).

```python
load("@rules_backstage//:defs.bzl", "backstage_install", "backstage_health_check")

backstage_install(name = "backstage_install_bin")          # default ns: backstage
backstage_health_check(name = "backstage_health_bin")
```

That's the whole API. Backstage is a developer-portal framework — its
catalog plugin tracks software components / APIs / resources, and a
plugin ecosystem layers tech-docs / scaffolder / kubernetes / etc.
on top. This rule set installs Backstage with the chart-bundled
PostgreSQL ready for catalog reads / writes.

**Pinned versions:** Backstage helm chart `2.6.3` (image
`backstage/backstage:latest` — the upstream demo build). The chart
bundles Bitnami's `postgresql` subchart at `15.4.0-debian-11-r10`
(uses the `bitnamilegacy/postgresql` registry — chart already
applies the override). Smoke-fixture render — single Backstage
replica, single Postgres replica, emptyDir storage, Ingress off,
ServiceMonitor off, NetworkPolicy off. The values file is exported
as `@rules_backstage//config:backstage-values.yaml` for inspection
/ extension.

**Supported platforms (v0.1):** any platform where rules_kubectl
runs. Validated on Linux x86\_64 in CI.

> **Image-pin warning.** v0.1's render uses `backstage/backstage:latest`
> because the chart's default tag is also `latest`. Production
> deployments must override `backstage.image.tag` to a specific
> digest / version (and almost certainly to a custom-built image
> with their own plugins, theming, app-config). The demo image is
> for evaluation only — it ships the example catalog the smoke
> asserts against.

---

## Contents

- [Installation](#installation) (Bzlmod-only)
- [Quickstart](#quickstart)
- [Configuring Backstage](#configuring-backstage)
- [Macros](#macros)
- [Hermeticity exceptions](#hermeticity-exceptions)
- [Contributing](#contributing)

---

## Installation

```python
bazel_dep(name = "rules_backstage", version = "0.1.0")
```

Bzlmod-only. Transitively pulls in
[`rules_kubectl`](https://github.com/collider-bazel-extensions/rules_kubectl).

---

## Quickstart

```python
load("@rules_backstage//:defs.bzl", "backstage_install", "backstage_health_check")
load("@rules_itest//:itest.bzl", "itest_service", "service_test")
load("@rules_kind//:defs.bzl", "kind_cluster", "kind_health_check")
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

# 1. Cluster.
kind_cluster(name = "cluster", k8s_version = "1.32")
kind_health_check(name = "cluster_health", cluster = ":cluster")
itest_service(name = "kind_svc", exe = ":cluster", health_check = ":cluster_health")

# 2. Backstage.
backstage_install(name = "backstage_install_bin")
backstage_health_check(name = "backstage_health_bin")
sh_binary(name = "backstage_install_wrapper", srcs = ["install_wrapper.sh"], data = [":backstage_install_bin"])
sh_binary(name = "backstage_health_wrapper",  srcs = ["health_wrapper.sh"],  data = [":backstage_health_bin"])

itest_service(
    name = "backstage_svc",
    exe = ":backstage_install_wrapper",
    deps = [":kind_svc"],
    health_check = ":backstage_health_wrapper",
)

# 3. Your test workload — see `examples/` for shapes.
```

---

## Configuring Backstage

Once Backstage is up, the in-cluster Service
`backstage.<namespace>.svc.cluster.local:7007` accepts HTTP requests:

| Path | Use |
|---|---|
| `GET /api/catalog/entities` | Read the catalog (Components, APIs, Users, etc.) |
| `POST /api/catalog/locations` | Register a new catalog location for ingestion |
| `GET /api/scaffolder/v2/templates` | Software templates for the scaffolder plugin |
| `GET /.backstage/health/v1/readiness` | Liveness / readiness probes |

The smoke render uses the upstream demo image (`backstage/backstage:latest`)
which carries the example catalog locations baked into its
`app-config.yaml`. Real consumers will:

1. Build their own Backstage image (`yarn create-app` + plugins).
2. Override `backstage.image.repository` + `backstage.image.tag`.
3. Supply their own `backstage.appConfig` ConfigMap (catalog locations,
   auth providers, plugin config).

See [`examples/`](examples/) for sketches of these.

---

## Macros

### `backstage_install`

```python
backstage_install(
    name = "backstage_install_bin",
    namespace = "backstage",    # default
    wait_timeout = "600s",      # default
)
```

Expands to a `kubectl_apply(...)` target that:

- Applies `@rules_backstage//private/manifests:backstage.yaml`.
- `create_namespace = True` (default `backstage`).
- `server_side = True`.
- `wait_for_deployments = ["backstage"]`.
- `wait_for_rollouts = ["sts/backstage-postgresql"]` — chart-bundled
  Postgres subchart's StatefulSet.
- `wait_timeout = "600s"` — Backstage demo image is ~500MB and
  Postgres is ~150MB; cluster startup time dominates after the pulls.

Drops into `itest_service.exe`.

### `backstage_health_check`

```python
backstage_health_check(name = "backstage_health_bin", namespace = "backstage")
```

Drops into `itest_service.health_check`. Same wait shape with
`--timeout=0s`.

---

## Hermeticity exceptions

| Component | Status | Notes |
|---|---|---|
| Backstage manifest | Fully hermetic. URL + sha256 pinned in `tools/versions.bzl`; pre-rendered + committed. | Re-render via `bash tools/render_backstage.sh <ver>`. |
| `kubectl` | Inherited from `rules_kubectl`. | |
| Target cluster | Out of scope. | |
| Backstage container image | Pulled at runtime. `docker.io/backstage/backstage:latest` (overridable). | Future: pre-load via `kind_cluster.images`. |
| PostgreSQL container image | Pulled at runtime. `docker.io/bitnamilegacy/postgresql:15.4.0-debian-11-r10`. | Chart's image override already applied. |

---

## Contributing

PRs welcome. Conventions match the sibling rule sets:

- New rules need an analysis test in `tests/analysis_tests.bzl`.
- Bumping the pinned chart version: edit `tools/versions.bzl`, add a
  `helm_template + sh_binary` block in `tools/BUILD.bazel`, run
  `bash tools/render_backstage.sh <new-version>`, commit.
- `MODULE.bazel.lock` is intentionally not committed.

### Help wanted

- macOS validation
- Pin an explicit Backstage image tag (the chart defaults to `latest`)
- Compose with [`rules_cloudnativepg`](https://github.com/collider-bazel-extensions/rules_cloudnativepg)
  for the production-style "Postgres-via-CNPG" path (drop the
  chart-bundled Postgres subchart, point Backstage at a CNPG-managed
  Cluster)
- Catalog round-trip smoke (POST a Location, assert the entity it
  references is ingested) — currently the smoke only exercises the
  read path with the bootstrapped example catalog
- TechDocs plugin smoke (Backstage's static-site generation for
  Markdown docs)
- Scaffolder plugin smoke (template-based component creation)
- OpenID Connect / GitHub OAuth integration smoke
- Custom Backstage image with plugins (the v0.1 render uses the
  upstream demo image; production users always build their own)
