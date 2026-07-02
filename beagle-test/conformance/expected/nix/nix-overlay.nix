final: prev: {
  my-tool = prev.callPackage ./my-tool.nix { };
  hello = prev.hello.overrideAttrs (old: {
    version = "9.99";
  });
}
