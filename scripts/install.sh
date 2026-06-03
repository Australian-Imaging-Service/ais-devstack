#!/bin/bash
# AIS-XNAT Installation Script for k3s
# This script installs XNAT on a k3s cluster
set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"

# Create values.yaml from templates if they don't exist
if [ ! -f "$BASE_DIR/manifests/values.yaml" ]; then
    if [ -f "$BASE_DIR/manifests/values.yaml.template" ]; then
        cp "$BASE_DIR/manifests/values.yaml.template" "$BASE_DIR/manifests/values.yaml"
        echo "Created manifests/values.yaml from template"
    else
        echo -e "${RED}Error: manifests/values.yaml.template not found${NC}"
        exit 1
    fi
fi

if [ ! -f "$BASE_DIR/nfs-server/values.yaml" ]; then
    if [ -f "$BASE_DIR/nfs-server/values.yaml.template" ]; then
        cp "$BASE_DIR/nfs-server/values.yaml.template" "$BASE_DIR/nfs-server/values.yaml"
        echo "Created nfs-server/values.yaml from template"
    else
        echo -e "${RED}Error: nfs-server/values.yaml.template not found${NC}"
        exit 1
    fi
fi

echo -e "${BLUE}"
echo "=========================================="
echo "   AIS-XNAT Installation (k3s)"
echo "=========================================="
echo -e "${NC}"

# Function to check if command succeeded
check_status() {
    if [ $1 -eq 0 ]; then
        echo -e "${GREEN}Done${NC}"
    else
        echo -e "${RED}Failed${NC}"
        exit 1
    fi
}

# Step 1: Install k3s (if not already installed)
echo -e "${BLUE}[Step 1/9] Installing k3s...${NC}"
if command -v kubectl &> /dev/null && kubectl get nodes &> /dev/null; then
    echo -e "${GREEN}k3s is already running${NC}"
else
    echo "Installing k3s WITHOUT Traefik (using nginx ingress instead)..."
    echo "Note: Disabling Traefik to avoid conflicts with nginx ingress controller"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -s - --disable=traefik

    # Wait for k3s to be ready
    echo "Waiting for k3s to start..."
    sleep 10

    # Setup kubeconfig
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $USER:$USER ~/.kube/config
    export KUBECONFIG=~/.kube/config

    # Verify k3s is running
    if kubectl get nodes &> /dev/null; then
        echo -e "${GREEN}k3s installed and running (Traefik disabled)${NC}"
    else
        echo -e "${RED}k3s installation failed${NC}"
        exit 1
    fi
fi

# Step 2: Install Helm (if not already installed)
echo -e "${BLUE}[Step 2/9] Installing Helm...${NC}"
if command -v helm &> /dev/null; then
    echo -e "${GREEN}Helm is already installed${NC}"
else
    echo "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    check_status $?
fi

# Verify prerequisites
echo ""
echo -e "${BLUE}[Pre-flight Checks]${NC}"
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl not found${NC}"
    exit 1
fi
echo -e "${GREEN}kubectl found${NC}"

if ! command -v helm &> /dev/null; then
    echo -e "${RED}helm not found${NC}"
    exit 1
fi
echo -e "${GREEN}helm found${NC}"

if ! kubectl get nodes &> /dev/null; then
    echo -e "${RED}Cannot connect to k3s cluster${NC}"
    exit 1
fi
echo -e "${GREEN}k3s cluster accessible${NC}"
echo ""

# Configuration Review
echo -e "${BLUE}=========================================="
echo "   Configuration Review"
echo "==========================================${NC}"
echo ""

# Extract current values
VALUES_FILE="$BASE_DIR/manifests/values.yaml"
NFS_VALUES_FILE="$BASE_DIR/nfs-server/values.yaml"

