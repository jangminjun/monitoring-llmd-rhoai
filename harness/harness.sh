#!/usr/bin/env bash
# llm-d / MaaS harness for this repo (monitoring-llmd-rhoai). Assumes the
# base cluster already exists (bastion, OpenShift, GPU nodes, RHOAI,
# monitoring/logging) -- built separately via openshift-aws-harness
# (https://github.com/jangminjun/openshift-aws-harness), which stays the
# generic "install a cluster" tool. This harness only adds what's specific
# to llm-d testing: MaaS/RHCL, request tracing, model deployment, and the
# scenario 11-14 demos (docs/scenarios/*.md). Idempotent where the
# underlying remote scripts are idempotent.
#
# Usage: ./harness.sh <subcommand> [args]
#   maas                                install RHCL (Kuadrant/Authorino) + enable modelsAsService in the DSC
#   llmd-deploy-model                     deploy one LLMInferenceService (LLMD_NAMESPACE/LLMD_NAME/LLMD_MODEL_URI/...)
#   llmd-monitoring                         PrometheusRule + Grafana dashboard for one LLMInferenceService (LLMD_NAMESPACE)
#   tracing                                   COO + RHBO(OpenTelemetry) + Tempo Operator + TempoStack (llm-d request tracing)
#   scenario11-llmd-dp-{start,scale,load,stop}  data parallelism: 1 replica vs N, throughput comparison
#   scenario12-llmd-failure-{start,trigger,stop}  failure & recovery: kill a workload pod under traffic
#   scenario13-llmd-tracing-{demo,stop}             request tracing: OTLP-enabled model, per-request trace in Tempo
#   scenario14-llmd-latency-{start,diagnose,stop}     latency diagnosis: queue/prefill/decode breakdown
#
# Config: harness/config.env (bastion IP, SSH key, cluster name). Cluster
# access details also documented in ../AGENT.md.
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HARNESS_DIR"
source ./config.env
source ./lib.sh

MONITORING_NAMESPACE="${MONITORING_NAMESPACE:-gpu-monitoring}"

cmd="${1:-}"
[ -n "$cmd" ] && shift || true

cmd_maas()         { ssh_bastion 'bash -s' < ./remote/maas.sh; }

cmd_llmd_deploy_model() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:?set LLMD_NAMESPACE}' LLMD_NAME='${LLMD_NAME:-llmd-demo}' \
    LLMD_MODEL_URI='${LLMD_MODEL_URI:-}' LLMD_MODEL_NAME='${LLMD_MODEL_NAME:-}' LLMD_REPLICAS='${LLMD_REPLICAS:-1}' \
    GPU_INSTANCE_TYPE='${GPU_INSTANCE_TYPE:-g5.2xlarge}' LLMD_MAX_MODEL_LEN='${LLMD_MAX_MODEL_LEN:-16384}' \
    LLMD_GPU_MEM_UTIL='${LLMD_GPU_MEM_UTIL:-0.90}' LLMD_EXTRA_VLLM_ARGS='${LLMD_EXTRA_VLLM_ARGS:-}' \
    LLMD_GATEWAY_NAME='${LLMD_GATEWAY_NAME:-}' LLMD_GATEWAY_NAMESPACE='${LLMD_GATEWAY_NAMESPACE:-openshift-ingress}' \
    bash -s" < ./remote/llmd-deploy-model.sh
}

cmd_llmd_monitoring() {
  ssh_bastion "mkdir -p ~/ocp-install"
  scp_to_bastion ./remote/dashboards/llmd-observability.json "~/ocp-install/llmd-observability.json"
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:?set LLMD_NAMESPACE}' MONITORING_NAMESPACE='$MONITORING_NAMESPACE' \
    LLMD_TTFT_THRESHOLD_S='${LLMD_TTFT_THRESHOLD_S:-2}' LLMD_ERROR_RATE_THRESHOLD='${LLMD_ERROR_RATE_THRESHOLD:-0.05}' \
    bash -s" < ./remote/llmd-monitoring.sh
}

cmd_tracing() { ssh_bastion 'bash -s' < ./remote/tracing.sh; }

# --- Scenario 11: llm-d data parallelism ---
cmd_scenario11_llmd_dp_start() {
  LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-scenario11}" LLMD_NAME="${LLMD_NAME:-llmd-dp-demo}" LLMD_REPLICAS=1 \
    cmd_llmd_deploy_model
}
cmd_scenario11_llmd_dp_scale() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:-llmd-scenario11}' LLMD_NAME='${LLMD_NAME:-llmd-dp-demo}' \
    LLMD_REPLICAS='${LLMD_REPLICAS:?set LLMD_REPLICAS}' bash -s" < ./remote/scenario11-llmd-dp-scale.sh
}
cmd_scenario11_llmd_dp_load() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:-llmd-scenario11}' LLMD_NAME='${LLMD_NAME:-llmd-dp-demo}' \
    CONCURRENCY='${CONCURRENCY:-8}' DURATION='${DURATION:-90}' bash -s" < ./remote/scenario11-llmd-dp-load.sh
}
cmd_scenario11_llmd_dp_stop() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:-llmd-scenario11}' LLMD_NAME='${LLMD_NAME:-llmd-dp-demo}' \
    bash -s" < ./remote/scenario11-llmd-dp-stop.sh
}

