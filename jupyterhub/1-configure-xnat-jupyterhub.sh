#!/bin/bash
# Configure XNAT JupyterHub Plugin via REST API
# This script automates the manual steps in XNAT-CONFIGURATION.md (Steps 2-4)
#
# Prerequisites:
#   - XNAT is running and accessible
#   - JupyterHub plugin JAR is installed (run 0-xnat-jupyter-plugin.sh first)
#   - Admin has completed XNAT setup wizard and knows the admin password
#
# Usage:
#   ./1-configure-xnat-jupyterhub.sh [--password <admin_password>]
set -e

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
VALUES_FILE="$BASE_DIR/manifests/values.yaml"
JUPYTERHUB_VALUES="$SCRIPT_DIR/5-jupyterhub-values.yaml"

# Ensure kubeconfig is available (k3s default requires root)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# Parse arguments
ADMIN_PASSWORD=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --password) ADMIN_PASSWORD="$2"; shift 2 ;;
        *) echo -e "${RED}Unknown argument: $1${NC}"; exit 1 ;;
    esac
done

# Prompt for password if not provided
if [ -z "$ADMIN_PASSWORD" ]; then
    read -sp "Enter XNAT admin password: " ADMIN_PASSWORD
    echo
fi

echo -e "${BLUE}"
echo "=========================================="
echo "  XNAT JupyterHub Plugin Configuration"
echo "=========================================="
echo -e "${NC}"

