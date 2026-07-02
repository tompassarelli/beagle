{ pkgs, lib, config, ... }:

{
  hello = pkgs.writeShellScriptBin "hello" ''
    #!${pkgs.bash}/bin/bash
    set -e

    NAME="''${USER:-world}"
    printf '%s\n' ''${greetings[@]}
    echo "Hello, $NAME"
  '';
  literals = ''
    pair = '''';
    dollar = "$";
  '';
}
