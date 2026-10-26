# Install the platform for the lab

There are two things to deploy: the platform controllers and your model. The platform comes first. It teaches Kubernetes about resources such as `LLMInferenceService` and `InferencePool`, then runs the controllers that act on them.

This installation is for a fresh, disposable development cluster. It creates cluster-wide APIs and uses `cert-manager`, `envoy-gateway-system`, `envoy-ai-gateway-system`, `lws-system`, and `kserve`. You need cluster-admin permissions, a compatible NVIDIA GPU node, and additional capacity for the controllers. The installer does not provision infrastructure or NVIDIA software.

Install Helm 3 and [Mike Farah yq v4](https://github.com/mikefarah/yq) on the machine running the commands. Your `kubectl` version should be compatible with the cluster. A different program named `yq` will not work here.

## Read the commands before running them

From the repository root:

```sh
kubectl config current-context
less kserve/install-platform.sh
bash kserve/install-platform.sh
```

The versions follow KServe v0.20.0's release installer: cert-manager v1.17.0, Gateway API v1.5.1, Inference Extension v1.5.0, llm-d router CRDs v0.9.0, Envoy Gateway v1.8.1, Envoy AI Gateway v1.0.0, LeaderWorkerSet v0.8.0, and KServe v0.20.0. Model and EPP images are versioned separately in the release's runtime templates.

The order matters: register inference APIs before starting the gateway controller; install the KServe API and controller; wait for the webhook certificate and controller rollout; then install runtime configurations. Otherwise an apply can fail because a resource kind is unknown or its validating webhook is not ready.

We set `kserve.llmisvc.createGIECRDs=false` because the script already installs inference CRDs. They have one owner, avoiding a second Helm release trying to adopt them.

LeaderWorkerSet is an upstream platform dependency; this one-pod model does not use distributed execution. The AI Gateway integration is installed, but the example does not configure provider API conversion or token budgets.

## Check the result

```sh
kubectl get deployments -n kserve
kubectl get deployments -n envoy-gateway-system
kubectl get deployments -n envoy-ai-gateway-system
kubectl get llminferenceserviceconfigs -n kserve
kubectl get gatewayclass llm-demo-envoy
kubectl get gateway kserve-ingress-gateway -n kserve
```

The controllers should be available, runtime configurations should exist, and the Gateway should become `Programmed=True`. No model has been deployed yet. Continue with [README.md](README.md).

## Existing platforms and interrupted installs

Do not run this installer against a shared installation. It refuses the known platform namespaces and CRDs. Ask the owner to check component versions, runtime templates, inference extension support, and gateway policy against this lab.

Our model references `kserve/kserve-ingress-gateway`. On a compatible platform, either provide the lab gateway from [platform/gateway.yaml](platform/gateway.yaml), or update the model's gateway reference and route configuration to the gateway you may use. The discovery commands and request URL assume the lab configuration.

If installation fails partway, inspect the failing command and Helm release. The initial guard rejects a second whole-script run because namespaces now exist. Resolve the failure and resume the remaining commands deliberately, or recreate the disposable cluster. There is no automatic uninstall or forced replacement of partial resources.

## Check the installer without a cluster

The installer also has offline checks that use fake command-line tools. They verify refusal of existing platforms, failure handling, and dependency order without connecting to a cluster:

```sh
python3 -m unittest discover -s tests -v
```

These tests do not establish that real controllers or GPU workloads start successfully.

## Remove the platform

Deleting the model namespace only removes the example application. It leaves the controllers and cluster-wide APIs. For a disposable cluster created for this lab, deleting that cluster through its provider is the cleanest full teardown. On a shared cluster, leave platform removal to its owner. Application cleanup never deletes shared CRDs.
