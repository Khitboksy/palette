{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
}:

pkgs.mkShell {
  name = "palette-test";

  packages = with pkgs; [
    fish
    pastel
    jq
    fzf
    wl-clipboard-rs
    tmux
    coreutils
  ];

  # Set the palette file to the test file in the repo
  PALETTE_FILE = "${toString ./.}/test-palette.json";

  # Replace current shell with fish that sources palette.fish and runs palette
  #   If you do not have fish installed, its fresh, if you do have fish installed its your config+palette.
  shellHook = ''
    exec ${lib.getExe pkgs.fish} -c "
        source ${toString ./.}/palette.fish
        clear
        and palette
    "
  '';
}