# --- Determine XNAT URL ---
# Try in-cluster first, fall back to ingress
XNAT_INTERNAL="http://xnat-web.ais-xnat.svc.cluster.local"
XNAT_POD=$(kubectl -n ais-xnat get pods -l app.kubernetes.io/name=xnat-web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$XNAT_POD" ]; then
    echo -e "${RED}XNAT pod not found. Is XNAT running?${NC}"
    exit 1
fi

# Use kubectl exec to call the API from within the cluster
xnat_api() {
    local method="$1"
    local path="$2"
    local data="$3"

    local curl_args=(-s -f -X "$method" -u "admin:${ADMIN_PASSWORD}")

    if [ -n "$data" ]; then
        curl_args+=(-H "Content-Type: application/json" -d "$data")
    fi

    kubectl -n ais-xnat exec "$XNAT_POD" -c xnat-web -- \
        curl "${curl_args[@]}" "http://localhost:8080${path}" 2>/dev/null
}

# --- Step 1: Verify authentication ---
echo -e "${BLUE}[1/5] Verifying XNAT admin credentials...${NC}"
if ! xnat_api GET "/xapi/siteConfig/siteId" > /dev/null 2>&1; then
    echo -e "${RED}Authentication failed. Check admin password.${NC}"
    echo "If the admin account is locked, wait 1 hour or reset via database."
    exit 1
fi
echo -e "${GREEN}Authentication successful${NC}"

# --- Step 2: Read configuration values ---
echo -e "${BLUE}[2/5] Reading configuration...${NC}"

# Get JupyterHub service token from values file
if [ -f "$JUPYTERHUB_VALUES" ]; then
    JUPYTERHUB_TOKEN=$(grep -A2 'xnat-service:' "$JUPYTERHUB_VALUES" 2>/dev/null | grep 'apiToken:' | awk -F'"' '{print $2}')
fi

# Fall back to template
if [ -z "$JUPYTERHUB_TOKEN" ] && [ -f "$SCRIPT_DIR/5-jupyterhub-values.yaml.template" ]; then
    JUPYTERHUB_TOKEN=$(grep -A2 'xnat-service:' "$SCRIPT_DIR/5-jupyterhub-values.yaml.template" 2>/dev/null | grep 'apiToken:' | awk -F'"' '{print $2}')
fi

if [ -z "$JUPYTERHUB_TOKEN" ]; then
    echo -e "${RED}Could not find JupyterHub API token in values file${NC}"
    exit 1
fi

# Get domain from XNAT values
DOMAIN=$(grep -A1 "hosts:" "$VALUES_FILE" 2>/dev/null | grep "host:" | head -1 | awk '{print $3}')
DOMAIN=${DOMAIN:-"localhost"}

JUPYTERHUB_HOST_URL="https://${DOMAIN}"
JUPYTERHUB_API_URL="http://proxy-public.jupyter.svc.cluster.local/jupyter/hub/api"

echo "  Domain:           $DOMAIN"
echo "  JupyterHub Token: ${JUPYTERHUB_TOKEN:0:16}..."
echo "  API URL:          $JUPYTERHUB_API_URL"

# --- Step 3: Set JupyterHub plugin preferences ---
echo ""
echo -e "${BLUE}[3/5] Configuring JupyterHub plugin preferences...${NC}"

PREFS_JSON=$(cat <<EOF
{
    "jupyterHubHostUrl": "${JUPYTERHUB_HOST_URL}",
    "jupyterHubApiUrl": "${JUPYTERHUB_API_URL}",
    "jupyterHubToken": "${JUPYTERHUB_TOKEN}",
    "startTimeout": 300,
    "stopTimeout": 60,
    "allUsersCanStartJupyter": true,
    "workspacePath": "/data/xnat/workspaces",
    "inactivityTimeout": 120,
    "maxServerLifetime": 48,
    "maxNamedServers": 1,
    "pathTranslationArchivePrefix": "/data/xnat/archive",
    "pathTranslationArchiveDockerPrefix": "/data/xnat/archive",
    "pathTranslationWorkspacePrefix": "/data/xnat/workspaces",
    "pathTranslationWorkspaceDockerPrefix": "/data/xnat/workspaces"
}
EOF
)

if xnat_api POST "/xapi/jupyterhub/preferences" "$PREFS_JSON" > /dev/null 2>&1; then
    echo -e "${GREEN}Plugin preferences configured${NC}"
else
    echo -e "${RED}Failed to set plugin preferences${NC}"
    echo "Attempting individual preference updates..."

    # Fall back to setting preferences one at a time
    while IFS= read -r key; do
        value=$(echo "$PREFS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['$key'])" 2>/dev/null)
        if [ -n "$value" ]; then
            if xnat_api POST "/xapi/jupyterhub/preferences/${key}" "\"${value}\"" > /dev/null 2>&1; then
                echo -e "  ${GREEN}Set ${key}${NC}"
            else
                echo -e "  ${RED}Failed to set ${key}${NC}"
            fi
        fi
    done <<< "$(echo "$PREFS_JSON" | python3 -c "import sys,json; [print(k) for k in json.load(sys.stdin)]")"
fi

# --- Step 4: Update default compute environment to use Neurodesk ---
echo ""
echo -e "${BLUE}[4/5] Configuring Neurodesk compute environment...${NC}"

# The plugin auto-creates a default compute environment on first boot.
# Check if compute environments exist, and update the default to use Neurodesk image.
NEURODESK_IMAGE="ghcr.io/neurodesk/neurodesktop/neurodesktop:2026-07-07"

# Try to get existing compute environment configs
EXISTING_ENVS=$(xnat_api GET "/xapi/compute-environment-configs" 2>/dev/null || echo "")

if [ -n "$EXISTING_ENVS" ] && [ "$EXISTING_ENVS" != "[]" ]; then
    echo "  Existing compute environments found."
    # Get the first config ID
    FIRST_ID=$(echo "$EXISTING_ENVS" | python3 -c "import sys,json; data=json.load(sys.stdin); print(data[0]['id'])" 2>/dev/null || echo "")

    if [ -n "$FIRST_ID" ]; then
        # Get the existing config and update the image
        EXISTING_CONFIG=$(xnat_api GET "/xapi/compute-environment-configs/${FIRST_ID}" 2>/dev/null || echo "")

        if [ -n "$EXISTING_CONFIG" ]; then
            UPDATED_CONFIG=$(echo "$EXISTING_CONFIG" | python3 -c "
import sys, json
config = json.load(sys.stdin)
config['computeEnvironment']['name'] = 'NeuroDesk'
config['computeEnvironment']['image'] = '${NEURODESK_IMAGE}'
config['computeEnvironment']['environmentVariables'] = [
    {'key': 'JUPYTER_ENABLE_LAB', 'value': 'yes'}
]
print(json.dumps(config))
" 2>/dev/null)

            if [ -n "$UPDATED_CONFIG" ]; then
                if xnat_api PUT "/xapi/compute-environment-configs/${FIRST_ID}" "$UPDATED_CONFIG" > /dev/null 2>&1; then
                    echo -e "${GREEN}  Updated compute environment to NeuroDesk (${NEURODESK_IMAGE})${NC}"
                else
                    echo -e "${YELLOW}  Could not update via compute-environment-configs API${NC}"
                fi
            fi
        fi
    fi
else
    echo "  No compute environments found via REST API."
    echo "  Creating NeuroDesk compute environment..."

    NEW_ENV=$(cat <<ENVEOF
{
    "configTypes": ["JUPYTERHUB"],
    "computeEnvironment": {
        "name": "NeuroDesk",
        "image": "${NEURODESK_IMAGE}",
        "environmentVariables": [
            {"key": "JUPYTER_ENABLE_LAB", "value": "yes"}
        ],
        "mounts": []
    },
    "scopes": {
        "Site": {"scope": "Site", "enabled": true, "ids": []},
        "Project": {"scope": "Project", "enabled": true, "ids": []},
        "User": {"scope": "User", "enabled": true, "ids": []}
    },
    "hardwareOptions": {
        "allowAllHardware": true,
        "hardwareConfigs": []
    }
}
ENVEOF
)

    if xnat_api POST "/xapi/compute-environment-configs" "$NEW_ENV" > /dev/null 2>&1; then
        echo -e "${GREEN}  Created NeuroDesk compute environment${NC}"
    else
        echo -e "${YELLOW}  Could not create via REST API. The plugin may auto-create defaults on first use.${NC}"
        echo -e "${YELLOW}  You may need to update the image in: Administer > Plugin Settings > JupyterHub > Compute Environments${NC}"
    fi
fi

# --- Step 5: Update XNAT admin password in JupyterHub config ---
echo ""
echo -e "${BLUE}[5/5] Updating JupyterHub pre-spawn hook credentials...${NC}"

# Update password in values file (or template if values doesn't exist yet)
PASS_FILE=""
if [ -f "$JUPYTERHUB_VALUES" ]; then
    PASS_FILE="$JUPYTERHUB_VALUES"
elif [ -f "$SCRIPT_DIR/5-jupyterhub-values.yaml.template" ]; then
    PASS_FILE="$SCRIPT_DIR/5-jupyterhub-values.yaml.template"
fi

if [ -n "$PASS_FILE" ]; then
    CURRENT_XNAT_PASS=$(grep 'XNAT_PASSWORD:' "$PASS_FILE" | head -1 | awk -F'"' '{print $2}')
    if [ "$CURRENT_XNAT_PASS" != "$ADMIN_PASSWORD" ]; then
        sed -i "s|XNAT_PASSWORD: \"${CURRENT_XNAT_PASS}\"|XNAT_PASSWORD: \"${ADMIN_PASSWORD}\"|" "$PASS_FILE"
        echo -e "${GREEN}Updated XNAT_PASSWORD in $(basename "$PASS_FILE")${NC}"
        if [ "$PASS_FILE" = "$JUPYTERHUB_VALUES" ]; then
            echo -e "${YELLOW}Note: Run 'helm upgrade' to apply the new password to JupyterHub${NC}"
        fi
    else
        echo -e "${GREEN}XNAT_PASSWORD already matches${NC}"
    fi
else
    echo -e "${YELLOW}No JupyterHub values file found${NC}"
    echo "  The pre_spawn_hook uses XNAT_PASSWORD to call the XNAT API."
    echo "  Ensure it matches the admin password."
fi

echo ""
echo -e "${GREEN}=========================================="
echo "  Configuration Complete!"
echo "==========================================${NC}"
echo ""
echo "Configured:"
echo "  - JupyterHub Host URL:  $JUPYTERHUB_HOST_URL"
echo "  - JupyterHub API URL:   $JUPYTERHUB_API_URL"
echo "  - Compute Image:        $NEURODESK_IMAGE"
echo "  - All users can start:  true"
echo "  - Start timeout:        300s"
echo "  - Inactivity timeout:   120 min"
echo "  - Max server lifetime:  48 hours"
echo ""
echo "Next steps:"
echo "  1. Verify in XNAT UI: Administer > Plugin Settings > JupyterHub"
echo "  2. Enable JupyterHub per-project: Project > Project Settings > JupyterHub"
echo "  3. Test by clicking 'Launch JupyterHub' from a project page"
