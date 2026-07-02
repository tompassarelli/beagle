{ pkgs, ... }:

{
  script = pkgs.writeScriptBin "hello" ''
    #!${pkgs.bash}/bin/bash
    echo hello world
  '';
  config = {
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="usb"
      ATTR{idVendor}=="${vendor.id}"
    '';
  };
}
