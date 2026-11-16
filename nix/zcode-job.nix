{
  stdenv,
  writeShellApplication,
  jq,
  openssh,
  coreutils,
  # macOS grants Local Network access per binary: the system ssh holds it, while
  # a Nix store ssh gets EHOSTUNREACH on LAN addresses.
  isDarwin ? stdenv.hostPlatform.isDarwin,
  sshBin ? if isDarwin then "/usr/bin/ssh" else "${openssh}/bin/ssh",
}:
# curl comes from the host; it stays off runtimeInputs so the bats suite can
# stand it in from PATH.
writeShellApplication {
  name = "zcode-job";
  runtimeInputs = [
    jq
    coreutils
  ];
  text = ''
    ZCODE_JOB_SSH=${sshBin}
  ''
  + builtins.readFile ../scripts/zcode-job.sh;
}