# --- Scenario 12: llm-d failure & recovery ---
cmd_scenario12_llmd_failure_start() {
  LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-scenario12}" LLMD_NAME="${LLMD_NAME:-llmd-failure-demo}" LLMD_REPLICAS=1 \
    cmd_llmd_deploy_model
}
cmd_scenario12_llmd_failure_trigger() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:-llmd-scenario12}' LLMD_NAME='${LLMD_NAME:-llmd-failure-demo}' \
    TRAFFIC_DURATION='${TRAFFIC_DURATION:-180}' bash -s" < ./remote/scenario12-llmd-failure-trigger.sh
}
cmd_scenario12_llmd_failure_stop() {
  ssh_bastion "export KUBECONFIG=~/ocp-install/auth/kubeconfig; \
    oc delete llminferenceservice '${LLMD_NAME:-llmd-failure-demo}' -n '${LLMD_NAMESPACE:-llmd-scenario12}' --ignore-not-found"
}

# --- Scenario 13: llm-d request tracing ---
cmd_scenario13_llmd_tracing_demo() {
  LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-scenario13}" LLMD_NAME="${LLMD_NAME:-llmd-tracing-demo}" LLMD_REPLICAS=1 \
    LLMD_EXTRA_VLLM_ARGS="--otlp-traces-endpoint=grpc://tempo-llmd-tracing-distributor.${TRACING_NAMESPACE:-openshift-tempo}.svc:4317" \
    cmd_llmd_deploy_model
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:-llmd-scenario13}' LLMD_NAME='${LLMD_NAME:-llmd-tracing-demo}' \
    TRACING_NAMESPACE='${TRACING_NAMESPACE:-openshift-tempo}' bash -s" < ./remote/scenario13-llmd-tracing-demo.sh
}
cmd_scenario13_llmd_tracing_stop() {
  ssh_bastion "export KUBECONFIG=~/ocp-install/auth/kubeconfig; \
    oc delete llminferenceservice '${LLMD_NAME:-llmd-tracing-demo}' -n '${LLMD_NAMESPACE:-llmd-scenario13}' --ignore-not-found"
}

# --- Scenario 14: llm-d latency diagnosis ---
cmd_scenario14_llmd_latency_start() {
  LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-scenario14}" LLMD_NAME="${LLMD_NAME:-llmd-latency-demo}" LLMD_REPLICAS=1 \
    cmd_llmd_deploy_model
}
cmd_scenario14_llmd_latency_diagnose() {
  ssh_bastion "LLMD_NAMESPACE='${LLMD_NAMESPACE:-llmd-scenario14}' LLMD_NAME='${LLMD_NAME:-llmd-latency-demo}' \
    CONCURRENCY='${CONCURRENCY:-6}' DURATION='${DURATION:-60}' bash -s" < ./remote/scenario14-llmd-latency-diagnose.sh
}
cmd_scenario14_llmd_latency_stop() {
  ssh_bastion "export KUBECONFIG=~/ocp-install/auth/kubeconfig; \
    oc delete llminferenceservice '${LLMD_NAME:-llmd-latency-demo}' -n '${LLMD_NAMESPACE:-llmd-scenario14}' --ignore-not-found"
}

cmd_status() {
  ssh_bastion "export KUBECONFIG=~/ocp-install/auth/kubeconfig; \
    echo '=== llm-d LLMInferenceServices ==='; oc get llminferenceservice -A; \
    echo '=== GPU nodes ==='; oc get nodes -l nvidia.com/gpu.present=true -o jsonpath='{range .items[*]}{.metadata.name}{\"\t\"}{.metadata.labels.node\\.kubernetes\\.io/instance-type}{\"\n\"}{end}'; \
    echo '=== MaaS ==='; oc get gateway -n openshift-ingress 2>&1; \
    echo '=== Tracing ==='; oc get tempostack -A 2>&1"
}

case "$cmd" in
  maas)                               cmd_maas ;;
  llmd-deploy-model)                  cmd_llmd_deploy_model ;;
  llmd-monitoring)                    cmd_llmd_monitoring ;;
  tracing)                            cmd_tracing ;;
  scenario11-llmd-dp-start)           cmd_scenario11_llmd_dp_start ;;
  scenario11-llmd-dp-scale)           cmd_scenario11_llmd_dp_scale ;;
  scenario11-llmd-dp-load)            cmd_scenario11_llmd_dp_load ;;
  scenario11-llmd-dp-stop)            cmd_scenario11_llmd_dp_stop ;;
  scenario12-llmd-failure-start)      cmd_scenario12_llmd_failure_start ;;
  scenario12-llmd-failure-trigger)    cmd_scenario12_llmd_failure_trigger ;;
  scenario12-llmd-failure-stop)       cmd_scenario12_llmd_failure_stop ;;
  scenario13-llmd-tracing-demo)       cmd_scenario13_llmd_tracing_demo ;;
  scenario13-llmd-tracing-stop)       cmd_scenario13_llmd_tracing_stop ;;
  scenario14-llmd-latency-start)      cmd_scenario14_llmd_latency_start ;;
  scenario14-llmd-latency-diagnose)   cmd_scenario14_llmd_latency_diagnose ;;
  scenario14-llmd-latency-stop)       cmd_scenario14_llmd_latency_stop ;;
  status)                             cmd_status ;;
  *)
    err "Unknown subcommand '$cmd'. See header comment in ./harness.sh for the list."
    ;;
esac
