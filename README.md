# llm-serving-k8s

I wanted a small starting point for the ideas in [Serving LLMs on Kubernetes](https://riteshyadav.xyz/notes/inference-engineering/llm-serving-on-kubernetes): send a prompt, follow it through a proxy, and get tokens back from a GPU.

This example runs one vLLM pod and one LiteLLM pod. vLLM loads `Qwen/Qwen2.5-0.5B-Instruct`. LiteLLM exposes it as `coder`, the same alias used in the blog. The little model is here to keep the download and GPU requirements manageable, not to be a strong coding assistant.

Your request goes to LiteLLM on port 4000, then to vLLM on port 8000. The response comes back along the same path. Both Kubernetes Services are internal; a local port-forward lets you try them.

Get the example:

```sh
git clone https://github.com/DARK-art108/llm-serving-k8s.git
cd llm-serving-k8s
```

## Before you start

You need:

- A Kubernetes cluster with a free NVIDIA GPU. A Linux GPU node is needed; Docker Desktop on a Mac alone will not run this example.
- Working NVIDIA drivers, container runtime integration, and the device plugin. The node must advertise `nvidia.com/gpu`.
- A GPU and driver supported by the pinned vLLM CUDA 12.9 image. Aim for at least 8 GiB of GPU memory for this small experiment; the usable capacity still depends on the hardware and runtime.
- Enough CPU, host memory, and disk for the requests in the YAML, both images, and the model download.
- `kubectl`, `curl`, `openssl`, and outbound access to the image registries and Hugging Face.

Check which cluster you are using and whether it exposes GPUs:

```sh
kubectl config current-context
kubectl get nodes -o custom-columns='NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
```

The example uses whole GPUs and assumes the GPU node has no extra taint that blocks these pods. Add a toleration only if your cluster requires one. GPU allocation already restricts the model pod to a node advertising a GPU.

## What is in the folder?

| File | Purpose |
| --- | --- |
| `namespace.yaml` | Keeps the experiment in `llm-demo`. |
| `vllm.yaml` | One GPU-backed model server and its internal Service. |
| `config.yaml` | Maps `coder` to vLLM in LiteLLM. |
| `litellm.yaml` | The API proxy, health checks, and internal Service. |
| `kustomization.yaml` | Loads the YAML and turns `config.yaml` into a ConfigMap. |
| `request.json` | A short streaming chat request. |
| `kserve/` | A KServe learning path, from platform installation to streaming through Envoy and llm-d. |

## 1. Create the namespace and key

Run the following commands from this folder. The Secret holds a randomly generated LiteLLM admin key, so there is no password to edit into a committed YAML file.

```sh
kubectl apply -f namespace.yaml
export LITELLM_MASTER_KEY="sk-$(openssl rand -hex 24)"
kubectl create secret generic litellm-key \
  --namespace llm-demo \
  --from-literal=master-key="$LITELLM_MASTER_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Keep this terminal open. You will use the same key for the request below. This single-key setup has no database, virtual user keys, team budgets, or shared Redis state.

## 2. Start the model and proxy

You can preview the generated manifests without connecting to a cluster:

```sh
kubectl kustomize .
```

Then deploy them:

```sh
kubectl apply -k .
kubectl rollout status deployment/vllm -n llm-demo --timeout=30m
kubectl rollout status deployment/litellm -n llm-demo --timeout=5m
```

The first model startup includes a download. Watch it with:

```sh
kubectl logs -n llm-demo deployment/vllm -f
```

The server uses a 4,096-token context limit, including the prompt and output. Its scheduler processes up to eight sequences per iteration. Neither setting guarantees that any eight requests will fit in memory. The model cache uses `emptyDir`, so replacing a pod can require another download.

`Recreate` releases the existing GPU before an update starts another model pod. That makes updates possible with one free GPU, at the cost of downtime.

## 3. Ask it something

Open a second terminal and leave this running:

```sh
kubectl port-forward -n llm-demo svc/litellm 4000:4000
```

Back in the first terminal:

```sh
curl --fail-with-body --no-buffer http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  --data-binary @request.json
```

You should see streaming events containing generated text, ending with `[DONE]`. The wording will vary. A ready LiteLLM pod only means the proxy is ready; the successful chat request checks the model path too.

The admin key is just for this local experiment. The vLLM backend has no authentication, and ClusterIP does not prevent other cluster workloads from reaching it. Keep this in a development cluster and use the local port-forward.

## If it gets stuck

```sh
kubectl get pods -n llm-demo
kubectl describe pod -n llm-demo -l app=vllm
kubectl logs -n llm-demo deployment/vllm
kubectl logs -n llm-demo deployment/litellm
```

`Pending` usually means Kubernetes cannot satisfy a resource request or placement rule. Read the pod's Events for the actual reason. For a startup failure, check model downloads, host memory, CUDA compatibility, and available GPU memory. If the proxy returns 401, check the key. If it cannot reach the model, check vLLM readiness and the `api_base` in `config.yaml`.

After editing `config.yaml`, run `kubectl apply -k .` again. Kustomize changes the ConfigMap name when its contents change, which updates the proxy pod automatically. If you replace the Secret's key, restart the proxy with `kubectl rollout restart deployment/litellm -n llm-demo` so it reads the new value.

## Where the rest of the blog fits

The [KServe walkthrough](kserve/README.md) covers platform installation, a model managed by KServe, Envoy forwarding, llm-d endpoint selection, and an optional LiteLLM proxy. It uses a separate namespace and a gateway with an internal ClusterIP Service. Start with the plain example above, then move to that walkthrough to understand the surrounding serving platform.

Its [request flow diagram](kserve/README.md#follow-one-request) shows where Envoy asks the Endpoint Picker for a model pod and how generated text reaches the client.

Production serving also needs decisions about durable PostgreSQL storage, shared Redis state, public TLS, tenant access controls, monitoring, and scaling. Those remain separate exercises. Neither example creates cloud GPU nodes or configures autoscaling.

vLLM already exposes `/metrics` on port 8000 for a future Prometheus setup. Start by getting one request working before adding that stack.

Images are pinned to vLLM `v0.32.0-cu129` and LiteLLM `v1.106.4`. The standalone model uses Hugging Face revision `7ae5576`. These pins make the chosen versions explicit; they are not a claim that I have benchmarked this combination on a GPU cluster.

## Clean up

Stop the port-forward with Ctrl+C, then remove the dedicated demo namespace and its contents:

```sh
kubectl delete -k .
unset LITELLM_MASTER_KEY
```

This also removes the Secret. It does not stop or delete a cloud GPU node, so check your provider separately if you created one for the experiment.

## References

- [vLLM on Kubernetes](https://docs.vllm.ai/en/stable/deployment/k8s/)
- [vLLM v0.32.0 image variants](https://github.com/vllm-project/vllm/releases/tag/v0.32.0)
- [Qwen2.5-0.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct)
- [LiteLLM with vLLM](https://docs.litellm.ai/docs/providers/vllm)
- [LiteLLM configuration](https://docs.litellm.ai/docs/proxy/configs)
- [LiteLLM health checks](https://docs.litellm.ai/docs/proxy/health)
- [LiteLLM v1.106.4 image verification](https://github.com/BerriAI/litellm/releases/tag/v1.106.4)
- [Scheduling GPUs in Kubernetes](https://kubernetes.io/docs/tasks/manage-gpus/scheduling-gpus/)
