#!/usr/bin/env bash
# Runs ON the bastion, after rhoai.sh (DataScienceCluster must already be
# Ready). Installs RHCL (Kuadrant: Authorino + Limitador) and enables
# RHOAI's integrated Models-as-a-Service (MaaS) gateway, required for llm-d
# serving. Ported from https://github.com/hyogrin/RHOAI-Toolkit
# (scripts/setup-maas.sh, RHOAI 3.3+ "integrated" path) and adapted to this
# harness's conventions. Idempotent — every step checks before creating.
set -euo pipefail
export KUBECONFIG="$HOME/ocp-install/auth/kubeconfig"

echo "== Step 0: cert-manager operator (Authorino TLS depends on it) =="

if oc get crd certificates.cert-manager.io &>/dev/null; then
  echo "cert-manager already installed."
else
  oc get namespace cert-manager-operator &>/dev/null || oc create namespace cert-manager-operator
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML
  echo "Waiting for cert-manager CRDs (up to 5m)..."
  for _ in $(seq 1 30); do
    oc get crd certificates.cert-manager.io &>/dev/null && break
    sleep 10
  done
  oc get crd certificates.cert-manager.io &>/dev/null || { echo "Timed out waiting for cert-manager CRDs" >&2; exit 1; }
  echo "Waiting for cert-manager webhook to be ready (up to 2m)..."
  for _ in $(seq 1 12); do
    oc get pods -n cert-manager -l app=webhook 2>/dev/null | grep -q Running && break
    sleep 10
  done
fi

echo "== Step 1: RHCL (Kuadrant) operator =="

oc get namespace kuadrant-system &>/dev/null || oc create namespace kuadrant-system

if oc get csv -n kuadrant-system 2>/dev/null | grep -qi rhcl-operator; then
  echo "RHCL operator already installed."
else
  oc apply -f - <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kuadrant-system
  namespace: kuadrant-system
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: kuadrant-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
YAML
  echo "Waiting for RHCL operator CRDs (up to 5m)..."
  for _ in $(seq 1 30); do
    oc get crd kuadrants.kuadrant.io &>/dev/null && break
    sleep 10
  done
  oc get crd kuadrants.kuadrant.io &>/dev/null || { echo "Timed out waiting for RHCL CRDs" >&2; exit 1; }
fi

if oc get kuadrant kuadrant -n kuadrant-system &>/dev/null; then
  echo "Kuadrant instance already exists."
else
  oc apply -f - <<'YAML'
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
YAML
  echo "Waiting for Authorino service (up to 2m)..."
  for _ in $(seq 1 12); do
    oc get svc/authorino-authorino-authorization -n kuadrant-system &>/dev/null && break
    sleep 10
  done
fi

echo "== Step 2: Authorino instance =="
# Listener TLS deliberately OFF: RHOAI 3.5's aigateway-operator/maas-controller
# auto-generates an EnvoyFilter (kuadrant-auth-<gateway-name>) that adds a
# plaintext (no transport_socket) Envoy cluster pointing at
# authorino-authorino-authorization:50051. An earlier version of this script
# turned listener.tls on (via a cert-manager cert) here, carried over from an
# RHOAI 3.3/3.4-era setup guide -- on 3.5 that makes Authorino refuse the
# plaintext connection the generated EnvoyFilter actually makes, so EVERY
# request through the MaaS gateway fails with a generic 500 and zero log
# lines on the Authorino/Limitador side (the gRPC call dies at the TLS
# handshake before reaching either). Confirmed fixed by leaving TLS off here
# -- see docs/scenarios/17-maas-external-oidc-auth.md "6) 근본 원인 확정" in
# the openshift-ai-maas-demo repo for the full trace. If a future RHOAI
# version's generated EnvoyFilter switches back to TLS for this cluster,
# this needs revisiting (check with: oc get envoyfilter
# kuadrant-auth-<gateway-name> -n openshift-ingress -o yaml, look for
# transport_socket on the authorino-authorino-authorization cluster patch).

oc apply -f - <<'YAML'
apiVersion: operator.authorino.kuadrant.io/v1beta1
kind: Authorino
metadata:
  name: authorino
  namespace: kuadrant-system
