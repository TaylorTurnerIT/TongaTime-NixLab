{ config, pkgs, lib, ... }:

let
  user = "jexactyl";
  dataDir = "/var/lib/jexactyl";
in {
  # --- Create the Restricted User ---
  users.users.${user} = {
    isNormalUser = true;
    description = "Jexactyl Game Server User";
    extraGroups = [ "podman" ]; 
    linger = true; # Keeps the rootless socket alive
    home = dataDir;
    createHome = true;
  };

  # --- Panel Environment Secrets ---
  sops.templates."jexactyl.env".content = ''
    APP_URL=${config.sops.placeholder.jexactyl_app_url}
    APP_KEY=${config.sops.placeholder.jexactyl_app_key}
    APP_SERVICE_AUTHOR="admin@tongatime.us"
    APP_TIMEZONE="America/Chicago"
    DB_HOST=jexactyl-db
    DB_PORT=3306
    DB_DATABASE=panel
    DB_USERNAME=jexactyl
    DB_PASSWORD=${config.sops.placeholder.jexactyl_db_password}
    REDIS_HOST=jexactyl-redis
    REDIS_PORT=6379
    REDIS_PASSWORD=${config.sops.placeholder.jexactyl_redis_password}
  '';

  # --- The Web Stack (Panel + DB + Redis) ---
  # These are low-risk web apps, so running them via standard OCI is fine.
  # We use a dedicated network for them.
  
  virtualisation.oci-containers.containers = {
    jexactyl-db = {
      image = "mariadb:10.11";
      autoStart = true;
      environment = {
        MYSQL_DATABASE = "panel";
        MYSQL_USER = "jexactyl";
        MYSQL_PASSWORD = "SOPS_PLACEHOLDER"; # Will be handled by panel init
        MYSQL_ROOT_PASSWORD = "${config.sops.placeholder.jexactyl_db_password}"; 
      };
      environmentFiles = [ config.sops.templates."jexactyl.env".path ]; 
      volumes = [ "${dataDir}/database:/var/lib/mysql" ];
      extraOptions = [ "--network=jexactyl-net" ];
    };

    jexactyl-redis = {
      image = "redis:alpine";
      autoStart = true;
      cmd = [ "redis-server" "--requirepass" "${config.sops.placeholder.jexactyl_redis_password}" ];
      volumes = [ "${dataDir}/redis:/data" ];
      extraOptions = [ "--network=jexactyl-net" ];
    };

    jexactyl-panel = {
      image = "ghcr.io/jexactyl/jexactyl:latest";
      autoStart = true;
      ports = [ "8081:80" ];
      environmentFiles = [ config.sops.templates."jexactyl.env".path ];
      volumes = [
        "${dataDir}/panel/var:/app/var"
        "${dataDir}/panel/logs:/app/storage/logs"
        "${dataDir}/panel/nginx:/etc/nginx/http.d"
      ];
      extraOptions = [ "--network=jexactyl-net" ];
    };
  };

  # --- The Critical Component: Wings ---
  # We run this as a Systemd User Service for the 'jexactyl' user.
  # This traps all game servers inside the 'jexactyl' user namespace.
  
  systemd.services.jexactyl-wings = {
    description = "Jexactyl Wings (Rootless)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "jexactyl-panel.service" ];
    serviceConfig = {
      User = user;
      Group = "users";
      WorkingDirectory = "${dataDir}/wings";
      Restart = "always";
      # The magic command: We run podman inside the user session.
      # We bind the USER'S rootless socket to where Wings expects the docker socket.
      ExecStart = let
        podman = "${pkgs.podman}/bin/podman";
      in ''
        ${podman} run --rm --name jexactyl-wings \
          --privileged \
          --network host \
          -v /run/user/${toString config.users.users.${user}.uid}/podman/podman.sock:/var/run/docker.sock
          -v ${dataDir}/wings/config:/etc/pterodactyl \
          -v ${dataDir}/wings/data:/var/lib/pterodactyl/volumes \
          -v ${dataDir}/wings/backups:/var/lib/pterodactyl/backups \
          ghcr.io/pterodactyl/wings:latest
      '';
    };
  };

  # --- Networking Setup ---
  systemd.services.init-jexactyl-network = {
    script = "${pkgs.podman}/bin/podman network exists jexactyl-net || ${pkgs.podman}/bin/podman network create jexactyl-net";
    wantedBy = [ "multi-user.target" ];
  };
}