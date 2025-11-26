#!/usr/bin/env bash

# --- Configuration ---
TARGET_HOST="homelab" 
FLAKE=".#homelab"
DEPLOYER_IMAGE="homelab-deployer:latest"
# ---------------------

set -e

# Function to print usage
usage() {
    echo "Usage: $0 [option]"
    echo "Options:"
    echo "  (no option)   Update the server (nixos-rebuild switch)"
    echo "  --install     Wipe and Re-install (nixos-anywhere)"
    echo "  --rebuild     Rebuild the deployment container"
    exit 1
}

# Check if we need to rebuild the image
if [[ "$1" == "--rebuild" ]]; then
    echo "🔨 Rebuilding deployment container..."
    podman build -t "$DEPLOYER_IMAGE" -f Containerfile .
    echo "✅ Container rebuilt!"
    exit 0
fi

# Check arguments
MODE="update"
if [[ "$1" == "--install" ]]; then
    MODE="install"
    echo "⚠️  WARNING: You are about to WIPE and RE-INSTALL $TARGET_HOST."
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 1
    fi
elif [[ -n "$1" ]]; then
    usage
fi

# Check if image exists
if ! podman image exists "$DEPLOYER_IMAGE"; then
    echo "❌ Deployer image not found. Building it now..."
    podman build -t "$DEPLOYER_IMAGE" -f Containerfile .
fi

echo "🚀 Starting Deployment (using $DEPLOYER_IMAGE)..."

podman run --rm -it \
  --security-opt label=disable \
  -v "$(pwd):/work:Z" \
  -v "$HOME/.ssh:/mnt/ssh_keys:ro" \
  -w /work \
  --net=host \
  "$DEPLOYER_IMAGE" \
  bash -c "
    # 1. Setup Writable SSH Environment
    # Copy keys from read-only mount to writable container location
    cp -r /mnt/ssh_keys/* /root/.ssh/ 2>/dev/null || true
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/* 2>/dev/null || true

    # 2. Execute Command (With Retry Loop)
    while true; do
        if [ \"$MODE\" == \"install\" ]; then
            echo '🔥 Nuking and Installing NixOS...'
            # Notice: No more 'nix run' - the tool is already installed!
            if nixos-anywhere --flake $FLAKE $TARGET_HOST; then
                echo '✅ Installation Complete!'
                break
            fi
        else
            echo '🔄 Updating Configuration...'
            # Notice: No more 'nix run' - the tool is already installed!
            if nixos-rebuild switch --flake $FLAKE --target-host $TARGET_HOST --use-remote-sudo; then
                echo '✅ Update Complete!'
                break
            fi
        fi

        echo 
        echo '❌ Command failed.'
        read -p 'Retry? (y/N) ' -n 1 -r REPLY
        echo
        if [[ ! \$REPLY =~ ^[Yy]$ ]]; then
            echo 'Exiting.'
            exit 1
        fi
        echo '🔄 Retrying...'
    done
"

echo "✅ Done!"