{ config, lib, ... }:

{
  networking = rec {
    hostName = "myhost";
    domain = "${hostName}.local";
  };
  boot = assert config.boot.isContainer; {
    kernelModules = [ "kvm-amd" ];
  };
}
