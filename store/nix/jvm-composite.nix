{ pkgs, beaglePackage, beagleNativeBin, beagleRevision, storePackage, ... }:

((storeRoot: ((rawDispatcher: ((runtimePath: pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "beagle-store-jvm-composite";
  version = "1-${beagleRevision}";
  nativeBuildInputs = with pkgs; [ makeWrapper bash coreutils diffutils gnugrep babashka ];
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  installPhase = ''
    runHook preInstall

    mkdir -p "$out/libexec/store" "$out/libexec/bin"
    cp -r ${storeRoot}/. "$out/libexec/store/"
    test ! -L "$out/libexec/store"
    test -x "$out/libexec/store/bin/beagle-store-server"
    test -r "$out/libexec/store/runtime.manifest"
    test -x ${rawDispatcher}

    makeWrapper ${rawDispatcher} "$out/libexec/bin/beagle" \
      --set _BEAGLE_RACKET "${pkgs.racket}/bin/racket" \
      --set PLTCOLLECTS ":${beaglePackage}/share/racket-collects" \
      --set BEAGLE_STORE_HOME "$out/libexec/store" \
      --set BEAGLE_STORE_BIN "$out/libexec/store/bin" \
      --set BEAGLE_STORE_OUT "$out/libexec/store/out" \
      --set BEAGLE_STORE_RESOLVE "$out/libexec/store/out/resolve.clj" \
      --set BEAGLE_STORE_SERVER_CLASSPATH_FILE "$out/libexec/store/server.classpath" \
      --set BEAGLE_STORE_PACKAGED "1" \
      --set BEAGLE_STORE_SERVER_RUNTIME "jvm" \
      --set BEAGLE_STORE_JAVA "${pkgs.jdk}/bin/java" \
      --set BEAGLE_PACKAGED_COMPILER_COMMIT "${beagleRevision}" \
      --set BEAGLE_NATIVE_BIN "${beagleNativeBin}" \
      --set _BEAGLE_SELFHOST_EXACT_NATIVE_BIN "${beagleNativeBin}" \
      --prefix PATH : "${runtimePath}"

    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck

    BEAGLE_JVM_COMPOSITE_TEST_BB="${pkgs.babashka}/bin/bb" \
    BEAGLE_JVM_COMPOSITE_TEST_CMP="${pkgs.diffutils}/bin/cmp" \
    BEAGLE_JVM_COMPOSITE_TEST_ENV="${pkgs.coreutils}/bin/env" \
    BEAGLE_JVM_COMPOSITE_TEST_GREP="${pkgs.gnugrep}/bin/grep" \
    BEAGLE_JVM_COMPOSITE_TEST_JAVA="${pkgs.jdk}/bin/java" \
    BEAGLE_JVM_COMPOSITE_TEST_RAW_DISPATCHER="${rawDispatcher}" \
    BEAGLE_JVM_COMPOSITE_TEST_STORE_ROOT="${storeRoot}" \
      ${pkgs.bash}/bin/bash ${../tests/package_jvm_composite_smoke.sh} "$out"

    runHook postInstallCheck
  '';
  meta = {
    description = "Immutable Beagle dispatcher and packaged JVM Store runtime";
    license = with pkgs.lib.licenses; [ mit asl20 ];
    platforms = pkgs.lib.platforms.unix;
  };
  passthru = {
    runtimeRoot = "${finalAttrs.finalPackage}/libexec/store";
    babashkaClasspath = "${finalAttrs.finalPackage}/libexec/store/out";
    runtimeManifest = "${finalAttrs.finalPackage}/libexec/store/runtime.manifest";
    beagleExecutable = "${finalAttrs.finalPackage}/libexec/bin/beagle";
    storePackage = storePackage;
    beaglePackage = beaglePackage;
  };
})) (pkgs.lib.makeBinPath (with pkgs; [
    racket
    babashka
    bun
    clojure
    jdk
    python3
    bash
    coreutils
    gnugrep
    gnused
    gawk
    findutils
    util-linux
    ripgrep
  ])))) "${beaglePackage}/bin/.beagle-wrapped")) storePackage.runtimeRoot)
