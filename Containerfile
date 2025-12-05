# Deployment ContainerFile
# This builds a custom container with all deployment tools pre-installed

# Start from the official NixOS container image
FROM nixos/nix:latest

# --- Configure Nix ---
# Nix needs to know we want to use modern features (flakes and nix commands)
RUN mkdir -p /root/.config/nix && \
    echo 'experimental-features = nix-command flakes' > /root/.config/nix/nix.conf

# --- Pre-install Deployment Tools ---
# We install everything ONCE during build
# These tools will be permanently available in the image
RUN nix profile add \
    nixpkgs#nixos-rebuild \
    github:nix-community/nixos-anywhere \
    nixpkgs#dnscontrol \
    nixpkgs#sops \
    nixpkgs#yq-go

# --- Pre-fetch nixos-anywhere ---
# nixos-anywhere is used for initial installs
# We fetch it so it's cached in the image
RUN nix flake metadata github:nix-community/nixos-anywhere --refresh

# --- Configure SSH defaults ---
# Set up SSH to ignore known_hosts collisions
RUN mkdir -p /root/.ssh && \
    echo "StrictHostKeyChecking no" >> /root/.ssh/config && \
    echo "UserKnownHostsFile /dev/null" >> /root/.ssh/config

# Set working directory
WORKDIR /work

# Default command (can be overridden)
CMD ["/bin/bash"]