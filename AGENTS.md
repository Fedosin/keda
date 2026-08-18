# AGENTS.md — openshift/kedacore-keda

This file provides AI-specific guidance for working in the OpenShift downstream fork of [KEDA](https://keda.sh) (Kubernetes Event-driven Autoscaling). For contribution guidelines, see [CONTRIBUTING_OPENSHIFT.md](CONTRIBUTING_OPENSHIFT.md).

## Project Overview

This repo is for **Custom Metrics Autoscaler (CMA)** for OpenShift — a downstream fork of [kedacore/keda](https://github.com/kedacore/keda). KEDA allows fine-grained autoscaling of Kubernetes workloads based on external event sources (Kafka topics, Prometheus queries, cloud provider queues, cron schedules, and ~60 other sources), including scaling to and from zero.

The CMA is deployed and managed by the [custom-metrics-autoscaler-operator](https://github.com/openshift/custom-metrics-autoscaler-operator).

### Three Binaries

This repo produces three separate binaries, each running as its own container:

| Binary | Source | Purpose |
|--------|--------|---------|
| `keda` | `cmd/operator/main.go` | The controller manager. Watches ScaledObject/ScaledJob CRs and manages HPA objects and scaling decisions. |
| `keda-adapter` | `cmd/adapter/main.go` | A Kubernetes metrics API server. Exposes custom/external metrics from scalers so HPAs can consume them. |
| `keda-admission-webhooks` | `cmd/webhooks/main.go` | Admission webhooks for validating and defaulting KEDA CRDs. |

### CRDs

| CRD | API Group | Purpose |
|-----|-----------|---------|
| ScaledObject | `keda.sh/v1alpha1` | Defines autoscaling rules for a Deployment/StatefulSet based on event triggers |
| ScaledJob | `keda.sh/v1alpha1` | Defines autoscaling rules for Jobs based on event triggers |
| TriggerAuthentication | `keda.sh/v1alpha1` | Namespaced authentication config for scaler triggers |
| ClusterTriggerAuthentication | `keda.sh/v1alpha1` | Cluster-scoped authentication config for scaler triggers |
| CloudEventSource | `eventing.keda.sh/v1alpha1` | Configures CloudEvent emission for scaling events |
| ClusterCloudEventSource | `eventing.keda.sh/v1alpha1` | Cluster-scoped CloudEvent source configuration |

## Repository Structure

```
cmd/
  operator/          # Main controller manager binary
  adapter/           # Metrics API server binary
  webhooks/          # Admission webhook binary
apis/
  keda/v1alpha1/     # ScaledObject, ScaledJob, TriggerAuth CRD types + webhooks
  eventing/v1alpha1/ # CloudEventSource CRD types
controllers/
  keda/              # ScaledObject and ScaledJob controllers
  eventing/          # CloudEventSource controller
pkg/
  scalers/           # ~60 scaler implementations (one file per scaler + tests)
  scaling/           # Core scaling logic, scaler lifecycle management
    scalers_builder.go  # Registry: maps trigger type string -> scaler constructor
  provider/          # Kubernetes metrics API provider (serves custom metrics)
  certificates/      # TLS certificate management
  fallback/          # Fallback metrics when scalers fail
  generated/         # Generated client-go clientsets
  mock/              # Generated mocks for testing
  k8s/               # Kubernetes utility helpers
  metricsservice/    # gRPC metrics service
  status/            # Status update helpers
config/
  crd/bases/         # Generated CRD manifests (do not hand-edit)
  rbac/              # Generated RBAC manifests
  manager/           # Kustomize overlay for operator deployment
  metrics-server/    # Kustomize overlay for metrics adapter
  webhooks/          # Kustomize overlay for admission webhooks
  samples/           # Example CR manifests
tests/
  scalers/           # E2E tests organized by scaler type
  internals/         # E2E tests for internal behavior (fallback, caching, scaling strategies)
  sequential/        # E2E tests that cannot run in parallel
  helper/            # Shared test utilities
hack/
  cma-verify-history.sh   # CI check: validates upstream commit prefix convention
  update-codegen.sh       # Regenerate client-go clientsets
  verify-codegen.sh       # Verify clientsets are up to date
  verify-manifests.sh     # Verify CRD/RBAC manifests are up to date
```

## Upstream / Downstream Relationship

This repo tracks upstream `kedacore/keda` on the `main` branch. Currently CMA is single-stream so the release branches are not used. All fixes and releases are made using the main branch downstream. Upstream release branches are sometimes used when doing the upstream rebase depending upon the timing of the rebase.

### What is downstream-only

These files exist only in the downstream fork:

- `OWNERS` — OpenShift approver list
- `.ci-operator.yaml` — OpenShift CI build root config
- `Dockerfile.tests` — E2E test image for OpenShift CI
- `openshift-e2e.yaml` — OpenShift-specific e2e test configuration
- `hack/cma-verify-history.sh` — Commit prefix validation
- `CONTRIBUTING_OPENSHIFT.md` — This downstream contributing guide
- `AGENTS.md` — This file
- `.coderabbit.yaml` — CodeRabbit configuration

### What is upstream

Everything else. In particular: the core scaler implementations in `pkg/scalers/`, the controllers in `controllers/`, the API types in `apis/`, the Makefiles, the upstream Dockerfiles, and the `.github/` workflows (which are not used in our CI but are kept for upstream compatibility). Avoid modifying the upstream files in this repository since patches will need to be re-applied during every rebase cycle. Instead, try to find a way to contribute features and fixes upstream where we can help to cleanly maintain the code without worrying about merges and conflicts.

### Rebase Cycle

Periodically, the `main` branch is rebased onto a newer upstream release. During a rebase:
- `UPSTREAM: <drop>:` commits are discarded
- `UPSTREAM: <carry>:` commits are re-applied
- `UPSTREAM: 1234:` commits are dropped if upstream PR 1234 is now included, otherwise re-applied

## Architecture: What Is Not Obvious

### Scaling Flow

1. User creates a **ScaledObject** referencing a Deployment and one or more triggers
2. The **ScaledObject controller** (`controllers/keda/scaledobject_controller.go`) creates an HPA targeting the Deployment and registers the scaling configuration
3. The **scaling handler** (`pkg/scaling/`) periodically polls each trigger's scaler for current metric values and activity status
4. The **metrics adapter** (`pkg/provider/`) serves these metrics via the Kubernetes custom/external metrics API
5. The HPA reads metrics from the adapter and scales the Deployment accordingly
6. For scale-to-zero: KEDA manages this directly (HPA min replicas is 0 only through KEDA's intervention), activating the workload when the scaler reports activity

### Scaler Registration

New scalers are registered in `pkg/scaling/scalers_builder.go` via a large switch statement that maps trigger type strings (e.g., `"kafka"`, `"prometheus"`) to scaler constructor functions. Every scaler implements the `Scaler` interface defined in `pkg/scalers/scaler.go`.

### Three Processes, One Repo

The operator, adapter, and webhooks are separate binaries sharing the same codebase. They share API types and utility packages but have distinct entry points and runtime behavior. Changes to shared packages can affect all three.

## Common Pitfalls

1. **Add a carry prefix to every commit.** Every non-upstream commit must use `UPSTREAM: <carry>:`, `UPSTREAM: <drop>:`, or `UPSTREAM: 1234:`. CI enforces this via `hack/cma-verify-history.sh`. Only commits merged from upstream don't require the prefix.

2. **Do not hand-edit generated files.** Files matching `zz_generated*`, CRD manifests in `config/crd/bases/`, clientsets in `pkg/generated/`, and mocks in `pkg/mock/` are all generated. Run `make generate && make manifests` instead.

3. **Do not add new scalers downstream.** New scaler implementations should go upstream to `kedacore/keda`. Carrying a scaler downstream means maintaining it through every rebase cycle.

4. **Do not use GitHub Actions.** The `.github/workflows/` directory is from upstream and is not used in our CI. Our CI runs through OpenShift CI (Prow). The CI config is in [openshift/release](https://github.com/openshift/release/tree/master/ci-operator/config/openshift/kedacore-keda).

5. **Do not modify vendor/ directly.** Run `go mod tidy && go mod vendor` and commit vendor changes in a separate commit from logic changes.

6. **Watch for scaler concurrency issues.** Scalers run concurrently. The `Close()` method must be safe to call from any goroutine. Resource cleanup in `Close()` must not race with `GetMetricsAndActivity()`.

7. **Remember the three-binary impact.** A change to a shared package (e.g., `pkg/scaling/`, `apis/`) can affect the operator, adapter, and webhooks. Test accordingly.

8. **OpenShift e2e runs only a subset.** The CI runs tests for: cpu, cron, kafka, kubernetes_workload, memory, prometheus scalers. Most cloud-provider-specific scalers (AWS, Azure, GCP) are not tested in our CI. See `openshift-e2e.yaml` for the exact test matrix.

## Human-in-the-Loop Triggers

Stop and consult a human before:

- **Modifying CRD API types** (`apis/`) — API changes have compatibility implications and may require coordinated changes in the operator repo
- **Changing RBAC permissions** (`config/rbac/`) — Privilege changes require security review
- **Adding or removing scalers** — Scaler changes affect the product surface area
- **Modifying the upstream/downstream boundary** — Any change to which files are carried vs. upstream
- **Rebase-related decisions** — Whether a carry patch is still needed, whether to drop or keep
- **Changing Dockerfiles** — Build changes can affect the product payload

## Paired Changes

These files must be updated together:

| If you change... | Also update... |
|-----------------|----------------|
| API types in `apis/keda/v1alpha1/` | Run `make generate && make manifests` to regenerate deepcopy and CRDs |
| API types with webhooks | Update corresponding `*_webhook.go` and webhook tests |
| Scaler interface or behavior | Update mocks with `make mockgen-gen` |
| Protobuf definitions | Run `make proto-gen` |
| `go.mod` dependencies | Run `go mod vendor` and commit vendor changes separately |
| OpenShift e2e test list | Update `openshift-e2e.yaml` |

## Further Reading

- [CONTRIBUTING_OPENSHIFT.md](CONTRIBUTING_OPENSHIFT.md) — Downstream contribution workflow, PR commands, test expectations
- [CONTRIBUTING.md](CONTRIBUTING.md) — Upstream KEDA contribution guidelines
- [CREATE-NEW-SCALER.md](CREATE-NEW-SCALER.md) — How to add a new scaler (upstream)
- [BUILD.md](BUILD.md) — Upstream build instructions
- [TESTING.md](TESTING.md) — Upstream testing guide
