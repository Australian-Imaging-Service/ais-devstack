### Using NVIDIA GPU operator

For deployments using GPU operator

1.  Add the NVIDIA Helm repository

    ```
    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
    helm repo update
    ```

2.  Install the GPU Operator

    ```
    helm -n gpu-operator install --create-namespace --wait gpu-operator nvidia/gpu-operator --version=v26.3.1
    ```

### GPU operator MIG profile

To set the required MIG profile

1.  List the available MIG profiles

    ```
    kubectl -n gpu-operator exec -it nvidia-driver-daemonset-<id> -n gpu-operator -- nvidia-smi mig -lgip
    ```

2.  Check current node names and labels, eg.

    ```
    kubectl get node -o json | jq '.items[].metadata |{"name":.name,"labels":.labels}' |grep -E "nvidia.com/(gpu.count|mig.config)"
      "nvidia.com/gpu.count": "4",
      "nvidia.com/mig.config": "all-1g.10gb",
      "nvidia.com/mig.config.state": "success",
    ```

3.  If needed, add node label for required profile, eg.

    ```
    kubectl label node <gpu_node_1> nvidia.com/mig.config=all-1g.10gb --overwrite
    ```

    Confirm `mig.config.state` and `gpu.count`

    ```
    kubectl get node -o json | jq '.items[].metadata |{"name":.name,"labels":.labels}' |grep -E "nvidia.com/(gpu.count|mig.config)"
    ```

4.  Test using cuda-vector-add pod

    ```
    kubectl apply -f - <<EOF
    apiVersion: v1
    kind: Pod
    metadata:
      name: cuda-vector-add
    spec:
      restartPolicy: OnFailure
      containers:
      - name: cuda-vector-add
        image: "k8s.gcr.io/cuda-vector-add:v0.1"
        resources:
          limits:
            nvidia.com/gpu: 1
    EOF
    kubectl logs -f pods/cuda-vector-add
    ...
    Test PASSED
    Done
    kubectl delete pods/cuda-vector-add
    ```
