{ config, lib, pkgs, ... }:

let
  cfg = config.services.demo;
  port = cfg.port;
  isDev = (cfg.environment == "development");
in
{
  options.services.demo = {
    enable = lib.mkEnableOption "demo service";
    port = lib.mkOption {
      type = lib.types.int;
      default = 8080;
    };
    environment = lib.mkOption {
      type = lib.types.str;
      default = "production";
    };
  };
  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ port ];
    systemd.services.demo = {
      wantedBy = [ "multi-user.target" ];
      environment = {
        PORT = toString port;
        LOG_LEVEL = if isDev then "debug" else "info";
      };
    };
  };
}
