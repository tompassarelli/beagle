{ config, lib, pkgs, ... }:

let
  cfg = config.services.demo;
in
{
  config = lib.mkIf cfg.enable {
    services.demo = {
      enable = true;
      user = "demo";
      settings = lib.mkIf (cfg.port != null) {
        port = cfg.port;
        bindAddress = lib.mkDefault "127.0.0.1";
        logFile = lib.mkForce "/var/log/demo.log";
      };
    };
    systemd.services.demo.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = "demo";
      ReadOnlyPaths = [ "/etc/demo" ];
      ConfigFile = builtins.readFile cfg.configPath;
    };
  };
}
