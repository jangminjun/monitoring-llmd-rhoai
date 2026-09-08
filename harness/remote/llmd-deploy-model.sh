#!/usr/bin/env bash
# Shared by the llm-d scenario scripts (scenario11-14): deploys one
# LLMInferenceService directly from a HuggingFace repo (no PVC/data
# connection needed). Runs ON the bastion. Idempotent.
#
# Default model is Qwen2.5-7B-Instruct, not the newer Qwen3.5/3.6 family --
# Qwen3.5 introduces a hybrid Gated DeltaNet + Gated Attention architecture
# that is NOT confirmed compatible with the vLLM build RHOAI 3.4.4 ships
# (registry.redhat.io/rhaii/vllm-cuda-rhel9). Override MODEL_URI/MODEL_NAME
# to try Qwen3.5-9B once that's verified (LLMD_MODEL_URI=hf://Qwen/Qwen3.5-9B) --
# see docs/scenarios/qwen3.5-compat-check.md in monitoring-llmd-rhoai for
# how to check compatibility before betting a whole scenario run on it.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

LLMD_NAMESPACE="${LLMD_NAMESPACE:?set LLMD_NAMESPACE}"
LLMD_NAME="${LLMD_NAME:-llmd-demo}"
MODEL_URI="${LLMD_MODEL_URI:-hf://Qwen/Qwen2.5-7B-Instruct}"
MODEL_NAME="${LLMD_MODEL_NAME:-$(basename "$MODEL_URI")}"
REPLICAS="${LLMD_REPLICAS:-1}"
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g5.2xlarge}"
MAX_MODEL_LEN="${LLMD_MAX_MODEL_LEN:-16384}"
GPU_MEM_UTIL="${LLMD_GPU_MEM_UTIL:-0.90}"
EXTRA_VLLM_ARGS="${LLMD_EXTRA_VLLM_ARGS:-}"
# Gateway name varies by how MaaS was set up -- this harness's maas.sh
# creates "openshift-ai-inference"; some RHOAI dashboard-driven setups
# create "maas-default-gateway" instead. Auto-detect if not overridden
# rather than hardcoding one (bit live 2026-09-08: hardcoded
# maas-default-gateway on a cluster that only had openshift-ai-inference --
# LLMInferenceService came up with WorkloadsReady=True but
# GatewaysReady=False, so it never went fully Ready).
GATEWAY_NAME="${LLMD_GATEWAY_NAME:-}"
GATEWAY_NAMESPACE="${LLMD_GATEWAY_NAMESPACE:-openshift-ingress}"
STORAGE_INIT_IMAGE="${STORAGE_INIT_IMAGE:-registry.redhat.io/rhoai/odh-kserve-storage-initializer-rhel9@sha256:0e900505bb5033e6e9dbc9bb096ee97cdd5abe5bb2030c0d53334b66916476b5}"

echo "=== ClusterStorageContainer for hf:// (cluster-scoped, only created if missing) ==="
oc get clusterstoragecontainer hf-hub >/dev/null 2>&1 || oc apply -f - <<YAML
apiVersion: serving.kserve.io/v1alpha1
kind: ClusterStorageContainer
metadata:
  name: hf-hub
spec:
  container:
    name: storage-initializer
    image: ${STORAGE_INIT_IMAGE}
    resources:
      requests:
        memory: 100Mi
        cpu: 100m
      limits:
        memory: 4Gi
        cpu: "1"
  supportedUriFormats:
  - regex: "^hf://"
YAML

oc get namespace "$LLMD_NAMESPACE" &>/dev/null || oc create namespace "$LLMD_NAMESPACE"

if [ -z "$GATEWAY_NAME" ]; then
  GATEWAY_NAME=$(oc get gateway -n "$GATEWAY_NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="maas-default-gateway")].metadata.name}' 2>/dev/null)
  [ -z "$GATEWAY_NAME" ] && GATEWAY_NAME=$(oc get gateway -n "$GATEWAY_NAMESPACE" -o jsonpath='{.items[?(@.metadata.name=="openshift-ai-inference")].metadata.name}' 2>/dev/null)
  [ -z "$GATEWAY_NAME" ] && GATEWAY_NAME=$(oc get gateway -n "$GATEWAY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi
if [ -z "$GATEWAY_NAME" ]; then
  echo "No Gateway found in $GATEWAY_NAMESPACE -- run 'harness.sh maas' first." >&2
  exit 1
fi
echo "Using gateway: $GATEWAY_NAMESPACE/$GATEWAY_NAME"

echo "=== LLMInferenceService $LLMD_NAME ($MODEL_URI, $REPLICAS replica(s)) in $LLMD_NAMESPACE ==="
oc apply -f - <<YAML
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceService
metadata:
  name: ${LLMD_NAME}
  namespace: ${LLMD_NAMESPACE}
  labels:
    opendatahub.io/dashboard: "true"
spec:
  replicas: ${REPLICAS}
  model:
    name: ${MODEL_NAME}
    uri: ${MODEL_URI}
  router:
    gateway:
      refs:
      - name: ${GATEWAY_NAME}
        namespace: ${GATEWAY_NAMESPACE}
    route: {}
  template:
    containers:
    - name: main
      env:
      - name: VLLM_ADDITIONAL_ARGS
        value: "--max-model-len=${MAX_MODEL_LEN} --enforce-eager --gpu-memory-utilization=${GPU_MEM_UTIL}${EXTRA_VLLM_ARGS:+ }${EXTRA_VLLM_ARGS}"
      resources:
        limits:
          cpu: "2"
          memory: 16Gi
          nvidia.com/gpu: "1"
        requests:
          cpu: "2"
          memory: 16Gi
          nvidia.com/gpu: "1"
    nodeSelector:
      node.kubernetes.io/instance-type: ${GPU_INSTANCE_TYPE}
    tolerations:
    - effect: NoSchedule
      key: nvidia.com/gpu
      operator: Exists
YAML

echo "Waiting for LLMInferenceService to become Ready (up to 10m -- includes model download)..."
for _ in $(seq 1 60); do
  ready=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
  [ "$ready" = "True" ] && break
  sleep 10
done
oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE"

# Re-check once more -- the loop above can exhaust its last sleep right as
# the condition flips (confirmed live 2026-09-08: loop's own last read saw
# stale state and exited 1, even though the informational `oc get` right
# above it already showed READY=True moments later).
ready=$(oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

if [ "$ready" != "True" ]; then
  echo "NOT Ready yet -- check: oc describe llminferenceservice $LLMD_NAME -n $LLMD_NAMESPACE" >&2
  echo "and: oc logs -n $LLMD_NAMESPACE -l app.kubernetes.io/name=$LLMD_NAME --tail=100" >&2
  exit 1
fi

echo "Ready. Internal endpoint (from any pod in-cluster, or via oc port-forward to the workload svc):"
oc get llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" -o jsonpath='{.status.addresses}' | python3 -m json.tool
