{
  writeShellApplication,
  jq,
  openssh,
  coreutils,
}:
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
