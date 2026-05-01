"""Public API for rules_backstage."""

load("@rules_kubectl//:defs.bzl", "kubectl_apply", "kubectl_apply_health_check")

# In v0.1's smoke render (`postgresql.enabled: true`), the chart emits
# one Deployment (Backstage) + one StatefulSet (PostgreSQL primary).
# Release name pinned to `backstage` at maintainer-render time.
_BACKSTAGE_DEPLOYS = [
    "backstage",
]
_BACKSTAGE_ROLLOUTS = [
    # Postgres comes from the bitnami chart's StatefulSet template.
    # The Postgres pod must be Ready before Backstage can complete
    # its DB connection on startup; the chart wires Backstage's pod
    # to wait via its own initContainer (`wait-for-db`).
    "sts/backstage-postgresql",
]
_BACKSTAGE_CRD = ""  # No CRDs — Backstage doesn't ship any.

def backstage_install(
        name,
        namespace = "backstage",
        wait_timeout = "600s",
        **kwargs):
    """Apply the pinned Backstage manifest into `namespace` and block
    until the Backstage Deployment AND the chart-bundled PostgreSQL
    StatefulSet are Ready before idling.

    Drops into `itest_service.exe`. Wait timeout 600s — Backstage's
    `backstage/backstage:latest` image is ~500MB and the official
    demo build runs `yarn build` artifacts at startup. PostgreSQL
    pull is ~150MB. Cluster startup time dominates after the pulls.
    """
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply(
        name = name,
        manifests = ["@rules_backstage//private/manifests:backstage.yaml"],
        namespace = namespace,
        create_namespace = True,
        server_side = True,
        wait_for_deployments = list(_BACKSTAGE_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_BACKSTAGE_ROLLOUTS) + list(extra_rollouts),
        wait_timeout = wait_timeout,
        **kwargs
    )

def backstage_health_check(
        name,
        namespace = "backstage",
        **kwargs):
    """Readiness probe paired with `backstage_install`."""
    extra_deploys = kwargs.pop("wait_for_deployments", [])
    extra_rollouts = kwargs.pop("wait_for_rollouts", [])
    kubectl_apply_health_check(
        name = name,
        namespace = namespace,
        wait_for_deployments = list(_BACKSTAGE_DEPLOYS) + list(extra_deploys),
        wait_for_rollouts = list(_BACKSTAGE_ROLLOUTS) + list(extra_rollouts),
        **kwargs
    )
