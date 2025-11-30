#!/usr/bin/env bash

# --- Configuration ---
TARGET_HOST="129.153.13.212"
TARGET_USER="ubuntu"
FLAKE=".#homeConfigurations.ubuntu"
SSH_KEY_NAME="homelab"
DEPLOYER_IMAGE="homelab-deployer:latest"
# ---------------------

set -e

# Check for SSH Key locally
if [[ ! -f "$HOME/.ssh/$SSH_KEY_NAME" ]]; then
    echo "❌ CRITICAL ERROR: SSH Key '$HOME/.ssh/$SSH_KEY_NAME' not found!"
    exit 1
fi

# Check if we need to rebuild the image
if [[ "$1" == "--rebuild" ]]; then
    echo "🔨 Rebuilding deployment container..."
    podman build -t "$DEPLOYER_IMAGE" -f Containerfile .
    echo "✅ Container rebuilt!"
    exit 0
fi

# Ensure image exists
if ! podman image exists "$DEPLOYER_IMAGE"; then
    echo "❌ Deployer image not found. Building it now..."
    podman build -t "$DEPLOYER_IMAGE" -f Containerfile .
fi

echo "🚀 Starting Deployment to $TARGET_USER@$TARGET_HOST..."

# Run the deployment INSIDE the container
podman run --rm -it \
  --security-opt label=disable \
  -v "$(pwd):/work:Z" \
  -v "$HOME/.ssh:/mnt/ssh_keys:ro" \
  -w /work \
  --net=host \
  -e TARGET_HOST="$TARGET_HOST" \
  -e TARGET_USER="$TARGET_USER" \
  -e FLAKE="$FLAKE" \
  -e SSH_KEY_NAME="$SSH_KEY_NAME" \
  "$DEPLOYER_IMAGE" \
  bash -c "
    # --- 1. Setup SSH Inside Container ---
    mkdir -p /root/.ssh
    cp -r /mnt/ssh_keys/* /root/.ssh/ 2>/dev/null || true
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/* 2>/dev/null || true
    
    # Configure SSH
    echo 'Host $TARGET_HOST' >> /root/.ssh/config
    echo '    StrictHostKeyChecking no' >> /root/.ssh/config
    echo '    UserKnownHostsFile /dev/null' >> /root/.ssh/config
    echo '    IdentityFile /root/.ssh/$SSH_KEY_NAME' >> /root/.ssh/config

    SSH_CMD=\"ssh -i /root/.ssh/$SSH_KEY_NAME $TARGET_USER@$TARGET_HOST\"

    # --- 2. Bootstrap Nix on Remote (if missing) ---
    echo '🔍 Checking for Nix on remote host...'
    if ! \$SSH_CMD \"command -v nix-env &> /dev/null\"; then
        echo '📦 Nix not found. Installing Nix on remote host...'
        # Install Determinate Systems Nix (Standard for non-NixOS)
        \$SSH_CMD \"curl --proto '=https' --tlsv1.2 -sSf -L https://install.determinate.systems/nix | sh -s -- install --no-confirm\"
        echo '✅ Nix installed!'
    else
        echo '✅ Nix is already installed.'
    fi

    # --- 3. Build Configuration (Inside Container) ---
    echo '🔨 Building Home Manager configuration...'
    # We build the activation script. 
    # Note: We must allow impure builds if you are referencing unfree packages in a certain way, 
    # but standard flakes usually don't need --impure unless specified.
    DRV=\$(nix build --no-link --print-out-paths \"$FLAKE.activationPackage\" --extra-experimental-features 'nix-command flakes')
    
    if [ -z \"\$DRV\" ]; then
        echo '❌ Build failed.'
        exit 1
    fi
    echo \"✅ Build successful: \$DRV\"

    # --- 4. Copy to Remote ---
    echo 'Ns Copying closure to remote...'
    # We use NIX_SSHOPTS to ensure the copy uses our key
    export NIX_SSHOPTS=\"-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /root/.ssh/$SSH_KEY_NAME\"
    nix copy --to \"ssh://$TARGET_USER@$TARGET_HOST\" \"\$DRV\" --extra-experimental-features 'nix-command flakes'

    # --- 5. Activate on Remote ---
    echo '🔄 Activating configuration...'
    \$SSH_CMD \"\$DRV/activate\"

    echo '✅ Deployment Complete!'
"