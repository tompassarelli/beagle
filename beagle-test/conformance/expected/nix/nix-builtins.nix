{ lib, pkgs, ... }:

let
  nodes = builtins.mapAttrs (name: config: config.system.build.toplevel) {
    foo = 1;
    bar = 2;
  };
  json = builtins.toJSON {
    version = 1;
    name = "test";
  };
in
{
  data = nodes;
  meta = json;
  count = builtins.length [ 1 2 3 ];
  merged = ({
    a = 1;
  } // {
    b = 2;
  });
  path = ./hardware.nix;
}
