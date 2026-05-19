#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# KEDA memory load test
#
# Creates a kind cluster, deploys KEDA, installs KWOK, then creates fake
# resources in increasing steps and measures keda-operator memory at each
# step.  Produces a markdown report at the end.
#
# Env vars (all optional — sensible defaults provided):
#
#   RESOURCE_COUNTS         Space-separated resource counts (default: "100 500 1000 2000 3000")
#   RESOURCE_TEMPLATE_PATH  Path to a YAML template (default: resources/pod-template.yaml)
#   SAMPLE_DURATION         Seconds to wait after resource creation before sampling (default: 60)
#   SETTLE_DURATION         Seconds to wait for GC to settle before the next step (default: 30)
#   KWOK_VERSION            KWOK release tag (default: v0.7.0)
#   KIND_CLUSTER_NAME       Name of the kind cluster (default: keda-load-test)
#   KEDA_NAMESPACE          Namespace where KEDA is deployed (default: keda)
#   SKIP_CLUSTER_CREATE     Set "true" to reuse an existing cluster (default: false)
#   SKIP_KEDA_DEPLOY        Set "true" to reuse an already-deployed KEDA (default: false)
#   SKIP_KWOK_SETUP         Set "true" if KWOK is already installed (default: false)
#   CLEANUP                 Set "false" to keep the cluster after the test (default: true)
#   KEDA_IMAGE_TAG          Tag for locally built KEDA images (default: load-test)
#   REPORT_PATH             Save report to this file (default: load-test-report.md)
#   CONTAINER_TOOL          Container runtime: "podman" or "docker" (default: auto-detect)
#   ENABLE_PPROF            Enable pprof on keda-operator (default: false)
# ---------------------------------------------------------------------------

log()  { echo "[$(date +%T)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
bold() { echo -e "\033[1m$*\033[0m"; }

# ── Configuration ──────────────────────────────────────────────────────────

RESOURCE_COUNTS="${RESOURCE_COUNTS:-100 1000}"
SAMPLE_DURATION="${SAMPLE_DURATION:-60}"
SETTLE_DURATION="${SETTLE_DURATION:-30}"
KWOK_VERSION="${KWOK_VERSION:-v0.7.0}"
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-keda-load-test}"
KEDA_NAMESPACE="${KEDA_NAMESPACE:-keda}"
SKIP_CLUSTER_CREATE="${SKIP_CLUSTER_CREATE:-false}"
SKIP_KEDA_DEPLOY="${SKIP_KEDA_DEPLOY:-false}"
SKIP_KWOK_SETUP="${SKIP_KWOK_SETUP:-false}"
CLEANUP="${CLEANUP:-true}"
KEDA_IMAGE_TAG="${KEDA_IMAGE_TAG:-load-test}"
REPORT_PATH="${REPORT_PATH:-load-test-report.md}"
ENABLE_PPROF="${ENABLE_PPROF:-false}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Auto-detect container runtime
if [[ -z "${CONTAINER_TOOL:-}" ]]; then
    if command -v podman &>/dev/null; then
        CONTAINER_TOOL="podman"
    elif command -v docker &>/dev/null; then
        CONTAINER_TOOL="docker"
    else
        die "No container runtime found (podman or docker)"
    fi
fi
export KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_TOOL}"

# Podman on Linux requires rootful mode for kind (device-mount issues in
# rootless mode).  Wrap kind and container commands with sudo when needed.
SUDO=""
if [[ "${CONTAINER_TOOL}" == "podman" && "$(uname)" == "Linux" ]]; then
    SUDO="sudo"
fi
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${SCRIPT_DIR}/.kubeconfig}"
RESOURCE_TEMPLATE_PATH="${RESOURCE_TEMPLATE_PATH:-${SCRIPT_DIR}/resources/pod-template.yaml}"

KWOK_NAMESPACE="kwok-system"
TEST_NAMESPACE_PREFIX="load-test"
export KWOK_NODE_NAME="kwok-node-0"

# These must match the "app" label on the KEDA pods.
KEDA_PODS=("keda-operator" "keda-metrics-apiserver" "keda-admission-webhooks")

# Result accumulators
RESULT_STEPS=()           # ("baseline" "100" "500" ...)
declare -A RESULT_MEM     # RESULT_MEM["step:pod"] = "123" (MiB) or "FAILING"

# ── Prerequisites ──────────────────────────────────────────────────────────

