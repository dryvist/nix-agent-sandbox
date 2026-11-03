{
  writeShellApplication,
  jq,
  openssh,
  coreutils,
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
    ZCODE_JOB_SSH=${openssh}/bin/ssh
  ''
  + builtins.readFile ../scripts/zcode-job.sh;
}
