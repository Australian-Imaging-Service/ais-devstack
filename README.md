# Running XNAT Container Service with JVM remote debug support

## Prerequisites

Clone repo with HTTPS
```
git clone https://github.com/Australian-Imaging-Service/ais-devstack
```
Or SSH
```
git clone git@github.com:Australian-Imaging-Service/ais-devstack.git
```

### Site Setup

Check you have an xnattesting entry in your `hosts` file (`C:\Windows\System32\drivers\etc\hosts` on Windows)

```
127.0.0.1 xnattesting.local
```

If using Windows WSL, also add a TCP port proxy that listens on port 80 and forwards connections to WSL port 80.

Get WSL IP address for `eth0` in WSL terminal:
```bash
ip a show dev eth0
```

Add TCP proxy port in PowerShell admin terminal:
```powershell
netsh interface portproxy add v4tov4 listenport=80 listenaddress=0.0.0.0 connectport=80 connectaddress=<eth0_ip>
```

---

## Installation Options

Choose one of the following Kubernetes distributions:

- [Option A: MicroK8s](#option-a-microk8s)
- [Option B: k3s](#option-b-k3s)

---

### Option A: MicroK8s

1.  Install microk8s and required addons

    ```bash
    sudo snap install microk8s --classic
    sudo microk8s start
    sudo microk8s enable ingress hostpath-storage
    sudo microk8s status
    ```

2.  Add helm and kubectl aliases to bashrc

    ```bash
    # go to end ~/.bashrc and add the following entries
    alias kubectl="microk8s kubectl"
    alias k="microk8s kubectl"
    alias helm="microk8s helm"
    ```

3.  Add yourself to microk8s group

    ```bash
    sudo usermod -a -G microk8s $USER
    ```

    Close terminal and reopen to get aliases and group

4.  Install NFS server using helm chart from rcc-portals repo, add required exports

    ```bash
    kubectl create ns storage
    helm -n storage install nfs-server rcc-portals/charts/nfs-server \
      --set persistence.storageClass=microk8s-hostpath \
      --set persistence.size=1Gi
    kubectl -n storage exec deploy/nfs-server -- mkdir -p \
      /exports/xnat/data /exports/xnat/plugins
    ```

5.  Install the NFS CSI driver

    ```bash
    helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
    helm repo update
    helm -n kube-system install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
      --set kubeletDir=/var/snap/microk8s/common/var/lib/kubelet
    ```

6.  Create the XNAT namespace

    ```bash
    kubectl create ns ais-xnat
    ```

7.  Install XNAT using helm chart from ais repo and kustomize

    ```bash
    helm repo add ais https://australian-imaging-service.github.io/charts
    helm repo update
    helm -n ais-xnat install xnat-web ais/xnat --values values.yaml \
      --post-renderer ./kustomize-microk8s.sh
    ```

    Note: The provided `kustomization.yaml` disables XNAT health checks. If you need health checking, remove entries suffixed with `Probe`.

---

### Option B: k3s

1.  Install k3s with nginx ingress controller

    ```bash
    # Install k3s without Traefik (we'll use nginx instead)
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=traefik" sh -
    
    # Set up kubeconfig for current user
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $USER:$USER ~/.kube/config
    chmod 600 ~/.kube/config
    
    # Verify k3s is running
    kubectl get nodes
    ```

2.  Install nginx ingress controller

    ```bash
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.1/deploy/static/provider/cloud/deploy.yaml
    
    # Wait for ingress controller to be ready
    kubectl wait --namespace ingress-nginx \
      --for=condition=ready pod \
      --selector=app.kubernetes.io/component=controller \
      --timeout=120s
    ```

3.  Add kubectl and helm aliases to bashrc (optional)

    ```bash
    # go to end ~/.bashrc and add the following entries
    alias k="kubectl"
    ```

    Close terminal and reopen to get aliases

4.  Install NFS server using helm chart from rcc-portals repo, add required exports

    ```bash
    # Add helm repo if not already added
    helm repo add rcc-portals https://australian-imaging-service.github.io/rcc-portals
    helm repo update
    
    kubectl create ns storage
    helm -n storage install nfs-server rcc-portals/charts/nfs-server \
      --set persistence.storageClass=local-path \
      --set persistence.size=1Gi
    kubectl -n storage exec deploy/nfs-server -- mkdir -p \
      /exports/xnat/data /exports/xnat/plugins
    ```

5.  Install the NFS CSI driver

    ```bash
    helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
    helm repo update
    helm -n kube-system install csi-driver-nfs csi-driver-nfs/csi-driver-nfs
    ```

6.  Create the XNAT namespace

    ```bash
    kubectl create ns ais-xnat
    ```

7.  Install XNAT using helm chart from ais repo and kustomize

    ```bash
    helm repo add ais https://australian-imaging-service.github.io/charts
    helm repo update
    helm -n ais-xnat install xnat-web ais/xnat --values values.yaml \
      --post-renderer ./kustomize-k3s.sh
    ```

    Note: The provided `kustomization.yaml` disables XNAT health checks. If you need health checking, remove entries suffixed with `Probe`.

---

## Common Configuration

1.  Configure initial XNAT Site Setup

    | Setting      | Value                     |
    | ---          | ---                       |
    | Site URL     | http://xnattesting.local/ |
    | Enable SMTP? | Disabled                  |

2.  Configure Container Service plugin Compute Backend

    | Setting                                             | Value                      |
    | ---                                                 | ---                        |
    | Host Name                                           | pipelines                  |
    | Type                                                | Kubernetes                 |
    | Automatically clean up containers?                  | ON (OFF if debugging)      |
    | PVC Setup                                           | Separate Archive and Build |
    | Archive Directory PVC Name Build Directory PVC Name | pv-xnat-archive            |
    | Build Directory PVC Name                            | pv-xnat-build              |

3.  Add dcm2niix command under Images & Commands using [command.json](https://github.com/NrgXnat/docker-images/blob/master/dcm2niix/command.json)

4.  Enable dcm2niix command under Command Configurations

5.  Create test projects proj\_1 AND proj\_2, open project settings and set dcm2niix command to Enabled