check_prerequisites() {
    local missing=()
    for cmd in kubectl kind "${CONTAINER_TOOL}" envsubst; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done
    if (( ${#missing[@]} > 0 )); then
        die "Missing required tools: ${missing[*]}"
    fi
    [[ -f "${RESOURCE_TEMPLATE_PATH}" ]] || die "Resource template not found: ${RESOURCE_TEMPLATE_PATH}"
    log "Using container runtime: ${CONTAINER_TOOL}"
}

# ── Kind cluster ───────────────────────────────────────────────────────────

create_kind_cluster() {
    if [[ "${SKIP_CLUSTER_CREATE}" == "true" ]]; then
        log "Skipping cluster creation (SKIP_CLUSTER_CREATE=true)"
        if [[ -f "${KUBECONFIG_PATH}" && -z "${KUBECONFIG:-}" ]]; then
            export KUBECONFIG="${KUBECONFIG_PATH}"
        fi
        return
    fi

    if ${SUDO} kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
        log "Kind cluster '${KIND_CLUSTER_NAME}' already exists, deleting..."
        ${SUDO} kind delete cluster --name "${KIND_CLUSTER_NAME}"
    fi

    log "Creating kind cluster '${KIND_CLUSTER_NAME}'..."
    ${SUDO} kind create cluster --name "${KIND_CLUSTER_NAME}" --wait 120s

    # Export kubeconfig so non-root kubectl can access the cluster.
    ${SUDO} kind get kubeconfig --name "${KIND_CLUSTER_NAME}" > "${KUBECONFIG_PATH}"
    chmod 600 "${KUBECONFIG_PATH}"
    export KUBECONFIG="${KUBECONFIG_PATH}"
    log "Kubeconfig written to ${KUBECONFIG_PATH}"

    log "Waiting for metrics-server or installing it..."
    if ! kubectl get deployment metrics-server -n kube-system &>/dev/null; then
        log "Installing metrics-server..."
        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
        kubectl patch deployment metrics-server -n kube-system \
            --type='json' \
            -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
        log "Waiting for metrics-server to be ready..."
        kubectl rollout status deployment/metrics-server -n kube-system --timeout=180s
    fi
}

delete_kind_cluster() {
    if [[ "${CLEANUP}" == "true" && "${SKIP_CLUSTER_CREATE}" != "true" ]]; then
        log "Deleting kind cluster '${KIND_CLUSTER_NAME}'..."
        ${SUDO} kind delete cluster --name "${KIND_CLUSTER_NAME}" 2>/dev/null || true
        rm -f "${KUBECONFIG_PATH}"
    else
        log "Keeping cluster (CLEANUP=${CLEANUP})"
        [[ -f "${KUBECONFIG_PATH}" ]] && log "  kubeconfig: export KUBECONFIG=${KUBECONFIG_PATH}"
    fi
}

# ── Build & deploy KEDA ───────────────────────────────────────────────────

deploy_keda() {
    if [[ "${SKIP_KEDA_DEPLOY}" == "true" ]]; then
        log "Skipping KEDA deploy (SKIP_KEDA_DEPLOY=true)"
        return
    fi

    # Podman stores locally-built images under "localhost/" prefix.
    local img_prefix="docker.io"
    if [[ "${CONTAINER_TOOL}" == "podman" ]]; then
        img_prefix="localhost"
    fi
    local img_controller="${img_prefix}/kedacore/keda:${KEDA_IMAGE_TAG}"
    local img_adapter="${img_prefix}/kedacore/keda-metrics-apiserver:${KEDA_IMAGE_TAG}"
    local img_webhooks="${img_prefix}/kedacore/keda-admission-webhooks:${KEDA_IMAGE_TAG}"

    local git_version git_commit
    git_version="$(cd "${REPO_ROOT}" && git describe --always --abbrev=7)"
    git_commit="$(cd "${REPO_ROOT}" && git rev-list -1 HEAD)"

    log "Building container images (${SUDO:+sudo }${CONTAINER_TOOL})..."
    ${SUDO} ${CONTAINER_TOOL} build "${REPO_ROOT}" \
        -t "${img_controller}" \
        --build-arg "BUILD_VERSION=${KEDA_IMAGE_TAG}" \
        --build-arg "GIT_VERSION=${git_version}" \
        --build-arg "GIT_COMMIT=${git_commit}"
    ${SUDO} ${CONTAINER_TOOL} build "${REPO_ROOT}" \
        -f "${REPO_ROOT}/Dockerfile.adapter" \
        -t "${img_adapter}" \
        --build-arg "BUILD_VERSION=${KEDA_IMAGE_TAG}" \
        --build-arg "GIT_VERSION=${git_version}" \
        --build-arg "GIT_COMMIT=${git_commit}"
    ${SUDO} ${CONTAINER_TOOL} build "${REPO_ROOT}" \
        -f "${REPO_ROOT}/Dockerfile.webhooks" \
        -t "${img_webhooks}" \
        --build-arg "BUILD_VERSION=${KEDA_IMAGE_TAG}" \
        --build-arg "GIT_VERSION=${git_version}" \
        --build-arg "GIT_COMMIT=${git_commit}"

    log "Loading images into kind cluster..."
    for img in "${img_controller}" "${img_adapter}" "${img_webhooks}"; do
        local img_archive="/tmp/keda-image-$(date +%s%N).tar"
        ${SUDO} ${CONTAINER_TOOL} save "${img}" -o "${img_archive}"
        ${SUDO} kind load image-archive "${img_archive}" --name "${KIND_CLUSTER_NAME}"
        ${SUDO} rm -f "${img_archive}"
    done

    # Ensure keda namespace is fully gone from any previous run before deploying.
    if kubectl get ns "${KEDA_NAMESPACE}" &>/dev/null; then
        log "Waiting for namespace ${KEDA_NAMESPACE} to terminate..."
        kubectl delete ns "${KEDA_NAMESPACE}" --wait=true --timeout=60s 2>/dev/null || true
        while kubectl get ns "${KEDA_NAMESPACE}" &>/dev/null; do
            sleep 2
        done
    fi
    kubectl delete apiservice v1beta1.external.metrics.k8s.io 2>/dev/null || true

    log "Deploying KEDA via kustomize..."
    make -C "${REPO_ROOT}" deploy \
        VERSION="${KEDA_IMAGE_TAG}" \
        IMAGE_CONTROLLER="${img_controller}" \
        IMAGE_ADAPTER="${img_adapter}" \
        IMAGE_WEBHOOKS="${img_webhooks}" 2>&1 | tail -10

    log "Patching imagePullPolicy to Never..."
    for deploy in keda-operator keda-metrics-apiserver keda-admission; do
        kubectl patch deployment "${deploy}" -n "${KEDA_NAMESPACE}" \
            --type='json' \
            -p='[{"op": "replace", "path": "/spec/template/spec/containers/0/imagePullPolicy", "value": "Never"}]' 2>/dev/null || true
    done

    if [[ "${ENABLE_PPROF}" == "true" ]]; then
        log "Enabling pprof on keda-operator..."
        kubectl patch deployment keda-operator -n "${KEDA_NAMESPACE}" \
            --type='json' \
            -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--profiling-bind-address=:6060"}]'
    fi

    log "Waiting for KEDA pods to be ready..."
    kubectl rollout status deployment/keda-operator -n "${KEDA_NAMESPACE}" --timeout=180s
    kubectl rollout status deployment/keda-metrics-apiserver -n "${KEDA_NAMESPACE}" --timeout=180s
    kubectl rollout status deployment/keda-admission-webhooks -n "${KEDA_NAMESPACE}" --timeout=180s
    log "KEDA deployed successfully"
}

# ── KWOK setup ─────────────────────────────────────────────────────────────

setup_kwok() {
    if [[ "${SKIP_KWOK_SETUP}" == "true" ]]; then
        log "Skipping KWOK setup (SKIP_KWOK_SETUP=true)"
        return
    fi

    log "Installing KWOK ${KWOK_VERSION}..."
    kubectl create namespace "${KWOK_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    curl -sSfL "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/kwok.yaml" \
        | sed "s/namespace: kube-system/namespace: ${KWOK_NAMESPACE}/g" \
        | kubectl apply -f -

    log "Waiting for KWOK controller..."
    kubectl wait -n "${KWOK_NAMESPACE}" \
        --for=condition=Available \
        --timeout=120s \
        deployment/kwok-controller

    log "Applying KWOK lifecycle stages..."
    kubectl apply -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_VERSION}/stage-fast.yaml"

    log "Creating fake node '${KWOK_NODE_NAME}'..."
    kubectl apply -f "${SCRIPT_DIR}/resources/fake-node.yaml"
    log "KWOK ready"
}

cleanup_kwok() {
    if [[ "${SKIP_KWOK_SETUP}" != "true" ]]; then
        log "Cleaning up KWOK..."
        kubectl delete node "${KWOK_NODE_NAME}" --wait=false 2>/dev/null || true
        kubectl delete namespace "${KWOK_NAMESPACE}" --wait=false 2>/dev/null || true
    fi
}

# ── ScaledObject setup (triggers cache warming) ───────────────────────────

setup_scaledobject() {
    local so_manifest="${SCRIPT_DIR}/resources/scaledobject.yaml"
    if [[ ! -f "${so_manifest}" ]]; then
        log "No scaledobject.yaml found, skipping ScaledObject setup"
        return
    fi

    log "Applying ScaledObject to trigger Pod informer cache warming..."
    kubectl apply -f "${so_manifest}"
    sleep 5
    kubectl get scaledobject -n "${KEDA_NAMESPACE}" 2>/dev/null || true
    log "ScaledObject applied — keda-operator will now watch Pods cluster-wide"
}

cleanup_scaledobject() {
    kubectl delete -f "${SCRIPT_DIR}/resources/scaledobject.yaml" 2>/dev/null || true
}

# ── Resource management ────────────────────────────────────────────────────

create_test_namespace() {
    local ns=$1
    kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

create_resources() {
    local count=$1
    local ns=$2
    local batch_size=50

    log "Creating ${count} resources in ${ns} (batch size: ${batch_size})..."

    local batch_start=1
    while (( batch_start <= count )); do
        local batch_end=$(( batch_start + batch_size - 1 ))
        (( batch_end > count )) && batch_end=${count}

        local manifest="/tmp/load-test-batch-$(date +%s%N).yaml"
        for (( i=batch_start; i<=batch_end; i++ )); do
            RESOURCE_INDEX="${i}" TEST_NAMESPACE="${ns}" \
                envsubst '${RESOURCE_INDEX} ${TEST_NAMESPACE} ${KWOK_NODE_NAME}' \
                < "${RESOURCE_TEMPLATE_PATH}" >> "${manifest}"
            echo "---" >> "${manifest}"
        done

        kubectl apply --server-side -f "${manifest}" >/dev/null 2>&1
        rm -f "${manifest}"

        log "  Applied ${batch_end}/${count} resources"
        batch_start=$(( batch_end + 1 ))
    done

    log "Applied all ${count} resources"
}

delete_test_namespace() {
    local ns=$1
    log "Deleting namespace ${ns}..."
    kubectl delete namespace "${ns}" --wait=true --timeout=300s 2>/dev/null || \
        log "WARNING: namespace ${ns} not fully deleted within timeout"
}

# ── Memory measurement ─────────────────────────────────────────────────────

get_pod_memory_mib() {
    local app_label=$1
    local ns=$2

    local pod_name
    pod_name=$(kubectl get pods -n "${ns}" -l "app=${app_label}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -z "${pod_name}" ]]; then
        echo "N/A"
        return
    fi

    # Check if pod is healthy
    local phase
    phase=$(kubectl get pod "${pod_name}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null)
    if [[ "${phase}" != "Running" ]]; then
        local reason
        reason=$(kubectl get pod "${pod_name}" -n "${ns}" \
            -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}' 2>/dev/null)
        if [[ "${reason}" == "OOMKilled" ]]; then
            echo "OOMKilled"
        else
            echo "FAILING"
        fi
        return
    fi

    # Use kubectl top for memory reading (returns Mi)
    local mem_mi
    mem_mi=$(kubectl top pod "${pod_name}" -n "${ns}" --no-headers 2>/dev/null \
        | awk '{print $3}' | sed 's/Mi//')
    if [[ -n "${mem_mi}" && "${mem_mi}" =~ ^[0-9]+$ ]]; then
        echo "${mem_mi}"
    else
        echo "N/A"
    fi
}

sample_keda_memory() {
    local step=$1
    local best_of=3
    local interval=5

    log "Sampling KEDA pod memory (best of ${best_of} samples over $((best_of * interval))s)..."

    for pod_prefix in "${KEDA_PODS[@]}"; do
        local max_mem=0
        for (( s=0; s<best_of; s++ )); do
            local mem
            mem=$(get_pod_memory_mib "${pod_prefix}" "${KEDA_NAMESPACE}")
            if [[ "${mem}" == "OOMKilled" || "${mem}" == "FAILING" ]]; then
                max_mem="${mem}"
                break
            fi
            if [[ "${mem}" =~ ^[0-9]+$ ]] && (( mem > max_mem )); then
                max_mem=${mem}
            fi
            if (( s < best_of - 1 )); then
                sleep "${interval}"
            fi
        done
        RESULT_MEM["${step}:${pod_prefix}"]="${max_mem}"
        log "  ${pod_prefix}: ${max_mem} Mi"
    done
}

# ── Report ─────────────────────────────────────────────────────────────────

print_report() {
    echo ""
    bold "## KEDA Memory Load Test Report"
    echo "## Template: ${RESOURCE_TEMPLATE_PATH}"
    echo "## Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    # Header
    printf "| %-35s" "pod"
    for step in "${RESULT_STEPS[@]}"; do
        if [[ "${step}" == "baseline" ]]; then
            printf " | %10s" "baseline"
        else
            printf " | %8s" "${step} res"
        fi
    done
    printf " | %10s |\n" "delta"

    # Separator
    printf "|%s" "$(printf -- '-%.0s' {1..37})"
    for _ in "${RESULT_STEPS[@]}"; do
        printf "|%s" "$(printf -- '-%.0s' {1..12})"
    done
    printf "|%s|\n" "$(printf -- '-%.0s' {1..12})"

    # Rows
    for pod_prefix in "${KEDA_PODS[@]}"; do
        printf "| %-35s" "${pod_prefix}"
        local baseline_val=""
        local last_val=""
        for step in "${RESULT_STEPS[@]}"; do
            local val="${RESULT_MEM["${step}:${pod_prefix}"]:-N/A}"
            if [[ "${step}" == "baseline" ]]; then
                baseline_val="${val}"
            fi
            last_val="${val}"
            if [[ "${val}" =~ ^[0-9]+$ ]]; then
                printf " | %7s Mi" "${val}"
            else
                printf " | %10s" "${val}"
            fi
        done

        # Delta column
        if [[ "${baseline_val}" =~ ^[0-9]+$ && "${last_val}" =~ ^[0-9]+$ ]]; then
            local delta=$(( last_val - baseline_val ))
            local sign="+"
            (( delta < 0 )) && sign=""
            printf " | %7s Mi" "${sign}${delta}"
        elif [[ "${last_val}" == "OOMKilled" || "${last_val}" == "FAILING" ]]; then
            printf " | %10s" "${last_val}"
        else
            printf " | %10s" "-"
        fi
        printf " |\n"
    done
    echo ""
}

# ── Cleanup ────────────────────────────────────────────────────────────────

cleanup() {
    local exit_code=$?
    log "Cleaning up..."

    # Delete any leftover test namespaces
    for ns in $(kubectl get ns --no-headers -o custom-columns=":metadata.name" 2>/dev/null | grep "^${TEST_NAMESPACE_PREFIX}-" || true); do
        kubectl delete namespace "${ns}" --wait=false 2>/dev/null || true
    done

    cleanup_scaledobject
    cleanup_kwok

    if [[ -n "${REPORT_PATH}" ]]; then
        print_report | tee "${REPORT_PATH}"
        log "Report saved to ${REPORT_PATH}"
    else
        print_report
    fi

    delete_kind_cluster
    exit ${exit_code}
}
trap cleanup EXIT

# ── Main load loop ─────────────────────────────────────────────────────────

run_load_test() {
    log "Starting load test"
    log "  Resource counts: ${RESOURCE_COUNTS}"
    log "  Template: ${RESOURCE_TEMPLATE_PATH}"
    log "  Sample duration: ${SAMPLE_DURATION}s"
    log "  Settle duration: ${SETTLE_DURATION}s"
    echo ""

    # Wait for metrics to be available
    log "Waiting for metrics API to become available..."
    local retries=0
    while ! kubectl top pod -n "${KEDA_NAMESPACE}" --no-headers &>/dev/null; do
        retries=$((retries + 1))
        if (( retries > 60 )); then
            die "Metrics API not available after 60 retries"
        fi
        sleep 5
    done
    log "Metrics API ready"

    # Baseline
    log "=== Baseline: sampling memory with no load (waiting ${SAMPLE_DURATION}s) ==="
    sleep "${SAMPLE_DURATION}"
    RESULT_STEPS+=("baseline")
    sample_keda_memory "baseline"

    # Steps
    for count in ${RESOURCE_COUNTS}; do
        local step_ns="${TEST_NAMESPACE_PREFIX}-${count}"
        echo ""
        log "=== Step: ${count} resources ==="

        create_test_namespace "${step_ns}"
        create_resources "${count}" "${step_ns}"

        log "Waiting ${SAMPLE_DURATION}s for memory to stabilize..."
        sleep "${SAMPLE_DURATION}"

        RESULT_STEPS+=("${count}")
        sample_keda_memory "${count}"

        delete_test_namespace "${step_ns}"

        log "Waiting ${SETTLE_DURATION}s for GC to settle before next step..."
        sleep "${SETTLE_DURATION}"
    done

    log "Load test complete"
}

# ── Entrypoint ─────────────────────────────────────────────────────────────

main() {
    check_prerequisites

    echo ""
    bold "KEDA Memory Load Test (issue #7728)"
    echo "===================================="
    echo ""

    create_kind_cluster
    deploy_keda
    setup_kwok
    setup_scaledobject
    run_load_test
}

main "$@"
