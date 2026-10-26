# Put LiteLLM in front of the KServe gateway

First send the direct request in [the KServe walkthrough](../README.md). That establishes that the model, route, gateway, and Endpoint Picker work together. Now add LiteLLM without starting another model server.

Run these commands from the repository root. This proxy uses `llm-kserve-demo`, separately from the original example in `llm-demo`.

## 1. Find an address the proxy can reach

`localhost:8080` works on your laptop because of its port-forward. Inside LiteLLM's pod, `localhost` would mean that pod itself. It needs Envoy's Kubernetes Service address instead.

```sh
export ENVOY_SERVICE=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-namespace=kserve,gateway.envoyproxy.io/owning-gateway-name=kserve-ingress-gateway \
  -o jsonpath='{.items[0].metadata.name}')
test -n "$ENVOY_SERVICE"
export KSERVE_API_BASE="http://${ENVOY_SERVICE}.envoy-gateway-system.svc.cluster.local/llm-kserve-demo/coder/v1"
kubectl create configmap kserve-endpoint -n llm-kserve-demo \
  --from-literal=api-base="$KSERVE_API_BASE" \
  --dry-run=client -o yaml | kubectl apply -f -
```

The URL ends with `/v1`. LiteLLM adds `/chat/completions`. The example assumes the usual `cluster.local` DNS domain; adjust it if your cluster uses another domain.

## 2. Create the proxy key and deploy it

```sh
export LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)"
kubectl create secret generic litellm-key -n llm-kserve-demo \
  --from-literal=master-key="$LITELLM_MASTER_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k kserve/litellm
kubectl rollout status deployment/litellm -n llm-kserve-demo --timeout=5m
```

The Deployment reads its key from the Secret and its gateway address from the ConfigMap. `config.yaml` maps the public alias `coder` to that endpoint. This pod loads no model weights and requests no GPU.

## 3. Send the same prompt through LiteLLM

In another terminal, run:

```sh
kubectl port-forward -n llm-kserve-demo svc/litellm 4001:4000
```

Local port 4001 lets the original example keep using 4000. Back in the terminal containing your key:

```sh
curl --fail-with-body --no-buffer http://127.0.0.1:4001/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H 'Content-Type: application/json' \
  --data-binary @kserve/request.json
```

The answer should stream through LiteLLM. An incorrect key should be rejected by the proxy. If the direct Envoy request works but this one fails, check the proxy logs and configured gateway address:

```sh
kubectl logs deployment/litellm -n llm-kserve-demo --tail=100
kubectl get configmap kserve-endpoint -n llm-kserve-demo -o yaml
```

After replacing the key or endpoint ConfigMap, restart the proxy so its environment variables are refreshed:

```sh
kubectl rollout restart deployment/litellm -n llm-kserve-demo
```

This is a single-key learning example. It has no PostgreSQL-backed virtual keys, Redis-backed shared limits, or tenant budgets. The internal gateway is also reachable by permitted cluster workloads, so this is not a tenant-isolation design.

## Remove just the proxy

Stop its port-forward, then run:

```sh
kubectl delete -k kserve/litellm --ignore-not-found
kubectl delete configmap/kserve-endpoint secret/litellm-key -n llm-kserve-demo --ignore-not-found
unset LITELLM_MASTER_KEY KSERVE_API_BASE ENVOY_SERVICE
```

The model remains reachable through Envoy. To remove it too, follow the cleanup commands in the KServe walkthrough.