spec:
  replicas: 1
  clusterWide: true
  listener:
    tls:
      enabled: false
  oidcServer:
    tls:
      enabled: false
YAML

echo "== Step 3: Enable AI Gateway / modelsAsAService in DataScienceCluster =="
# RHOAI 3.5+: spec.components.kserve.modelsAsService is deprecated in favor of
# the new top-level spec.components.aigateway.modelsAsAService (note the
# "AsA" spelling -- matches the ai-gateway-operator CRD field name, confirmed
# via `oc explain datasciencecluster.spec.components.aigateway.modelsAsAService`,
# not a typo). Setting the old field errors: "modelsAsService is deprecated;
# cannot re-enable once Removed." On RHOAI 3.3/3.4 the old field is still what
# exists -- this harness targets 3.5+ per AGENT.md, so only the new path is
# implemented here.

current_state=$(oc get datasciencecluster default-dsc -o jsonpath='{.spec.components.aigateway.modelsAsAService.managementState}' 2>/dev/null || echo "")
if [ "$current_state" = "Managed" ]; then
  echo "aigateway.modelsAsAService already Managed."
else
  oc patch datasciencecluster default-dsc --type=merge -p '{
    "spec": {"components": {"aigateway": {"managementState": "Managed", "modelsAsAService": {"managementState": "Managed"}}}}
  }'
  echo "Waiting 30s for DataScienceCluster to reconcile..."
  sleep 30
fi

echo "== Step 4: Inference GatewayClass/Gateway(s) =="
# RHOAI 3.5's maas-controller does NOT auto-create its Gateway -- it explicitly
# refuses to reconcile until one named exactly "maas-default-gateway" exists in
# openshift-ingress ("the Gateway must be created by a network or cluster
# administrator before AITenant can be provisioned", confirmed from
# maas-controller logs / AIGateway status conditions). This is a *separate*
# Gateway object from openshift-ai-inference below -- both are needed.
#
# Also: "default-gateway-tls" (the cert this script used to reference) does not
# exist on a fresh cluster -- there's nothing that creates it. Using the
# cluster's own default ingress router cert (router-certs-default, already in
# openshift-ingress) instead avoids needing a separate cert-manager Certificate
# for this.

CLUSTER_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')

oc get gatewayclass openshift-ai-inference &>/dev/null || oc apply -f - <<'YAML'
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: openshift-ai-inference
spec:
  controllerName: openshift.io/gateway-controller/v1
YAML

if oc get gateway openshift-ai-inference -n openshift-ingress &>/dev/null; then
  echo "Gateway openshift-ai-inference already exists."
else
  oc apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/rev: openshift-gateway
  name: openshift-ai-inference
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-ai-inference
  listeners:
    - allowedRoutes:
        namespaces:
          from: All
      hostname: inference-gateway.${CLUSTER_DOMAIN}
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ''
            kind: Secret
            name: router-certs-default
        mode: Terminate
YAML
fi

if oc get gateway maas-default-gateway -n openshift-ingress &>/dev/null; then
  echo "Gateway maas-default-gateway already exists."
else
  oc apply -f - <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/rev: openshift-gateway
  name: maas-default-gateway
  namespace: openshift-ingress
spec:
  gatewayClassName: openshift-ai-inference
  listeners:
    - allowedRoutes:
        namespaces:
          from: All
      hostname: maas.${CLUSTER_DOMAIN}
      name: https
      port: 443
      protocol: HTTPS
      tls:
        certificateRefs:
          - group: ''
            kind: Secret
            name: router-certs-default
        mode: Terminate
YAML
fi

echo "== Step 4b: MaaS API database =="
# RHOAI 3.5's maas-api component needs its own Postgres -- nothing provisions
# one automatically. Ephemeral single-pod instance, demo/test only (same
# pattern as this repo's other harness for Keycloak's DB) -- not HA, data lost
# on pod restart.
oc get namespace redhat-ai-gateway-infra &>/dev/null || oc create namespace redhat-ai-gateway-infra

if oc get secret maas-db-config -n redhat-ai-gateway-infra &>/dev/null; then
  echo "maas-db-config already exists."
