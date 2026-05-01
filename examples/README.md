# Examples

Reference shapes for configuring Backstage. v0.1's smoke uses the
upstream `backstage/backstage:latest` demo image (which carries
example entities); production deployments build their own image
and override `backstage.appConfig`.

| File | Use case | Exercised by smoke? |
|---|---|---|
| [`catalog_info.yaml`](catalog_info.yaml) | Backstage entity YAML — what gets POSTed at a `Location` URL or referenced from `catalog.locations`. | No (the demo image's bundled examples are what the smoke reads) |
| [`app_config_override.yaml`](app_config_override.yaml) | A `backstage.appConfig` override that registers a custom catalog location + tweaks plugin config. The way real consumers customize Backstage without re-building the image. | No (sketch) |
| [`cnpg_compose.md`](cnpg_compose.md) | How a future `rules_backstage` × `rules_cloudnativepg` composed smoke would look — Backstage points at a CNPG-managed Postgres Cluster instead of the chart-bundled subchart. | No (doc) |

## Things this directory deliberately does NOT show

- **A full Backstage app build.** Backstage app code lives in your
  own repo (`yarn create-app`); this rule set is about the
  Kubernetes deployment, not the app build.
- **Plugin development.** Backstage plugins ship as npm packages;
  building them is the consumer's concern.
- **OAuth / OIDC integration.** Each provider (Google, GitHub,
  Okta, Keycloak) has its own credentials flow; out-of-cluster
  credentials don't belong in a hermetic example.
- **TechDocs storage backends.** S3 / GCS / local filesystem;
  consumer-specific.
- **Production database migrations.** Backstage's catalog schema
  evolves; production upgrades need migration testing the smoke
  doesn't model.
