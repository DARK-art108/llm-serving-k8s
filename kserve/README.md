# Try KServe next

The first example lets you see vLLM and LiteLLM working together. This file is the next step: ask KServe to manage the model workload and its inference router.

It follows the KServe 0.20 `LLMInferenceService` API used in the blog. You need an existing KServe installation with its runtime configuration, Gateway API, Inference Extension, and an inference-capable gateway controller configured. Follow the [LLMInferenceService installation guide](https://kserve.github.io/website/docs/install/llmisvc-install) for the release you install. Installing these controllers is separate from deploying this model.

With `gateway: {}`, `route: {}`, and `scheduler: {}`, KServe manages the gateway, route, inference pool, and Endpoint Picker resources using the platform's defaults. Choose Envoy Gateway in the platform setup to follow the blog's gateway choice. This does not install the separate Envoy AI Gateway processor or enable every llm-d routing plugin.

## Start with a free GPU

Run these commands from the parent example folder. If you already ran the plain example, remove it first so the two model servers do not compete for the same GPU:

```sh
kubectl delete -k . --ignore-not-found
kubectl wait --for=delete namespace/llm-demo --timeout=5m
kubectl apply -f namespace.yaml
kubectl apply -f kserve/coder.yaml
kubectl get llminferenceservice coder -n llm-demo -w
```

Deleting the plain example also deletes its dedicated namespace and Secret. The wait command lets deletion finish before recreating it. Skip the delete and wait commands if you have not deployed it.

The runtime image, download settings, and context limit come from the installed KServe configuration. Unlike the standalone example, this small service spec does not pin a model revision or override those defaults. Check them before running it. The `nvidia.com/gpu` limit requests one GPU.

## Send a request

Inspect the generated routing configuration:

```sh
kubectl get llminferenceservice coder -n llm-demo -o yaml
kubectl get gateway,httproute -n llm-demo
kubectl get svc -A
```

Use the URL and path reported by the service, or port-forward the generated gateway's Service. Its namespace and name depend on the gateway controller. Replace both placeholders below with the values from your cluster:

```sh
kubectl port-forward -n <gateway-namespace> svc/<gateway-service> 8080:80
```

In another terminal, send `request.json` to the route's chat completions URL. If the route matches a hostname, include that hostname in the `Host` header when testing through the port-forward. Check any route path prefix too. Do not assume all platforms expose the same URL.

Once that works, LiteLLM can sit in front of this gateway. Set `api_base` in the parent `config.yaml` to the gateway URL reachable **from inside the cluster**, including the route prefix and `/v1`. Reuse the LiteLLM manifests and create its Secret as described in the parent README. Do not redeploy the parent's `vllm.yaml`.

For the additional AI API processing layer, follow the [KServe Envoy AI Gateway integration](https://kserve.github.io/website/docs/model-serving/generative-inference/llmisvc/llmisvc-envoy-ai-gateway). It needs compatible component versions and more configuration than this first example.

## Remove it

```sh
kubectl delete -f kserve/coder.yaml
kubectl delete -f namespace.yaml
```

This removes the demo service and namespace. Shared platform controllers stay installed.
