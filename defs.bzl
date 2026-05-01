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
        wait_timeout = "900s",
        **kwargs):
    """Apply the pinned Backstage manifest into `namespace` and block
    until the Backstage Deployment AND the chart-bundled PostgreSQL
    StatefulSet are Ready before idling.

    Drops into `itest_service.exe`. Wait timeout **900s** (15 min) —
    Backstage's `backstage/backstage:latest` image is ~500MB; with
    the v0.2 `appConfig` override (static-token auth) the backend
    startup runs config validation + DB migrations + plugin loading
    serially. PostgreSQL image pull is ~150MB on top. Total cold-pull
    + init can hit 8-10 minutes on a fresh CI runner; v0.1 used 600s
    and timed out twice while attempting auth overrides — the
    diagnostic-less timeout led us to wrongly conclude the overrides
    were broken when the actual root cause was likely "needs more
    time."
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
