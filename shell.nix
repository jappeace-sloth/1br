{
  hpkgs ? import ./nix/hpkgs.nix {},
  pkgs ? import ./nix/pkgs.nix {},
}:
hpkgs.shellFor {
  packages = ps: [ ps."1br" ];
  withHoogle = false;

  buildInputs = [
    hpkgs.haskell-language-server
    pkgs.ghcid
    pkgs.cabal-install
  ];
}
