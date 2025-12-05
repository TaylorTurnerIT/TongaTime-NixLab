{ config, pkgs, ... }:

{
    virtualisation.oci-containers.containers.homepage = {
        /*
            Homepage Container
            This container runs homepage using the ghcr.io/gethomepage/homepage:latest image.

            Configuration:
            - Image:
                - Uses the latest ghcr.io/gethomepage/homepage image from GitHub Container Registry.
            - Ports:
                - Maps port 3000 on the host to port 3000 in the container.
                - Host: 3000 <--> Container: 3000
            - Volumes:
                - Maps /var/lib/homepage on the host to /data in the container for persistent storage.
                - Host:/var/lib/homepage <--> Container:/data
            - Environment Variables:
        */
        # Container image
        image = "ghcr.io/gethomepage/homepage:latest";
        
        # Auto start container on boot
        autoStart = true;
        
        # Map ports: Host:Container
        ports = [ "3000:3000" ];

        # Persistent Storage
        volumes = [
                "/var/lib/homepage:/app/config"
                ];
        # Environment Variables
        environment = {
                HOMEPAGE_ALLOWED_HOSTS = "tongatime.us";
            };
        };
        systemd.tmpfiles.rules = [
                "d /var/lib/homepage 0755 1000 100 10d"
        ];
}