CURRENT_HOST=$(grep -A1 "hosts:" "$VALUES_FILE" | grep "host:" | head -1 | awk '{print $3}')
CURRENT_SITE_URL=$(grep "siteUrl:" "$VALUES_FILE" | head -1 | sed 's/.*siteUrl: *"\(.*\)"/\1/')
CURRENT_DB_PASSWORD=$(grep -A5 "postgresql:" "$VALUES_FILE" | grep "password:" | head -1 | awk '{print $2}')
CURRENT_NFS_SIZE=$(grep "size:" "$NFS_VALUES_FILE" | awk '{print $2}')

echo -e "${YELLOW}Current Configuration:${NC}"
echo "  1. Ingress Host:     $CURRENT_HOST"
echo "  2. Site URL:         $CURRENT_SITE_URL"
echo "  3. DB Password:      $CURRENT_DB_PASSWORD"
echo "  4. NFS Storage Size: $CURRENT_NFS_SIZE"
echo ""

read -p "Do you want to modify these settings? (y/N): " modify_config
if [[ "$modify_config" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${BLUE}Enter new values (press Enter to keep current):${NC}"
    echo ""

    # Ingress Host
    read -p "Ingress Host [$CURRENT_HOST]: " NEW_HOST
    NEW_HOST=${NEW_HOST:-$CURRENT_HOST}

    # Site URL
    DEFAULT_SITE_URL="http://$NEW_HOST"
    read -p "Site URL [$DEFAULT_SITE_URL]: " NEW_SITE_URL
    NEW_SITE_URL=${NEW_SITE_URL:-$DEFAULT_SITE_URL}

    # DB Password
    read -p "PostgreSQL Password [$CURRENT_DB_PASSWORD]: " NEW_DB_PASSWORD
    NEW_DB_PASSWORD=${NEW_DB_PASSWORD:-$CURRENT_DB_PASSWORD}

    # NFS Size
    read -p "NFS Storage Size [$CURRENT_NFS_SIZE]: " NEW_NFS_SIZE
    NEW_NFS_SIZE=${NEW_NFS_SIZE:-$CURRENT_NFS_SIZE}

    echo ""
    echo -e "${BLUE}Updating configuration files...${NC}"

    # Update values.yaml - Ingress host
    if [ "$NEW_HOST" != "$CURRENT_HOST" ]; then
        sed -i "s/host: $CURRENT_HOST/host: $NEW_HOST/g" "$VALUES_FILE"
        echo "  Updated ingress host to: $NEW_HOST"
    fi

    # Update values.yaml - Site URL
    if [ "$NEW_SITE_URL" != "$CURRENT_SITE_URL" ]; then
        sed -i "s|siteUrl: \"$CURRENT_SITE_URL\"|siteUrl: \"$NEW_SITE_URL\"|g" "$VALUES_FILE"
        echo "  Updated site URL to: $NEW_SITE_URL"
    fi

    # Update values.yaml - DB Password
    if [ "$NEW_DB_PASSWORD" != "$CURRENT_DB_PASSWORD" ]; then
        sed -i "s/password: $CURRENT_DB_PASSWORD/password: $NEW_DB_PASSWORD/g" "$VALUES_FILE"
        echo "  Updated DB password"
    fi

    # Update nfs-server values.yaml - Size
    if [ "$NEW_NFS_SIZE" != "$CURRENT_NFS_SIZE" ]; then
        sed -i "s/size: $CURRENT_NFS_SIZE/size: $NEW_NFS_SIZE/g" "$NFS_VALUES_FILE"
        echo "  Updated NFS storage size to: $NEW_NFS_SIZE"
    fi

    echo -e "${GREEN}Configuration updated${NC}"
fi

echo ""
read -p "Proceed with installation? (Y/n): " proceed
if [[ "$proceed" =~ ^[Nn]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi
echo ""

# Step 3: Install NGINX Ingress Controller
echo -e "${BLUE}[Step 3/9] Installing NGINX Ingress Controller...${NC}"
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update

# Install nginx ingress (XNAT requires nginx-specific annotations for large file uploads)
# Note: Don't use --wait as admission webhook jobs can cause timeouts
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.publishService.enabled=true

# Wait for the controller pod only (not webhook jobs)
echo "Waiting for ingress controller pod..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/component=controller -n ingress-nginx --timeout=300s
check_status $?

# Step 4: Install NFS CSI Driver
echo -e "${BLUE}[Step 4/9] Installing NFS CSI Driver...${NC}"
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts 2>/dev/null || true
helm repo update

# k3s kubelet path is /var/lib/kubelet (standard path)
helm upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --namespace kube-system \
  --set kubeletDir=/var/lib/kubelet

# Wait for CSI driver pods
echo "Waiting for NFS CSI driver pods..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=csi-driver-nfs -n kube-system --timeout=120s
check_status $?

# Step 5: Create storage namespace and install NFS server
echo -e "${BLUE}[Step 5/9] Setting up NFS Server...${NC}"
kubectl create namespace storage 2>/dev/null || echo "Namespace 'storage' already exists"

# Check if nfs-server helm chart exists locally
if [ -f "$BASE_DIR/nfs-server/Chart.yaml" ] || [ -d "$BASE_DIR/nfs-server" ]; then
    helm upgrade --install nfs-server "$BASE_DIR/nfs-server" \
      --namespace storage \
      --values "$BASE_DIR/nfs-server/values.yaml"
else
    echo -e "${YELLOW}NFS server chart not found at $BASE_DIR/nfs-server${NC}"
    echo "Please ensure you have the nfs-server helm chart"
    echo "You can extract it from: tar -xzf nfs-server-0.1.0.tgz"
    exit 1
fi

# Wait for NFS server pod to be ready
echo "Waiting for NFS server pod to be ready..."
kubectl wait --for=condition=ready pod -l app=nfs-server -n storage --timeout=300s
check_status $?

# Create NFS directories
echo "Creating NFS export directories..."
kubectl -n storage exec deploy/nfs-server -- mkdir -p \
  /exports/gpfs /exports/xnat/data/build /exports/xnat/plugins
check_status $?

# Copy plugins to NFS server
echo "Copying plugins to NFS server..."
PLUGINS_DIR="$BASE_DIR/plugins"
if [ -d "$PLUGINS_DIR" ] && [ "$(ls -A $PLUGINS_DIR/*.jar 2>/dev/null)" ]; then
    NFS_POD=$(kubectl -n storage get pods -l app=nfs-server -o jsonpath='{.items[0].metadata.name}')
    for plugin in "$PLUGINS_DIR"/*.jar; do
        plugin_name=$(basename "$plugin")
        echo "  Copying $plugin_name..."
        kubectl -n storage cp "$plugin" "$NFS_POD:/exports/xnat/plugins/$plugin_name"
    done
    check_status $?
else
    echo -e "${YELLOW}No plugins found in $PLUGINS_DIR${NC}"
fi

# Step 6: Create XNAT namespace
echo -e "${BLUE}[Step 6/9] Creating XNAT namespace...${NC}"
kubectl create namespace ais-xnat 2>/dev/null || echo "Namespace 'ais-xnat' already exists"
check_status $?

# Step 7: Apply PVs, PVCs, and ConfigMap
echo -e "${BLUE}[Step 7/9] Applying Kubernetes manifests...${NC}"
kubectl apply -f "$BASE_DIR/manifests/pv.yaml"
kubectl apply -f "$BASE_DIR/manifests/pvc.yaml"
kubectl apply -f "$BASE_DIR/manifests/configmap.yaml"
check_status $?

# Step 8: Add AIS Helm repo
echo -e "${BLUE}[Step 8/9] Adding AIS Helm repository...${NC}"
helm repo add ais https://australian-imaging-service.github.io/charts 2>/dev/null || true
helm repo update
check_status $?

# Step 9: Install XNAT
echo -e "${BLUE}[Step 9/9] Installing XNAT...${NC}"
chmod +x "$BASE_DIR/manifests/kustomize.sh"
helm upgrade --install xnat-web ais/xnat \
  --namespace ais-xnat \
  --values "$BASE_DIR/manifests/values.yaml" \
  --post-renderer "$BASE_DIR/manifests/kustomize.sh"

# Wait for XNAT pod to be ready (this can take several minutes)
echo "Waiting for XNAT pod to be ready (this may take several minutes)..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=xnat-web -n ais-xnat --timeout=900s
check_status $?

# Step 10: Enable configured authentication providers
echo -e "${BLUE}[Step 10] Enabling authentication providers...${NC}"
# Extract configured OpenID provider IDs from values.yaml
OPENID_PROVIDERS=$(grep -A2 "openid-auth-plugin:" "$VALUES_FILE" | grep -v "^--" | head -5)
if grep -q "openid-auth-plugin" "$VALUES_FILE" 2>/dev/null; then
    # Get provider IDs from the openid-auth-plugin config
    PROVIDER_IDS=$(grep "id:" "$VALUES_FILE" | grep -A0 -B5 "openid\|auth.*method" | awk '{print $2}' | head -5)
    # More reliable: extract provider.id values from the openid section
    PROVIDER_IDS=$(awk '/openid-auth-plugin:/,/^  [^ ]/' "$VALUES_FILE" | grep "id:" | awk '{print $2}')
    if [ -n "$PROVIDER_IDS" ]; then
        echo "Found OpenID providers: $PROVIDER_IDS"
        # Wait for PostgreSQL to be ready
        kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=xnat-web-postgresql -n ais-xnat --timeout=120s 2>/dev/null || true
        PG_POD=$(kubectl -n ais-xnat get pods -l app.kubernetes.io/name=xnat-web-postgresql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        DB_PASSWORD=$(grep -A3 "^global:" "$VALUES_FILE" | grep "password:" | head -1 | awk '{print $2}')
        if [ -n "$PG_POD" ] && [ -n "$DB_PASSWORD" ]; then
            # Build the enabled providers list: ['localdb','provider1','provider2',...]
            ENABLED_LIST="['localdb'"
            for pid in $PROVIDER_IDS; do
                ENABLED_LIST="${ENABLED_LIST},'${pid}'"
            done
            ENABLED_LIST="${ENABLED_LIST}]"
            echo "Setting enabledProviders to: $ENABLED_LIST"
            # Update or wait for the preference to exist (XNAT creates it on first startup)
            for attempt in 1 2 3 4 5; do
                CURRENT=$(kubectl -n ais-xnat exec "$PG_POD" -- bash -c "PGPASSWORD='$DB_PASSWORD' psql -U xnat -d xnat -t -c \"SELECT value FROM xhbm_preference WHERE name='enabledProviders';\"" 2>/dev/null | tr -d ' ')
                if [ -n "$CURRENT" ]; then
                    if echo "$CURRENT" | grep -q "$( echo $PROVIDER_IDS | awk '{print $1}')"; then
                        echo -e "${GREEN}Providers already enabled: $CURRENT${NC}"
                    else
                        # Use a Java helper to avoid shell quoting issues with SQL
                        XNAT_POD=$(kubectl -n ais-xnat get pods -l app.kubernetes.io/name=xnat-web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
                        kubectl -n ais-xnat exec "$XNAT_POD" -c xnat-web -- bash -c "cat > /tmp/EnableProviders.java << 'JAVA'
import java.sql.*;
public class EnableProviders {
    public static void main(String[] args) throws Exception {
        Connection conn = DriverManager.getConnection(args[0], args[1], args[2]);
        PreparedStatement ps = conn.prepareStatement(\"UPDATE xhbm_preference SET value=? WHERE name='enabledProviders'\");
        ps.setString(1, args[3]);
        int rows = ps.executeUpdate();
        System.out.println(\"Updated enabledProviders (\" + rows + \" rows): \" + args[3]);
        conn.close();
    }
}
JAVA
cd /tmp && javac -cp '/usr/local/tomcat/webapps/ROOT/WEB-INF/lib/*:/usr/local/tomcat/webapps/ROOT/WEB-INF/classes' EnableProviders.java && java -cp '.:/usr/local/tomcat/webapps/ROOT/WEB-INF/lib/*:/usr/local/tomcat/webapps/ROOT/WEB-INF/classes' EnableProviders 'jdbc:postgresql://xnat-web-postgresql/xnat' 'xnat' '$DB_PASSWORD' '$ENABLED_LIST'" 2>/dev/null
                        if [ $? -eq 0 ]; then
                            echo -e "${GREEN}Authentication providers enabled. Restarting XNAT to apply...${NC}"
                            kubectl -n ais-xnat delete pod "$XNAT_POD" 2>/dev/null
                            echo "Waiting for XNAT to restart..."
                            sleep 10
                            kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=xnat-web -n ais-xnat --timeout=900s
                        else
                            echo -e "${YELLOW}Warning: Could not update enabledProviders automatically.${NC}"
                            echo "You may need to enable the provider manually in XNAT Admin > Site Administration."
                        fi
                    fi
                    break
                else
                    echo "Waiting for XNAT database initialization (attempt $attempt/5)..."
                    sleep 30
                fi
            done
        fi
    fi
fi

echo ""
echo -e "${GREEN}=========================================="
echo "   XNAT Installation Complete!"
echo "==========================================${NC}"
echo ""
echo "Monitor XNAT startup:"
echo "  kubectl -n ais-xnat get pods -w"
echo ""
echo "Port forward to access XNAT locally:"
echo "  kubectl -n ais-xnat port-forward svc/xnat-web 8080:80"
echo "  Then open: http://localhost:8080"
echo ""
echo "Default admin credentials: admin / admin"
echo ""
# Get the final configured host
FINAL_HOST=$(grep -A1 "hosts:" "$VALUES_FILE" | grep "host:" | head -1 | awk '{print $3}')
echo "Ingress URL (if DNS configured):"
echo "  http://$FINAL_HOST"
echo ""

# Prompt for JupyterHub installation
echo -e "${BLUE}=========================================="
echo "   Optional: JupyterHub Integration (neurodesk chart)"
echo "==========================================${NC}"
echo ""
echo "JupyterHub provides interactive Jupyter notebooks integrated with XNAT."
echo "It is now installed by the consolidated jupyterhub/INSTALL.sh flow:"
echo "  Longhorn + NFS workspace + monitoring (infra) -> the single neurodesk"
echo "  Helm chart (JupyterHub + CVMFS + smarter-device-manager + Security"
echo "  Profiles Operator + AppArmor + the XNAT notebook upload extension)."
echo ""
JH_DIR="$BASE_DIR/jupyterhub"
JH_INSTALL="$JH_DIR/INSTALL.sh"
JH_VALUES="$JH_DIR/neurodesk/values-devstack.yaml"
JH_TEMPLATE="$JH_DIR/neurodesk/values-devstack.yaml.template"
read -p "Install JupyterHub now? (y/N): " install_jupyterhub
if [[ "$install_jupyterhub" =~ ^[Yy]$ ]]; then
    if [ ! -f "$JH_VALUES" ]; then
        echo ""
        echo -e "${YELLOW}JupyterHub needs its values file (with your secrets) first:${NC}"
        echo "  cp $JH_TEMPLATE \\"
        echo "     $JH_VALUES"
        echo "  # then edit it: OIDC client_id/secret, xnat-service apiToken, JUPYTERHUB_CRYPT_KEY_HEX"
        echo ""
        read -p "Continue without it (the installer will stop until it exists)? (y/N): " cont
        [[ "$cont" =~ ^[Yy]$ ]] || { echo "Create the values file, then run: cd jupyterhub && ./INSTALL.sh"; exit 0; }
    fi
    echo ""
    chmod +x "$JH_INSTALL"
    (cd "$JH_DIR" && ./INSTALL.sh)
else
    echo ""
    echo "You can install JupyterHub later:"
    echo "  cd $JH_DIR"
    echo "  cp neurodesk/values-devstack.yaml.template neurodesk/values-devstack.yaml   # fill in secrets"
    echo "  ./INSTALL.sh"
    echo ""
fi
