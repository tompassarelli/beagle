{ config, lib, pkgs, ... }:

let
  cfg = config.myConfig.modules.example;
in
{
  options.myConfig.modules.example.enable = lib.mkEnableOption "Example service";
  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.hello ];
  };
}
