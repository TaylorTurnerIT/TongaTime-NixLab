{ config, pkgs, lib, ... }:

let
  user = "jexactyl";
  group = "users";
  # We pin the UID to ensure the socket path (/run/user/1000/podman/podman.sock) 
  # is predictable and matches the existing system user.
  uid = 1000; 
  dataDir = "/var/lib/jexactyl";
in {
  # --- Secrets Management ---
  # We explicitly define the secrets used by the Jexactyl services.
  # Ownership is assigned to the service user so they can be read at runtime.
  sops.secrets.jexactyl_admin_password = { owner = "root"; }; # Only used by the one-shot init script
  sops.secrets.jexactyl_db_password = { owner = user; };
  sops.secrets.jexactyl_redis_password = { owner = user; };
  sops.secrets.jexactyl_app_key = { owner = user; };
  sops.secrets.jexactyl_app_url = { owner = user; };

  # --- User Configuration ---
  # Create a dedicated user for Jexactyl. This user requires 'linger' enabled
  # so that its rootless Podman socket remains active even when not logged in.
  users.users.${user} = {
    isNormalUser = true;
    description = "Jexactyl Game Server User";
    extraGroups = [ "podman" ];
    linger = true;
    home = dataDir;
    createHome = true;
    uid = uid; 
  };

  # --- Directory Structure & Permissions ---
  # Since we are running rootless containers, we must ensure the host directory 
  # structure exists with the correct ownership before the containers start.
  systemd.tmpfiles.rules = [
    # Wings Directories
    "d ${dataDir}/wings         0755 ${user} ${group} - -"
    "d ${dataDir}/wings/config  0755 ${user} ${group} - -"
    "d ${dataDir}/wings/data    0755 ${user} ${group} - -"
    "d ${dataDir}/wings/backups 0755 ${user} ${group} - -"
    
    # Panel Directories
    "d ${dataDir}/panel         0755 ${user} ${group} - -"
    "d ${dataDir}/panel/var     0755 ${user} ${group} - -"
    "d ${dataDir}/panel/logs    0755 ${user} ${group} - -"
    "d ${dataDir}/panel/nginx   0755 ${user} ${group} - -"
    
    # Database & Redis Directories
    "d ${dataDir}/database      0755 ${user} ${group} - -"
    "d ${dataDir}/redis         0755 ${user} ${group} - -"
  ];

  # --- Environment Configuration ---
  # Generate the .env file required by the Jexactyl panel, injecting secrets 
  # from sops-nix where appropriate.
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

  # --- Service Containers (Panel Stack) ---
  # These containers run the web panel, database, and cache.
  virtualisation.oci-containers.containers = {
    jexactyl-db = {
      image = "mariadb:10.11";
      autoStart = true;
      environment = {
        MYSQL_DATABASE = "panel";
        MYSQL_USER = "jexactyl";
        MYSQL_PASSWORD = "SOPS_PLACEHOLDER"; # Handled by sops template
        MYSQL_ROOT_PASSWORD = "${config.sops.placeholder.jexactyl_db_password}";
      };
      environmentFiles = [ config.sops.templates."jexactyl.env".path ];
      volumes = [ "${dataDir}/database:/var/lib/mysql" ];
      extraOptions = [ 
        "--network=jexactyl-net"
        "--health-cmd=healthcheck.sh --connect --innodb_initialized"
        "--health-start-period=10s"
        "--health-interval=10s"
        "--health-retries=3"
      ];
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

  # --- Wings Daemon (Rootless) ---
  # Wings controls the actual game servers. We run this as a user service
  # so that all game servers are spawned within the user's namespace.
  systemd.services.jexactyl-wings = {
    description = "Jexactyl Wings (Rootless)";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" "podman-jexactyl-panel.service" ];
    serviceConfig = {
      User = user;
      Group = group;
      WorkingDirectory = "${dataDir}/wings";
      Restart = "always";
      # We bind the user's rootless Podman socket to the container so Wings can spawn sibling containers.
      ExecStart = let
        podman = "${pkgs.podman}/bin/podman";
      in ''
        ${podman} run --rm --name jexactyl-wings \
        --privileged \
        --network host \
        -v /run/user/${toString uid}/podman/podman.sock:/var/run/docker.sock \
        -v ${dataDir}/wings/config:/etc/pterodactyl \
        -v ${dataDir}/wings/data:/var/lib/pterodactyl/volumes \
        -v ${dataDir}/wings/backups:/var/lib/pterodactyl/backups \
        ghcr.io/pterodactyl/wings:latest
      '';
    };
  };

  # --- Network Initialization ---
  # Ensures the dedicated bridge network exists before containers start.
  systemd.services.init-jexactyl-network = {
    script = "${pkgs.podman}/bin/podman network exists jexactyl-net || ${pkgs.podman}/bin/podman network create jexactyl-net";
    wantedBy = [ "multi-user.target" ];
  };

  # --- First-Run Initialization ---
  # This one-shot service runs only on the first deployment to seed the database
  # and create the initial admin user. It is skipped if .setup_complete exists.
  systemd.services.jexactyl-init = {
    description = "Initialize Jexactyl Database and Admin User";
    after = [ "podman-jexactyl-panel.service" "podman-jexactyl-db.service" ]; 
    requires = [ "podman-jexactyl-panel.service" "podman-jexactyl-db.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ConditionPathExists = "!/var/lib/jexactyl/.setup_complete";
    };

    script = ''
      set -e
      echo "Waiting for Database..."
      ${pkgs.podman}/bin/podman wait --condition=healthy jexactyl-db

      echo "Running Migrations..."
      ${pkgs.podman}/bin/podman exec jexactyl-panel php artisan migrate --seed --force

      echo "Creating Admin User..."
      ADMIN_PASS=$(cat ${config.sops.secrets.jexactyl_admin_password.path})
      
      ${pkgs.podman}/bin/podman exec jexactyl-panel php artisan p:user:make \
        --email="admin@tongatime.us" \
        --username="admin" \
        --name-first="Admin" \
        --name-last="User" \
        --password="$ADMIN_PASS" \
        --admin=1

      touch /var/lib/jexactyl/.setup_complete
      echo "Jexactyl Initialization Complete."
    '';
  };
}