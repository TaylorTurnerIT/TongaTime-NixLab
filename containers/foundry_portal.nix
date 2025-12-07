{ config, pkgs, lib, ... }:

let
    # --- Declarative Configuration ---
    # We define the config here, and Nix writes it to the store.
    portalConfig = {
        shared_data_mode = false;
        instances = [
            {
                name = "Genesis";
                url = "http://100.73.119.72:30000/chef/genesis";
            }
        ];
    };

    # Convert the set to YAML and write it to the Nix Store
    configYaml = pkgs.writeText "foundry-portal-config.yaml" (lib.generators.toYAML {} portalConfig);

    in {
    # --- Build Service ---
    # Since Foundry Portal does not have an official docker image, we build it from source using Podman.
    # This service ensures the image exists before the container starts.
    systemd.services.build-foundry-portal = {
        description = "Build Foundry Portal Docker Image";
        path = [ pkgs.git pkgs.podman ]; # Tools needed for the script
        script = ''
        set -e
        WORK_DIR="/var/lib/foundry-portal/source"
        
        # Ensure directory exists
        mkdir -p "$WORK_DIR"
        cd "$WORK_DIR"

        # Clone or Pull the latest source
        if [ -d ".git" ]; then
            echo "Updating existing repository..."
            git pull
        else
            echo "Cloning repository..."
            git clone https://github.com/TaylorTurnerIT/foundry-portal.git .
        fi

        # Build the image using Podman
        # We tag it as 'foundry-portal:latest' so the container service can find it.
        echo "Building Podman image..."
        podman build -t foundry-portal:latest .
        '';
        serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "300"; # Allow 5 minutes for the build
        };
    };
    virtualisation.oci-containers.containers.foundry-portal = {
        /*
            Foundry Portal Container
            This container runs Foundry Portal, a web frontend for managing multiple Foundry Virtual Tabletop (VTT) instances.

            Configuration:
            - Image:
                - Uses the image built by the build-foundry-portal service.
            - Ports:
                - Maps port 5000 on the host to port 5000 in the container.
                - Host: 5000 <--> Container: 5000
            - Volumes:
                - Maps /var/lib/foundry-portal/config.yaml to /app/config.yaml in the container
                - Host:/var/lib/foundry-portal/config.yaml <--> Container:/app/config.yaml
            - Auto Start:
                - Container starts automatically on boot

            Setup Instructions:
            1. Create the config directory: sudo mkdir -p /var/lib/foundry-portal
            2. Create your config.yaml at /var/lib/foundry-portal/config.yaml
            3. Example config.yaml:
                shared_data_mode: false
                instances:
                  - name: "In Golden Flame"
                    url: "https://foundry.tongatime.us/crunch/ingoldenflame"
                  - name: "Genesis"
                    url: "https://foundry.tongatime.us/chef/genesis"

            Reference:
            https://github.com/TaylorTurnerIT/foundry-portal
        */

        # Container image
        image = "foundry-portal:latest";

        # Auto start container on boot
        autoStart = true;

        # Map ports: Host:Container
        ports = [ "5000:5000" ];

        # Persistent Storage - mount config file
        volumes = [
            "${configYaml}:/app/config.yaml:ro"
        ];
    };

    systemd.services.podman-foundry-portal = {
        requires = [ "build-foundry-portal.service" ];
        after = [ "build-foundry-portal.service" ];
    };

    # Ensure the Foundry Portal config directory exists with correct permissions
    systemd.tmpfiles.rules = [
        "d /var/lib/foundry-portal 0755 root root - -"
    ];
}