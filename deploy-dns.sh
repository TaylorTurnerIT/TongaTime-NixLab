#!/usr/bin/env bash
set -e

# --- Configuration ---
DEPLOYER_IMAGE="homelab-deployer:latest"
SECRETS_FILE="secrets/secrets.yaml"
# ---------------------

# Check for Sops
if ! command -v sops &> /dev/null; then
    echo "❌ Error: 'sops' is not installed on your host. Please install it to decrypt secrets."
    exit 1
fi

# Check for Deployer Image
if ! podman image exists "$DEPLOYER_IMAGE"; then
    echo "⚠️  Deployer image not found. Please run ./build-deployer.sh first."
    exit 1
fi

# Extract Cloudflare Token
# We extract the token directly to a variable to avoid writing it to disk
echo "lf Decrypting Cloudflare Token..."
export CF_TOKEN=$(sops -d --extract '["cloudflare_token"]' "$SECRETS_FILE")

if [ -z "$CF_TOKEN" ]; then
    echo "❌ Failed to extract 'cloudflare_token' from $SECRETS_FILE"
    exit 1
fi

# Run DNSControl
echo "🚀 Running DNSControl Container..."
podman run --rm -it \
  --security-opt label=disable \
  -v "$(pwd):/work:Z" \
  -w /work \
  -e CLOUDFLARE_API_TOKEN="$CF_TOKEN" \
  "$DEPLOYER_IMAGE" \
  bash -c "
    echo '🔍 Checking Configuration...'
    dnscontrol check --creds network/creds.json --config network/dnsconfig.js

    echo '----------------------------------------'
    echo '🔮 PREVIEWING CHANGES'
    echo '----------------------------------------'
    dnscontrol preview --creds network/creds.json --config network/dnsconfig.js

    echo '----------------------------------------'
    read -p '⚠️  Apply these changes to Cloudflare? (y/N) ' -n 1 -r
    echo
    if [[ \$REPLY =~ ^[Yy]$ ]]; then
        echo '🚀 Pushing changes...'
        dnscontrol push --creds network/creds.json --config network/dnsconfig.js
    else
        echo '🚫 Aborted.'
    fi
"