# THC's runtime with the Truffle compiler settings its launcher hardcodes
# (src/main/java/thc/Main.java) read from system properties instead, so
# thc/README.md's experiments can vary them per run, for example
#   JAVA_OPTS=-Dthc.tune.MaximumGraalGraphSize=400000
# Unset properties keep THC's own values, so with no JAVA_OPTS this
# behaves exactly like ./thc-runtime.nix.
{ sources ? import ../../npins
, pkgs ? import sources.nixpkgs-thc { }
,
}:
(import ./thc-runtime.nix { inherit pkgs; }).overrideAttrs (old: {
  pname = "thc-runtime-tunable";
  postPatch = (old.postPatch or "") + ''
    substituteInPlace src/main/java/thc/Main.java \
      --replace-fail '"engine.MultiTier", "false"' \
        '"engine.MultiTier", System.getProperty("thc.tune.MultiTier", "false")' \
      --replace-fail '"engine.SingleTierCompilationThreshold", "10000"' \
        '"engine.SingleTierCompilationThreshold", System.getProperty("thc.tune.SingleTierCompilationThreshold", "10000")' \
      --replace-fail '"compiler.CompilationTimeout", "30"' \
        '"compiler.CompilationTimeout", System.getProperty("thc.tune.CompilationTimeout", "30")' \
      --replace-fail '"compiler.MaximumGraalGraphSize", "100000"' \
        '"compiler.MaximumGraalGraphSize", System.getProperty("thc.tune.MaximumGraalGraphSize", "100000")'
  '';
})
