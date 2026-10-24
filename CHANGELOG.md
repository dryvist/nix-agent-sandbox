# Changelog

## [1.5.5](https://github.com/dryvist/nix-agent-sandbox/compare/v1.5.4...v1.5.5) (2026-10-24)


### Bug Fixes

* **entrypoint:** close Codex stdin and fail on an empty final message ([#143](https://github.com/dryvist/nix-agent-sandbox/issues/143)) ([439de00](https://github.com/dryvist/nix-agent-sandbox/commit/439de0032014300c0d9e04f5f842372ee7deb3b1))

## [1.5.4](https://github.com/dryvist/nix-agent-sandbox/compare/v1.5.3...v1.5.4) (2026-10-19)


### Bug Fixes

* **bao-agent:** read the router key from its own leaf ([#136](https://github.com/dryvist/nix-agent-sandbox/issues/136)) ([2447682](https://github.com/dryvist/nix-agent-sandbox/commit/2447682825bdaad805fcc8fe0ac5d94b7482dfb7))

## [1.5.3](https://github.com/dryvist/nix-agent-sandbox/compare/v1.5.2...v1.5.3) (2026-10-18)


### Bug Fixes

* **entrypoint:** export the prompt file contents to the OpenBao Agent child ([#134](https://github.com/dryvist/nix-agent-sandbox/issues/134)) ([4e29fbc](https://github.com/dryvist/nix-agent-sandbox/commit/4e29fbc20f7764ab626ab4c94dc32e2b1d719809))

## [1.5.2](https://github.com/dryvist/nix-agent-sandbox/compare/v1.5.1...v1.5.2) (2026-10-18)


### Bug Fixes

* **ci:** map the zcode job module to its flake check ([afcaf3e](https://github.com/dryvist/nix-agent-sandbox/commit/afcaf3e4770a6d3063daac8822a12b7aa0e27f6a))
* **zcode-job:** accept owner wildcards in the allowedRepos option type ([598a26b](https://github.com/dryvist/nix-agent-sandbox/commit/598a26bdfefc668d0be788d1406a741f7b4cd312))
* **zcode-job:** accept owner wildcards in the allowedRepos option type ([#132](https://github.com/dryvist/nix-agent-sandbox/issues/132)) ([38820ed](https://github.com/dryvist/nix-agent-sandbox/commit/38820ed7bc9435d8fe6ec41859a1bb8727982c09))

## [1.5.1](https://github.com/dryvist/nix-agent-sandbox/compare/v1.5.0...v1.5.1) (2026-10-18)


### Bug Fixes

* **dispatch:** validate created PR identity case-insensitively ([34f3c18](https://github.com/dryvist/nix-agent-sandbox/commit/34f3c18bb4c2f3d4e629071d1da80c7d3398a4c4))
* **entrypoint:** fail when PR lookup returns no URL ([9bd0ed0](https://github.com/dryvist/nix-agent-sandbox/commit/9bd0ed0203f274ab5a747c9819e60cb20bd6b9a6))
* **pr:** require human review label for agent PRs ([#124](https://github.com/dryvist/nix-agent-sandbox/issues/124)) ([b746028](https://github.com/dryvist/nix-agent-sandbox/commit/b74602821938ffc0fbe8315f49a7df7ba43ff6a2))

## [1.5.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.4.0...v1.5.0) (2026-10-18)


### Features

* **zcode:** run the batch profile without tracker access ([#127](https://github.com/dryvist/nix-agent-sandbox/issues/127)) ([f117930](https://github.com/dryvist/nix-agent-sandbox/commit/f1179302023b8a0bcfe7cd37c4fa20b7e084de08))

## [1.4.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.3.1...v1.4.0) (2026-10-15)


### Features

* **image:** package Zammad MCP dependencies ([e026324](https://github.com/dryvist/nix-agent-sandbox/commit/e0263245b88cca444316ffd56496caf647c5aeaf))

## [1.3.1](https://github.com/dryvist/nix-agent-sandbox/compare/v1.3.0...v1.3.1) (2026-10-15)


### Bug Fixes

* **entrypoint:** quote the repo-less README without shellcheck findings ([28d871a](https://github.com/dryvist/nix-agent-sandbox/commit/28d871ab724f0d283eec601deaf9fd17c2e66e35))

## [1.3.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.2.3...v1.3.0) (2026-10-15)


### Features

* **dispatch:** allow repo-less zcode mirror sessions ([e3ac62b](https://github.com/dryvist/nix-agent-sandbox/commit/e3ac62b7eedcee859c9d6bb51b37bd58349b76b6))

## [1.2.3](https://github.com/dryvist/nix-agent-sandbox/compare/v1.2.2...v1.2.3) (2026-10-15)


### Bug Fixes

* **dispatch:** mint wrapped SecretIDs with the bao CLI ([108acfc](https://github.com/dryvist/nix-agent-sandbox/commit/108acfc29eb233bf3efd22268fb3f4e84c63a965))

## [1.2.2](https://github.com/dryvist/nix-agent-sandbox/compare/v1.2.1...v1.2.2) (2026-10-14)


### Bug Fixes

* **dispatch:** mint the agents token by repository owner name ([#105](https://github.com/dryvist/nix-agent-sandbox/issues/105)) ([4d21c4a](https://github.com/dryvist/nix-agent-sandbox/commit/4d21c4ac249abe08c6eabd21475a744ee72c922b))

## [1.2.1](https://github.com/dryvist/nix-agent-sandbox/compare/v1.2.0...v1.2.1) (2026-10-14)


### Bug Fixes

* **entrypoint:** define the agent-router provider for the OpenCode batch run ([#103](https://github.com/dryvist/nix-agent-sandbox/issues/103)) ([37e261e](https://github.com/dryvist/nix-agent-sandbox/commit/37e261eb3c457494e2e976e93bf75cb67d897c12))

## [1.2.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.1.1...v1.2.0) (2026-10-13)


### Features

* **sandbox:** add job credentials, MCP configuration and repository scope checks ([#101](https://github.com/dryvist/nix-agent-sandbox/issues/101)) ([1ec8484](https://github.com/dryvist/nix-agent-sandbox/commit/1ec84845a890744d5c651a7a60f7da8540400423))

## [1.1.1](https://github.com/dryvist/nix-agent-sandbox/compare/v1.1.0...v1.1.1) (2026-10-12)


### Bug Fixes

* **dispatch:** route batch agents through the router ([#97](https://github.com/dryvist/nix-agent-sandbox/issues/97)) ([c652be8](https://github.com/dryvist/nix-agent-sandbox/commit/c652be84b98882ce3e5d3bdb7178419119a6e9db))

## [1.1.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.0.0...v1.1.0) (2026-10-11)


### Features

* **ci-resolver:** add the org CI failure reconciler ([#92](https://github.com/dryvist/nix-agent-sandbox/issues/92)) ([5df3235](https://github.com/dryvist/nix-agent-sandbox/commit/5df32353fb5e0f7e4f12d4275f034fd987a5d602))
* **dispatch:** add a fix mode that publishes a guarded patch from the host ([#91](https://github.com/dryvist/nix-agent-sandbox/issues/91)) ([f0062c3](https://github.com/dryvist/nix-agent-sandbox/commit/f0062c3e2eeee81f7b528ef7a2cba4dc33a875c4))
* **dispatch:** scan fix-mode additions with gitleaks on the host ([#96](https://github.com/dryvist/nix-agent-sandbox/issues/96)) ([7e2cecd](https://github.com/dryvist/nix-agent-sandbox/commit/7e2cecd35d9a42456f95e84cfd550de7def52d61))


### Bug Fixes

* **repo-groups:** update the private docs repository name ([#95](https://github.com/dryvist/nix-agent-sandbox/issues/95)) ([61380ac](https://github.com/dryvist/nix-agent-sandbox/commit/61380ac9450b9cd400c85e08c7291d29b08ef2c5))

## 1.0.0 (2026-10-11)


### ⚠ BREAKING CHANGES

* profiles use `env` (a list of variable names) in place of `kv`, and the container no longer fetches secrets itself.

### Features

* **agent-cli:** inject subscription-OAuth creds per run ([#9](https://github.com/dryvist/nix-agent-sandbox/issues/9)) ([4b480e9](https://github.com/dryvist/nix-agent-sandbox/commit/4b480e986772a4489feaf2269d77e4128987c436))
* **agent-cli:** persist run transcripts to a host spool for Splunk ([#18](https://github.com/dryvist/nix-agent-sandbox/issues/18)) ([43bacd2](https://github.com/dryvist/nix-agent-sandbox/commit/43bacd2d8978e1c5ca12fbb070785adfc1681d8b))
* **agent-cli:** spool daily CLI logs ([#50](https://github.com/dryvist/nix-agent-sandbox/issues/50)) ([49c7583](https://github.com/dryvist/nix-agent-sandbox/commit/49c7583b00d047902499fe5b4744ec29fc1cc23f))
* **agent-dispatch:** add the agent-dispatch job dispatcher ([8530231](https://github.com/dryvist/nix-agent-sandbox/commit/8530231fe7e9055d8b0a640cb16d3fa9dbe2f901))
* **agent-dispatch:** add the host job dispatcher and its SSH entrypoint ([b0bfc41](https://github.com/dryvist/nix-agent-sandbox/commit/b0bfc41042c87778306fb5ed1d9aac8f0def820c))
* **agent-dispatch:** renew the login token while a job runs ([3ae6a2f](https://github.com/dryvist/nix-agent-sandbox/commit/3ae6a2f3866eeac75b12aa58432137235b6eccb7))
* **agent-dispatch:** renew the login token while a job runs ([38f9adf](https://github.com/dryvist/nix-agent-sandbox/commit/38f9adf2df428a72e3124b6c7f175ce9bfd8bc2d))
* **agent-dispatch:** terminal sessions, public-only repositories, signed publish ([#71](https://github.com/dryvist/nix-agent-sandbox/issues/71)) ([b5587ff](https://github.com/dryvist/nix-agent-sandbox/commit/b5587ffb8256c396bbd3cef245f22011d258876e))
* **agent-sandbox:** add Qwen Code CLI support ([#60](https://github.com/dryvist/nix-agent-sandbox/issues/60)) ([aca08df](https://github.com/dryvist/nix-agent-sandbox/commit/aca08dfa94510820ef3c60abf3cfc4f01de06af5))
* **agent:** default sweep concurrency to eight ([d93e5d4](https://github.com/dryvist/nix-agent-sandbox/commit/d93e5d4bffd138e56c7990c18487fc9c856566a4))
* **agent:** default sweep concurrency to eight ([b2cc3ca](https://github.com/dryvist/nix-agent-sandbox/commit/b2cc3ca702dc792114dc36a255c16ba8dc6a3223))
* container resource ceilings, hardening flags, timeout, gitleaks pre-push ([#16](https://github.com/dryvist/nix-agent-sandbox/issues/16)) ([b13c890](https://github.com/dryvist/nix-agent-sandbox/commit/b13c89095aa75169b38b7aad63967b82531f7896))
* **dispatch:** add a check verb and alert on missing credential files ([#72](https://github.com/dryvist/nix-agent-sandbox/issues/72)) ([fcae8b5](https://github.com/dryvist/nix-agent-sandbox/commit/fcae8b54b92e9b2077c6ed14ea9377d4552403f4))
* **dispatch:** add qwen-code batch tool and cursor-agent batch key ([#77](https://github.com/dryvist/nix-agent-sandbox/issues/77)) ([ed12bc5](https://github.com/dryvist/nix-agent-sandbox/commit/ed12bc5563a9a00559a651c69eac314d40b08431))
* **egress:** allow provider downloads ([#54](https://github.com/dryvist/nix-agent-sandbox/issues/54)) ([9151b1b](https://github.com/dryvist/nix-agent-sandbox/commit/9151b1b0a87e720d04e5df38309485d868df394f))
* **image:** add OpenCode and Cursor Agent ([#46](https://github.com/dryvist/nix-agent-sandbox/issues/46)) ([9632563](https://github.com/dryvist/nix-agent-sandbox/commit/9632563c8d8f3d85c9c4b811180a2329032b9373))
* initial scaffold - agent image, dispatch CLI, egress allowlist ([b256999](https://github.com/dryvist/nix-agent-sandbox/commit/b2569991e3fbc4ed2b3409aac647a331dd110209))
* OpenBao task profiles, GitHub App tokens, egress-proxied remote runs ([7f0f5b5](https://github.com/dryvist/nix-agent-sandbox/commit/7f0f5b5494d1dd7078ddcaf7545e5913c07b6217))
* repo groups + agent sweep fan-out ([#11](https://github.com/dryvist/nix-agent-sandbox/issues/11)) ([5c7d56f](https://github.com/dryvist/nix-agent-sandbox/commit/5c7d56f2d22e14c5d18c7006cd4b1014d6d9b548))
* reuse one dispatcher session for jobs ([#43](https://github.com/dryvist/nix-agent-sandbox/issues/43)) ([dfea2a8](https://github.com/dryvist/nix-agent-sandbox/commit/dfea2a833cec02f9b96b284c26dc0cf997ba8789))
* **zcode-job:** add --tool option to start ([#81](https://github.com/dryvist/nix-agent-sandbox/issues/81)) ([e222804](https://github.com/dryvist/nix-agent-sandbox/commit/e2228047a450a37b941d74543e5be82ce686f3a5))
* **zcode-job:** add the restricted SSH offload client ([#40](https://github.com/dryvist/nix-agent-sandbox/issues/40)) ([75a5134](https://github.com/dryvist/nix-agent-sandbox/commit/75a51340aab8d0c820f9f034fa5a11755f1703d7))
* **zcode:** add persistent Web runtime ([#42](https://github.com/dryvist/nix-agent-sandbox/issues/42)) ([82d44e9](https://github.com/dryvist/nix-agent-sandbox/commit/82d44e91da62f4b5f0abbfa67556d2bc4ebce53b))


### Bug Fixes

* **agent-cli,entrypoint:** canary follow-ups — codex repo-check, dead-cred guard, portable epoch ([#10](https://github.com/dryvist/nix-agent-sandbox/issues/10)) ([aa05c50](https://github.com/dryvist/nix-agent-sandbox/commit/aa05c507aecede9764e1dcf9f11b3a1098d56e1b))
* **agent-cli:** mint GitHub write tokens on the launcher, not in-container ([47d34a4](https://github.com/dryvist/nix-agent-sandbox/commit/47d34a4c104fed650b77fd76e6ee349da11aa396))
* **agent-cli:** remove orphaned container when OAuth injection fails ([#14](https://github.com/dryvist/nix-agent-sandbox/issues/14)) ([5a117ee](https://github.com/dryvist/nix-agent-sandbox/commit/5a117ee330106fe957fa5cad7ffb178dba00a549))
* **agent-cli:** string-form github-write mint params — list/number shape is denied ([#6](https://github.com/dryvist/nix-agent-sandbox/issues/6)) ([f82ed35](https://github.com/dryvist/nix-agent-sandbox/commit/f82ed3543b36ab7b9fe8e8dbbbbf50c397bd6621))
* **agent:** align sweep help with eight-run default ([b95e5ae](https://github.com/dryvist/nix-agent-sandbox/commit/b95e5aed0ef454e0374f3d569d13ed904a46ceff))
* **ci:** focus pull request flake checks ([#65](https://github.com/dryvist/nix-agent-sandbox/issues/65)) ([ed6a23d](https://github.com/dryvist/nix-agent-sandbox/commit/ed6a23db42fa00352798bca0c63207fd28b74b36))
* **flake:** repin nix-ai input to main ([#7](https://github.com/dryvist/nix-agent-sandbox/issues/7)) ([17758a4](https://github.com/dryvist/nix-agent-sandbox/commit/17758a4c0733d5fe01cfb8a6d8221daf70a5348f))
* make zcode-job help config-free ([43f8141](https://github.com/dryvist/nix-agent-sandbox/commit/43f8141613de6b15e8b69f264a45ebec2f92773e))
* make zcode-job help config-free ([f885685](https://github.com/dryvist/nix-agent-sandbox/commit/f885685cf3370e77418b27ac56e903937734849a))


### Refactoring

* take run credentials from the caller's environment ([ed5cb73](https://github.com/dryvist/nix-agent-sandbox/commit/ed5cb730f9cba2d4caa90e37dc9f8e9ce172b604))
