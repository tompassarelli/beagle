{ config, lib, pkgs, ... }:

let
  cfg = config.myConfig.modules.demo;
in
{
  options.myConfig.modules.demo = {
    enable = lib.mkEnableOption "demo";
    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
    };
  };
  config = lib.mkIf cfg.enable {
    networking.firewall.allowedTCPPorts = [ cfg.port ];
    systemd.services.demo = {
      wantedBy = [ "multi-user.target" ];
      environment = {
        PORT = toString cfg.port;
      };
    };
  };
}
