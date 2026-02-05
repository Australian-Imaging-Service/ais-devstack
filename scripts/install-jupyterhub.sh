#!/bin/bash
# JupyterHub Installation Script
# Orchestrates JupyterHub installation using config from ais-devstack
set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
JUPYTERHUB_DIR="$BASE_DIR/hub"
VALUES_FILE="$BASE_DIR/manifests/values.yaml"
JUPYTERHUB_VALUES_TEMPLATE="$JUPYTERHUB_DIR/5-jupyterhub-values.yaml.template"
JUPYTERHUB_VALUES="$JUPYTERHUB_DIR/5-jupyterhub-values.yaml"

echo -e "${BLUE}"
echo "=========================================="
echo "   JupyterHub Installation"
echo "=========================================="
echo -e "${NC}"

# Check prerequisites
echo -e "${BLUE}[Pre-flight Checks]${NC}"

# Check XNAT values file exists
if [ ! -f "$VALUES_FILE" ]; then
    echo -e "${RED}XNAT values.yaml not found at $VALUES_FILE${NC}"
    echo "Please run install.sh first to setup XNAT"
    exit 1
fi
echo -e "${GREEN}XNAT config found${NC}"

# Check JupyterHub directory exists
if [ ! -d "$JUPYTERHUB_DIR" ]; then
    echo -e "${RED}JupyterHub directory not found at $JUPYTERHUB_DIR${NC}"
    exit 1
fi
echo -e "${GREEN}JupyterHub directory found${NC}"

# Create values.yaml from template if it doesn't exist
if [ ! -f "$JUPYTERHUB_VALUES" ]; then
    if [ -f "$JUPYTERHUB_VALUES_TEMPLATE" ]; then
        cp "$JUPYTERHUB_VALUES_TEMPLATE" "$JUPYTERHUB_VALUES"
        echo -e "${GREEN}Created jupyterhub/5-jupyterhub-values.yaml from template${NC}"
    else
        echo -e "${RED}Error: $JUPYTERHUB_VALUES_TEMPLATE not found${NC}"
        exit 1
    fi
else
    echo -e "${GREEN}JupyterHub values.yaml found${NC}"
fi

# Check kubectl access
if ! kubectl get nodes &> /dev/null; then
    echo -e "${RED}Cannot connect to Kubernetes cluster${NC}"
    exit 1
fi
echo -e "${GREEN}Kubernetes cluster accessible${NC}"

# Check XNAT is running
if ! kubectl get pods -n ais-xnat -l app.kubernetes.io/name=xnat-web 2>/dev/null | grep -q Running; then
    echo -e "${RED}XNAT is not running${NC}"
    echo "Please ensure XNAT is deployed and running first"
    exit 1
fi
echo -e "${GREEN}XNAT is running${NC}"

# Check NFS server is running
if ! kubectl get pods -n storage -l app=nfs-server 2>/dev/null | grep -q Running; then
    echo -e "${YELLOW}Warning: NFS server may not be running${NC}"
else
    echo -e "${GREEN}NFS server is running${NC}"
fi

echo ""

# Read domain from XNAT config
DOMAIN=$(grep -A1 "hosts:" "$VALUES_FILE" | grep "host:" | head -1 | awk '{print $3}')

if [ -z "$DOMAIN" ]; then
    echo -e "${RED}Could not extract domain from $VALUES_FILE${NC}"
    exit 1
fi

echo -e "${BLUE}Configuration:${NC}"
echo "  Domain: $DOMAIN"
echo ""

# Update JupyterHub values with domain
echo -e "${BLUE}Updating JupyterHub configuration with domain...${NC}"

# Update oauth_callback_url
sed -i "s|oauth_callback_url: \"https://[^/]*/|oauth_callback_url: \"https://$DOMAIN/|g" "$JUPYTERHUB_VALUES"

# Update ingress hosts
sed -i "s|^\([[:space:]]*\)- xnat-test\.ssdsorg\.cloud\.edu\.au|\1- $DOMAIN|g" "$JUPYTERHUB_VALUES"

# Handle any other domain that might be there (more generic pattern for hosts under ingress)
# This updates the line that just has the hostname under hosts:
sed -i "/^ingress:/,/^[a-z]/ { /hosts:/,/pathType:/ s/^\([[:space:]]*- \)[a-zA-Z0-9.-]*\.edu\.au/\1$DOMAIN/ }" "$JUPYTERHUB_VALUES"

echo -e "${GREEN}JupyterHub values updated with domain: $DOMAIN${NC}"
echo ""

# Confirm installation
read -p "Proceed with JupyterHub installation? (Y/n): " proceed
if [[ "$proceed" =~ ^[Nn]$ ]]; then
    echo "Installation cancelled."
    exit 0
fi
echo ""

# Run JupyterHub installation
echo -e "${BLUE}Running JupyterHub installation...${NC}"
chmod +x "$JUPYTERHUB_DIR/INSTALL.sh"
cd "$JUPYTERHUB_DIR"
./INSTALL.sh

# Run XNAT JupyterHub plugin installation
echo ""
echo -e "${BLUE}=========================================="
echo "Installing XNAT JupyterHub Plugin"
echo "==========================================${NC}"
echo ""
echo -e "${YELLOW}Note: This will restart XNAT to load the plugin${NC}"
read -p "Install XNAT JupyterHub plugin now? (Y/n): " install_plugin
if [[ ! "$install_plugin" =~ ^[Nn]$ ]]; then
    chmod +x "$JUPYTERHUB_DIR/0-xnat-jupyter-plugin.sh"
    "$JUPYTERHUB_DIR/0-xnat-jupyter-plugin.sh"
fi

echo ""
echo -e "${GREEN}=========================================="
echo "   JupyterHub Installation Complete!"
echo "==========================================${NC}"
echo ""
echo "Access URLs:"
echo "  XNAT:       http://$DOMAIN"
echo "  JupyterHub: http://$DOMAIN/hub"
echo ""
API_TOKEN=$(grep -A1 'xnat-service:' "$JUPYTERHUB_VALUES" 2>/dev/null | grep 'apiToken:' | awk -F'"' '{print $2}')
API_TOKEN=${API_TOKEN:-"<check jupyterhub/5-jupyterhub-values.yaml>"}

echo -e "${BLUE}XNAT JupyterHub Plugin Configuration:${NC}"
echo "  Go to: XNAT -> Administer -> Plugin Settings -> JupyterHub"
echo ""
echo "  JupyterHub Host URL:  http://$DOMAIN/"
echo "  JupyterHub API URL:   http://proxy-public.jupyter.svc.cluster.local/hub/api"
echo "  API Token:            $API_TOKEN"
echo ""
echo "  See jupyterhub/XNAT-CONFIGURATION.md for detailed setup instructions"
echo ""
