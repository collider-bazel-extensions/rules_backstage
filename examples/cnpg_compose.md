# Composing rules_backstage with rules_cloudnativepg

v0.1's smoke uses the chart-bundled Bitnami `postgresql` subchart for
zero-touch setup. Production deployments often pivot to a
CNPG-managed Postgres for HA, point-in-time recovery, and managed
upgrades. Sketch — not exercised by v0.1's smoke; v0.2 candidate.

## High-level shape

```
[ rules_kind cluster ]
       │
       ├── [ rules_cloudnativepg ]    operator + Cluster CR backstage-pg (3 instances)
       │       │
       │       └── Service: backstage-pg-rw.backstage.svc:5432
       │           Secret:  backstage-pg-app    (username/password)
       │
       └── [ rules_backstage ]
              │
              └── Override: postgresql.enabled = false
                  appConfig.backend.database.client      = pg
                  appConfig.backend.database.connection.host     = backstage-pg-rw.backstage.svc.cluster.local
                  appConfig.backend.database.connection.port     = 5432
                  appConfig.backend.database.connection.user     = (from Secret)
                  appConfig.backend.database.connection.password = (from Secret)
                  appConfig.backend.database.connection.database = app
```

## Bazel composition

```python
# In your tests/BUILD.bazel:
load("@rules_cloudnativepg//:defs.bzl", "cloudnativepg_install", ...)
load("@rules_backstage//:defs.bzl", "backstage_install", ...)
load("@rules_kubectl//:defs.bzl", "kubectl_apply")

# 1) Operator.
cloudnativepg_install(name = "cnpg_install_bin")
itest_service(name = "cnpg_svc", exe = ":cnpg_install_wrapper", deps = [":kind_svc"], ...)

# 2) Postgres Cluster CR. Custom YAML referencing CNPG's API.
kubectl_apply(
    name = "backstage_pg_cluster",
    manifests = ["backstage-pg-cluster.yaml"],
    namespace = "backstage",
)
itest_service(name = "backstage_pg_svc", exe = ":backstage_pg_wrapper", deps = [":cnpg_svc"], ...)

# 3) Backstage with chart-bundled Postgres OFF + custom appConfig
#    pointing at the CNPG Cluster's read-write Service.
backstage_install(
    name = "backstage_install_bin",
    namespace = "backstage",
)
itest_service(name = "backstage_svc", exe = ":backstage_install_wrapper",
              deps = [":backstage_pg_svc"], ...)
```

## Postgres Cluster CR

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: backstage-pg
  namespace: backstage
spec:
  instances: 3
  postgresql:
    parameters:
      max_connections: "100"
  bootstrap:
    initdb:
      database: app
      owner: backstage
      secret: {name: backstage-pg-credentials}
  storage:
    size: 1Gi
```

## rules_backstage values overlay

```yaml
postgresql:
  enabled: false  # Chart-bundled subchart OFF.

backstage:
  appConfig:
    backend:
      database:
        client: pg
        connection:
          host: backstage-pg-rw.backstage.svc.cluster.local
          port: 5432
          # CNPG creates a Secret with username + password —
          # extraEnvVarsSecrets wires them into the pod env.
          user: ${POSTGRES_USER}
          password: ${POSTGRES_PASSWORD}
          database: app
  extraEnvVarsSecrets:
    - backstage-pg-app   # CNPG-issued credentials Secret
```

## What this gets you

- Production-shaped Postgres: 3-instance HA, automated failover,
  WAL archiving (with appropriate `Cluster.spec.backup`).
- Cluster.spec.certificates can wire mTLS between Backstage and
  Postgres (modeled on rules_cloudnativepg's existing
  cert-manager-issued-certs smoke).
- Lossless upgrades — bumping the Backstage image doesn't touch
  the database; bumping Postgres goes through CNPG's
  `inPlacePodVerticalScaling` / managed restart sequence.

What it costs:
- An extra rule-set dep + a couple of extra Bazel targets in
  consumer's tests/BUILD.bazel.
- Slightly slower smoke (CNPG operator + Cluster takes a couple
  more minutes to come up vs. the bundled subchart's one
  StatefulSet).
