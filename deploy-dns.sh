#!/usr/bin/env bash
set -e

# --- Configuration ---
DEPLOYER_IMAGE="homelab-deployer:latest"
# ---------------------

# Check for Deployer Image
if ! podman image exists "$DEPLOYER_IMAGE"; then
    echo "⚠️  Deployer image not found. Please run ./build-deployer.sh first."
    exit 1
fi

echo "🚀 Starting DNS Deployment..."

# Run Container
# We mount:
# - pwd -> /work
# - ~/.config/sops -> /root/.config/sops (for keys)
# - ~/.ssh -> /root/.ssh (for keys)

podman run --rm -it \
  --security-opt label=disable \
  -v "$(pwd):/work:Z" \
  -v "$HOME/.config/sops:/root/.config/sops:ro" \
  -v "$HOME/.ssh:/root/.ssh:ro" \
  -w /work \
  "$DEPLOYER_IMAGE" \
  bash -c "
    set -e

    echo '🔍 Checking Configuration...'
    # The '!' tells DNSControl to execute the command and parse the output as JSON
    # 'sops -d' outputs the decrypted JSON directly to stdout
    dnscontrol check --creds '!sops -d secrets/dns_creds.json' --config network/dnsconfig.js

    echo '----------------------------------------'
    echo '🔮 PREVIEWING CHANGES'
    echo '----------------------------------------'
    dnscontrol preview --creds '!sops -d secrets/dns_creds.json' --config network/dnsconfig.js

    echo '----------------------------------------'
    read -p '⚠️  Apply these changes to Cloudflare? (y/N) ' -n 1 -r
    echo
    if [[ \$REPLY =~ ^[Yy]$ ]]; then
        echo '🚀 Pushing changes...'
        dnscontrol push --creds '!sops -d secrets/dns_creds.json' --config network/dnsconfig.js
    else
        echo '🚫 Aborted.'
    fi
"