else
  DB_PASSWORD=$(openssl rand -hex 16)
  oc create secret generic maas-postgres-creds -n redhat-ai-gateway-infra \
    --from-literal=username=maas --from-literal=password="$DB_PASSWORD" \
    --dry-run=client -o yaml | oc apply -f -
  oc apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: maas-db
  namespace: redhat-ai-gateway-infra
spec:
  replicas: 1
  selector:
    matchLabels: {app: maas-db}
  template:
    metadata:
      labels: {app: maas-db}
    spec:
      containers:
        - name: postgres
          image: registry.redhat.io/rhel9/postgresql-15:latest
          env:
            - {name: POSTGRESQL_USER, valueFrom: {secretKeyRef: {name: maas-postgres-creds, key: username}}}
            - {name: POSTGRESQL_PASSWORD, valueFrom: {secretKeyRef: {name: maas-postgres-creds, key: password}}}
            - {name: POSTGRESQL_DATABASE, value: maasdb}
          ports: [{containerPort: 5432}]
          volumeMounts: [{name: data, mountPath: /var/lib/pgsql/data}]
      volumes: [{name: data, emptyDir: {}}]
---
apiVersion: v1
kind: Service
metadata:
  name: maas-db
  namespace: redhat-ai-gateway-infra
spec:
  selector: {app: maas-db}
  ports: [{port: 5432, targetPort: 5432}]
YAML
  echo "Waiting for maas-db to be ready (up to 2m)..."
  oc rollout status deployment/maas-db -n redhat-ai-gateway-infra --timeout=120s
  oc create secret generic maas-db-config -n redhat-ai-gateway-infra \
    --from-literal=DB_CONNECTION_URL="postgresql://maas:${DB_PASSWORD}@maas-db.redhat-ai-gateway-infra.svc:5432/maasdb" \
    --dry-run=client -o yaml | oc apply -f -
fi

echo "== Step 5: Dashboard MaaS features =="
oc patch odhdashboardconfig odh-dashboard-config -n redhat-ods-applications --type=merge -p '{
  "spec": {"dashboardConfig": {"disableModelRegistry": false, "disableModelCatalog": false,
  "disableKServeMetrics": false, "genAiStudio": true, "modelAsService": true, "disableLMEval": false}}
}' 2>/dev/null || echo "Could not patch odhdashboardconfig (may not exist yet) - continuing."

echo "== Step 6: Restart controllers to pick up the new config =="
oc delete pod -n redhat-ods-applications -l app=odh-model-controller --ignore-not-found=true
oc delete pod -n redhat-ods-applications -l control-plane=kserve-controller-manager --ignore-not-found=true
sleep 10

echo "== Step 7: Protect maas-default-gateway from odh-model-controller policy takeover =="
# The moment any LLMInferenceService is deployed, odh-model-controller's
# "gateway-auth-bootstrap" sub-controller creates its OWN AuthPolicy
# (<gateway>-authn) targeting this same Gateway -- Kuadrant's policy
# conflict resolution then makes that one "Enforced" and demotes this
# MaaS-managed AuthPolicy to "Overridden", silently dropping any custom
# identity sources (e.g. external OIDC) added on top of it. This annotation
# tells that controller to leave this Gateway's policies alone. Confirmed
# live: with this set, odh-model-controller deletes its own competing
# AuthPolicy instead of creating/keeping one. See
# docs/scenarios/17-maas-external-oidc-auth.md section 7 in
# openshift-ai-maas-demo for the full trace (including the controller's own
# log lines proving this).
oc annotate gateway maas-default-gateway -n openshift-ingress \
  opendatahub.io/managed="false" \
  security.opendatahub.io/authorino-tls-bootstrap="true" \
  --overwrite

echo ""
echo "MaaS setup complete."
echo "MaaS endpoint (once a model with MaaS enabled is deployed): https://maas.${CLUSTER_DOMAIN}"
echo "Inference gateway:  https://inference-gateway.${CLUSTER_DOMAIN}"
echo "Verify: oc get tenants.maas.opendatahub.io -A ; oc get gateway -A"
