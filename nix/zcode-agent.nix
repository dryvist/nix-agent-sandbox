{
  writeShellApplication,
  jq,
  curl,
  coreutils,
  zcodeJob,
}:
writeShellApplication {
  name = "zcode-agent";
  runtimeInputs = [
    jq
    curl
    coreutils
    zcodeJob
  ];
  text = builtins.readFile ../scripts/zcode-agent.sh;
}
