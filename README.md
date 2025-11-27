## Running XNAT Container Service on microk8s with JVM remote debug support

1.  Install microk8s and required addons

    ```
    sudo snap install microk8s --classic
    sudo microk8s start
    sudo microk8s enable ingress hostpath-storage
    sudo microk8s status
    ```

2.  Add helm and kubectl aliases to bashrc

    ```
    # go to end ~/.bashrc and add the following entries
    alias kubectl="microk8s kubectl"
    alias k="microk8s kubectl"
    alias helm="microk8s helm"
    ```

3.  Add yourself to microk8s group

    ```
    sudo usermod -a -G microk8s $USER
    ```

    Close terminal and reopen to get aliases and group

4.  Check you have an xnattesting entry in your `hosts` file
    (`C:\Windows\System32\drivers\etc\hosts` on Windows)

    ```
    127.0.0.1 xnattesting.local
    ```

    If using Windows WSL, also add a TCP port proxy that listens on port 80 and
    forwards connections to WSL port 80

    Get WSL IP address for `eth0` in WSL terminal

    ```
    ip a show dev eth0
    ```

    Add TCP proxy port in PowerShell admin terminal

    ```
    netsh interface portproxy add v4tov4 listenport=80 listenaddress=0.0.0.0 connectport=80 connectaddress=<eth0_ip>
    ```

5.  Install NFS server using helm chart from rcc-portals repo, add required
    exports

    ```
    kubectl create ns storage
    helm -n storage install nfs-server rcc-portals/charts/nfs-server \
      --set persistence.storageClass=microk8s-hostpath \
      --set persistence.size=1Gi
    kubectl -n storage exec deploy/nfs-server -- mkdir -p \
      /exports/xnat/data /exports/xnat/plugins
    ```

6.  Install the NFS CSI driver

    ```
    helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
    helm repo update
    helm -n kube-system install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
      --set kubeletDir=/var/snap/microk8s/common/var/lib/kubelet
    ```

7.  Create the XNAT namespace

    ```
    kubectl create ns ais-xnat
    ```

8.  Install XNAT using helm chart from ais repo and kustomize

    ```
    helm repo add ais https://australian-imaging-service.github.io/charts
    helm repo update
    helm -n ais-xnat install xnat-web ais/xnat --values values.yaml \
      --post-renderer ./kustomize.sh
    ```

    Note the provided `kustomization.yaml` disables XNAT health checks.  If you
    need health checking, remove entries suffixed with `Probe`

9.  Configure initial XNAT Site Setup

    | Setting      | Value                     |
    | ---          | ---                       |
    | Site URL     | http://xnattesting.local/ |
    | Enable SMTP? | Disabled                  |

10. Configure Container Service plugin Compute Backend

    | Setting                                             | Value                      |
    | ---                                                 | ---                        |
    | Host Name                                           | pipelines                  |
    | Type                                                | Kubernetes                 |
    | Automatically clean up containers?                  | ON (OFF if debugging)      |
    | PVC Setup                                           | Separate Archive and Build |
    | Archive Directory PVC Name Build Directory PVC Name | pv-xnat-archive            |
    | Build Directory PVC Name                            | pv-xnat-build              |

11. Add dcm2niix command under Images & Commands using
    [command.json](https://github.com/NrgXnat/docker-images/blob/master/dcm2niix/command.json)

12. Enable dcm2niix command under Command Configurations

13. Create test projects proj\_1 AND proj\_2, open project settings and set
    dcm2niix command to Enabled
