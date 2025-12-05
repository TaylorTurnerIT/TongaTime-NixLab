#!/usr/bin/env bash
set -e

# --- Configuration ---
DEPLOYER_IMAGE="homelab-deployer:latest"
# ---------------------

# 1. Check for Deployer Image
if ! podman image exists "$DEPLOYER_IMAGE"; then
    echo "⚠️  Deployer image not found. Please run ./build-deployer.sh first."
    exit 1
fi

echo "🚀 Starting DNS Deployment..."

# 2. Run Container
# We mount:
# - pwd -> /work (so it can see network/dnsconfig.js and creds-to-json.sh)
# - ~/.config/sops -> /root/.config/sops (for SOPS key access)
# - ~/.ssh -> /root/.ssh (for SSH key access if needed for sops)

podman run --rm -it \
  --security-opt label=disable \
  -v "$(pwd):/work:Z" \
  -v "$HOME/.config/sops:/root/.config/sops:ro" \
  -v "$HOME/.ssh:/root/.ssh:ro" \
  -w /work \
  "$DEPLOYER_IMAGE" \
  bash -c "
    set -e
    
    # Ensure the helper script is executable inside the container
    chmod +x creds-to-json.sh

    echo '🔍 Checking Configuration...'
    # The '!' tells DNSControl to execute the file instead of reading it
    dnscontrol check --creds !./creds-to-json.sh --config network/dnsconfig.js

    echo '----------------------------------------'
    echo '🔮 PREVIEWING CHANGES'
    echo '----------------------------------------'
    dnscontrol preview --creds !./creds-to-json.sh --config network/dnsconfig.js

    echo '----------------------------------------'
    read -p '⚠️  Apply these changes to Cloudflare? (y/N) ' -n 1 -r
    echo
    if [[ \$REPLY =~ ^[Yy]$ ]]; then
        echo '🚀 Pushing changes...'
        dnscontrol push --creds !./creds-to-json.sh --config network/dnsconfig.js
    else
        echo '🚫 Aborted.'
    fi
"