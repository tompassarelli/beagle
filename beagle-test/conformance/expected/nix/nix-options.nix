{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.custom;
in
{
  options.hardware.custom = {
    enable = lib.mkEnableOption "custom hardware";
    threshold = lib.mkOption {
      type = lib.types.int;
      default = 80;
      description = "Threshold percentage";
    };
  };
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.htop ];
    systemd.services.custom-threshold = {
      description = "Set threshold";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.runtimeShell} -c 'echo ${toString cfg.threshold} > /sys/threshold'";
      };
    };
  };
}
