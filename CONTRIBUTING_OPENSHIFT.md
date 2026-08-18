# Contributing to Custom Metrics Autoscaler (OpenShift Downstream)

This document covers contribution guidelines specific to the OpenShift downstream fork of [KEDA](https://github.com/kedacore/keda). For upstream KEDA contribution guidelines, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Related Resources

| Resource | Link |
|----------|------|
| Upstream repo | [kedacore/keda](https://github.com/kedacore/keda) |
| Operator repo | [openshift/custom-metrics-autoscaler-operator](https://github.com/openshift/custom-metrics-autoscaler-operator) |
| CI configuration | [openshift/release/.../kedacore-keda/](https://github.com/openshift/release/tree/master/ci-operator/config/openshift/kedacore-keda) |
| AI guidance | [AGENTS.md](AGENTS.md) |
| OpenShift docs | [Custom Metrics Autoscaler](https://docs.openshift.com/container-platform/latest/nodes/cma/nodes-cma-autoscaling-custom.html) |

## Review and Approval Policy

Every change in every pull request must be understood and approved by two humans. This can be the PR author and a reviewer, or — if the author used an AI tool and does not fully understand the contents of the PR — two human reviewers.

**Exception:** PRs authored by deterministic automation tools that are part of our CI and related systems (whose code has been reviewed by the OpenShift engineering org) can be merged with a single human review.

Every change should be closely scrutinized for bugs. Our software is complex with many interdependencies. Review changes from multiple angles:

- **Product architecture**: Does this fit the intended design of KEDA and OpenShift?
- **Security**: Are there new attack surfaces, credential handling issues, or privilege escalations?
- **Thread safety**: KEDA uses concurrent scalers and metrics collection — are shared resources properly synchronized?
- **Regressions**: Could this break existing scaler behavior or metrics reporting?
- **Effects on other components**: How does this impact the CMA operator, the metrics API, or HPA behavior?

## Upstream Commit Convention

This is a downstream fork. All non-upstream commits must use one of the following prefixes to ensure changes are not lost during the next upstream rebase:

- `UPSTREAM: <carry>: ` -- A change that should be kept (carried) indefinitely, or as long as it makes sense to do so
- `UPSTREAM: <drop>: ` -- A change that should be discarded during the next rebase cycle
- `UPSTREAM: 1234: ` -- A change carried until the rebase includes upstream PR #1234

Examples:

```
UPSTREAM: <carry>: Add OpenShift-specific e2e test targets
UPSTREAM: <drop>: Pin Go version to 1.25 until 1.26 builder is available
UPSTREAM: 5678: Backport fix for race condition in scaler shutdown
```

Commit prefixes are validated by CI via `hack/cma-verify-history.sh`.

## Upstream-First Policy

New feature work should be directed to the [upstream KEDA project](https://github.com/kedacore/keda). Downstream-only features are discouraged due to the ongoing cost of maintaining them through each rebase cycle. If a downstream-only change is necessary, use the `UPSTREAM: <carry>:` prefix and include a comment in the PR explaining why it cannot go upstream.

## PR Title Convention

PR titles should be prefixed with a Jira ticket reference:

```
AUTOSCALE-123: Fix the whatsit in the thingamajig
OCPBUGS-456: Correct nil pointer in scaler shutdown
NO-JIRA: Update Go module dependencies
```

The Jira prefix goes in the **PR title**. The upstream commit prefix goes in the **commit message**.

## PR Workflow

This repo uses [OpenShift CI (Prow)](https://docs.ci.openshift.org/) for continuous integration. GitHub Actions workflows in this repo are from upstream and are **not used** for our CI. PRs are automatically merged once all required tests pass and the correct labels are present.

### Required labels for merge

- `lgtm` — Added by a reviewer via the `/lgtm` command. Any developer from the OpenShift org can add this after reviewing the PR.
- `approved` — Added by an approver listed in the [OWNERS](OWNERS) file via the `/approve` command.

### Useful commands

Comment these on the PR:

| Command | Effect |
|---------|--------|
| `/lgtm` | Add the `lgtm` label after reviewing. In repos using [LGTM mode](https://docs.ci.openshift.org/how-tos/creating-a-pipeline/#the-pipeline-required-command), this also triggers E2E and other second-stage tests. |
| `/lgtm cancel` | Remove the `lgtm` label |
| `/approve` | Add the `approved` label (OWNERS approvers only) |
| `/pipeline required` | Manually trigger all required second-stage tests (e.g., E2Es) without waiting for `/lgtm` |
| `/retest` | Re-run all failed required tests |
| `/retest-required` | Re-run only the failed required tests |
| `/test <test-name>` | Run a specific test, e.g. `/test keda-e2e-aws-ovn` |
| `/hold` | Prevent the PR from being merged |
| `/hold cancel` | Remove the hold and allow merging |
| `/verified` | Mark the PR as verified |
| `/cherry-pick release-4.18` | Create a cherry-pick PR to a release branch |

### LGTM mode and E2E tests

Repos enrolled in [LGTM mode](https://docs.ci.openshift.org/how-tos/creating-a-pipeline/#the-pipeline-required-command) defer second-stage tests (such as E2Es) until the `/lgtm` label is applied. This avoids wasting CI resources on PRs that haven't been reviewed yet. If you need to run E2Es before getting `/lgtm` (e.g., to validate before requesting review), use `/pipeline required`.

### Preventing premature merges

- Add the `WIP:` prefix to the PR title (e.g., `WIP: AUTOSCALE-123: Work in progress`). Prow adds the `do-not-merge/work-in-progress` label automatically.
- Use `/hold` to temporarily block merging while awaiting additional review or testing.

## Test Expectations

PRs should include tests to verify correctness and prevent future regressions:

- **Unit tests**: Required for new logic, bug fixes, and behavior changes. Run with `make test`.
- **E2E tests**: Expected for new features or significant behavior changes. The OpenShift CI runs a subset of e2e tests (cpu, cron, kafka, kubernetes_workload, memory, prometheus scalers). Run locally with `make e2e-test-openshift`.

## Verified Label

Use `/verified` to indicate changes have been verified. Examples:

```
/verified
/verified by keda-e2e-aws-ovn
/verified by unit tests
/verified by E2Es
/verified deferred to QE
```

## Generated Code

The following files are generated and should never be hand-edited:

| File(s) | Generator | Regenerate with |
|---------|-----------|-----------------|
| `**/zz_generated.deepcopy.go` | controller-gen | `make generate` |
| `config/crd/bases/*.yaml` | controller-gen | `make manifests` |
| `pkg/generated/` (clientsets) | code-generator | `make clientset-generate` |
| `pkg/mock/mock_*/mock_*.go` | mockgen | `make mockgen-gen` |
| `*.pb.go` | protoc | `make proto-gen` |
| `pkg/scalers/liiklus/` | protoc/mock | `make proto-gen mockgen-gen` |

After modifying API types or interfaces, regenerate and commit the results in the same PR.

## Development Quick Reference

| Task | Command |
|------|---------|
| Build all binaries | `make build` |
| Build operator only | `make manager` |
| Build adapter only | `make adapter` |
| Build webhooks only | `make webhooks` |
| Run unit tests | `make test` |
| Run unit tests (race detection) | `make test-race` |
| Run linter | `make golangci` |
| Run go vet | `make vet` |
| Format code | `make fmt` |
| Generate deepcopy/mocks/proto | `make generate` |
| Generate CRD manifests | `make manifests` |
| Verify generated code is up to date | `make verify-manifests` |
| Verify clientsets | `make clientset-verify` |
| OpenShift e2e setup | `make e2e-test-openshift-setup` |
| OpenShift e2e run | `make e2e-test-openshift` |
| OpenShift e2e cleanup | `make e2e-test-openshift-clean` |

## Pre-Submit Checklist

Before requesting review:

1. `make build` — Verify the code compiles
2. `make test` — Run unit tests
3. `make golangci` — Run linters
4. `make verify-manifests && make clientset-verify` — Ensure generated files are up to date
5. Review your diff for secrets, credentials, or debug code
6. Address any [CodeRabbit](https://coderabbit.ai/) review feedback — as a courtesy to the human reviewer who follows. Responding with an explanation of why you're not acting on a suggestion is fine; the goal is to resolve straightforward issues so human reviewers can focus on the substantive aspects.

## Code Style

- Run `make fmt` before committing
- Follow Go conventions for error strings: lowercase, no trailing punctuation, wrap with `fmt.Errorf("context: %w", err)`
- Use structured logging with klog: constant messages, key-value pairs in lowerCamelCase
- Import ordering: stdlib, external packages, internal packages (separated by blank lines)
