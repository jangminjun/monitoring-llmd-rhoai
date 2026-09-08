#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"
LLMD_NAMESPACE="${LLMD_NAMESPACE:-llmd-scenario11}"
LLMD_NAME="${LLMD_NAME:-llmd-dp-demo}"
oc delete pod llmd-load-generator -n "$LLMD_NAMESPACE" --ignore-not-found
oc delete llminferenceservice "$LLMD_NAME" -n "$LLMD_NAMESPACE" --ignore-not-found
echo "Scenario 11 resources deleted from $LLMD_NAMESPACE."
