#!/usr/bin/env bash
set -euo pipefail

# This installs controllers on a fresh learning cluster, not GPU nodes or models.
example_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
for tool in kubectl helm yq; do
  command -v "$tool" >/dev/null || { echo "Install $tool first. See kserve/INSTALL.md." >&2; exit 1; }
done
yq --version | grep -q 'mikefarah/yq' || { echo 'Use Mike Farah yq v4, not the Python tool with the same name.' >&2; exit 1; }

echo "Cluster: $(kubectl config current-context)"
kubectl get namespaces >/dev/null
# Do not take ownership of someone else's platform.
for namespace in kserve envoy-gateway-system envoy-ai-gateway-system cert-manager lws-system; do
  if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    echo "Namespace $namespace already exists. Read the existing-platform notes in INSTALL.md." >&2
    exit 1
  fi
done
for crd in certificates.cert-manager.io gateways.gateway.networking.k8s.io inferencepools.inference.networking.k8s.io llminferenceservices.serving.kserve.io; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    echo "CRD $crd already exists. This installer is for a fresh learning cluster." >&2
    exit 1
  fi
done

# Pins follow the KServe v0.20.0 release installer.
echo 'Installing cert-manager for controller webhook certificates...'
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --version v1.17.0 --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 10m

echo 'Registering inference APIs before starting the gateway controller...'
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.5.0/v1-manifests.yaml
kubectl apply --server-side -f https://github.com/llm-d/llm-d-router/releases/download/v0.9.0/manifests.yaml
kubectl wait --for=condition=Established --timeout=120s \
  crd/gateways.gateway.networking.k8s.io \
  crd/inferencepools.inference.networking.k8s.io

# Gateway API CRDs already have an owner; select only Envoy's own CRDs.
helm show crds oci://docker.io/envoyproxy/gateway-helm --version v1.8.1 \
  | yq 'select(.spec.group == "gateway.envoyproxy.io")' \
  | kubectl apply --server-side -f -
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.8.1 --namespace envoy-gateway-system --create-namespace \
  --skip-crds --wait --timeout 10m

echo 'Adding the release-matched AI Gateway integration...'
helm upgrade --install aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm \
  --version v1.0.0 --namespace envoy-ai-gateway-system --create-namespace
helm upgrade --install aieg oci://docker.io/envoyproxy/ai-gateway-helm \
  --version v1.0.0 --namespace envoy-ai-gateway-system --wait --timeout 10m
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.8.1 --namespace envoy-gateway-system --skip-crds \
  -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/v1.0.0/manifests/envoy-gateway-values.yaml \
  -f https://raw.githubusercontent.com/envoyproxy/ai-gateway/v1.0.0/examples/inference-pool/envoy-gateway-values-addon.yaml \
  --wait --timeout 10m

# Included as an upstream dependency; our one-pod model does not use LWS.
kubectl apply --server-side -f https://github.com/kubernetes-sigs/lws/releases/download/v0.8.0/manifests.yaml
kubectl rollout status deployment/lws-controller-manager -n lws-system --timeout=5m

echo 'Installing the KServe service API and controller...'
helm upgrade --install kserve-llmisvc-crd oci://ghcr.io/kserve/charts/kserve-llmisvc-crd \
  --version v0.20.0 --namespace kserve --create-namespace --wait --timeout 10m
helm upgrade --install kserve-llmisvc-resources oci://ghcr.io/kserve/charts/kserve-llmisvc-resources \
  --version v0.20.0 --namespace kserve \
  --set kserve.llmisvc.createGIECRDs=false --wait --timeout 10m

# Runtime configs call the webhook, so wait for its certificate and new rollout.
kubectl wait --for=condition=Ready certificate/llmisvc-serving-cert -n kserve --timeout=5m
kubectl rollout restart deployment/llmisvc-controller-manager -n kserve
kubectl rollout status deployment/llmisvc-controller-manager -n kserve --timeout=5m
kubectl wait --for=jsonpath='{.subsets[0].addresses}' \
  endpoints/llmisvc-webhook-server-service -n kserve --timeout=120s
helm upgrade --install kserve-runtime-configs oci://ghcr.io/kserve/charts/kserve-runtime-configs \
  --version v0.20.0 --namespace kserve \
  --set kserve.servingruntime.enabled=false \
  --set kserve.llmisvcConfigs.enabled=true --wait --timeout 10m

# No public LoadBalancer is created for the demo gateway.
kubectl apply -f "$example_dir/platform/gateway.yaml"
kubectl wait --for=condition=Accepted gatewayclass/llm-demo-envoy --timeout=5m
kubectl wait --for=condition=Programmed gateway/kserve-ingress-gateway -n kserve --timeout=5m
echo 'Platform installed. Continue with kserve/README.md to deploy the model.'
