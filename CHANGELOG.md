# Changelog

## [1.14.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.13.4...v1.14.0) (2026-11-09)


### Features

* **sandbox:** ship the repo-check toolchain in the job image ([#201](https://github.com/dryvist/nix-agent-sandbox/issues/201)) ([4f36590](https://github.com/dryvist/nix-agent-sandbox/commit/4f3659008b0a39845e4d8303c2fafb28d60740d3))

## [1.13.4](https://github.com/dryvist/nix-agent-sandbox/compare/v1.13.3...v1.13.4) (2026-11-09)


### Bug Fixes

* **entrypoint:** open ready PRs and report success when the branch PR exists ([#198](https://github.com/dryvist/nix-agent-sandbox/issues/198)) ([af8d09d](https://github.com/dryvist/nix-agent-sandbox/commit/af8d09d41bd11b97529efdd8c4dfd360c2b2cdef))

## [1.13.3](https://github.com/dryvist/nix-agent-sandbox/compare/v1.13.2...v1.13.3) (2026-11-06)


### Bug Fixes

* **ci-resolver:** try local model tier before cloud ([#193](https://github.com/dryvist/nix-agent-sandbox/issues/193)) ([f700aca](https://github.com/dryvist/nix-agent-sandbox/commit/f700aca4919724dd70b51000df8e1321cedcf5cc))

## [1.13.2](https://github.com/dryvist/nix-agent-sandbox/compare/v1.13.1...v1.13.2) (2026-11-05)


### Bug Fixes

* **agent-cli:** retire local --repo mode and stop forwarding GitHub tokens ([#189](https://github.com/dryvist/nix-agent-sandbox/issues/189)) ([6fab8ba](https://github.com/dryvist/nix-agent-sandbox/commit/6fab8ba03a304e92c99ac2be27410801d4fce10e))

## [1.13.1](https://github.com/dryvist/nix-agent-sandbox/compare/v1.13.0...v1.13.1) (2026-11-05)


### Bug Fixes

* **zcode-job:** check repo visibility with an anonymous git read ([#190](https://github.com/dryvist/nix-agent-sandbox/issues/190)) ([69776ec](https://github.com/dryvist/nix-agent-sandbox/commit/69776ec1536e765ff2552be1bc97eb9053d19c59))

## [1.13.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.12.0...v1.13.0) (2026-11-04)


### Features

* **agent:** autonomous zcode run j-71f32b1ed94b42c6 ([#185](https://github.com/dryvist/nix-agent-sandbox/issues/185)) ([9fd896a](https://github.com/dryvist/nix-agent-sandbox/commit/9fd896a131b6bdf8df5f0161888ba8fc5ecc702a))

## [1.12.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.11.4...v1.12.0) (2026-11-04)


### Features

* **zcode-job:** require the public marker and verify repository visibility before dispatch ([#179](https://github.com/dryvist/nix-agent-sandbox/issues/179)) ([b991fd6](https://github.com/dryvist/nix-agent-sandbox/commit/b991fd635512703ab0b72f1e896d727f4ac2c219))


### Bug Fixes

* **zcode-job:** accept a visibility answer only when it is one object ([29f31d0](https://github.com/dryvist/nix-agent-sandbox/commit/29f31d0bd9b272bd9745666914dc3381f1e09bbc))
* **zcode-job:** bind the visibility check to the requested repository ([007bcf6](https://github.com/dryvist/nix-agent-sandbox/commit/007bcf6f4d2e09b3f75de5d53a7af27c6ff7dd2e))
* **zcode-job:** initialise the submitted flag before use ([733b660](https://github.com/dryvist/nix-agent-sandbox/commit/733b660443ab883cda7ab9054616752046d0c195))
* **zcode-job:** verify the job repository is public before continue ([d0cb59c](https://github.com/dryvist/nix-agent-sandbox/commit/d0cb59c21e60d92d865673939c5481a2b5857c45))

## [1.11.4](https://github.com/dryvist/nix-agent-sandbox/compare/v1.11.3...v1.11.4) (2026-11-03)


### Bug Fixes

* open agent PRs as drafts with no label ([#182](https://github.com/dryvist/nix-agent-sandbox/issues/182)) ([bc0c893](https://github.com/dryvist/nix-agent-sandbox/commit/bc0c893472a1284f98a8aa3ab5155f71b9df958c))

## [1.11.3](https://github.com/dryvist/nix-agent-sandbox/compare/v1.11.2...v1.11.3) (2026-11-02)


### Bug Fixes

* **dispatch:** make per-job ntfy posts opt-in (AGENT_DISPATCH_NTFY_JOBS) ([#177](https://github.com/dryvist/nix-agent-sandbox/issues/177)) ([99b20d1](https://github.com/dryvist/nix-agent-sandbox/commit/99b20d1e703a5752189937382569d2f4a584d10f))

## [1.11.2](https://github.com/dryvist/nix-agent-sandbox/compare/v1.11.1...v1.11.2) (2026-11-02)


### Bug Fixes

* **bao-agent:** keep the job alive after the agent token expires ([#175](https://github.com/dryvist/nix-agent-sandbox/issues/175)) ([4e802de](https://github.com/dryvist/nix-agent-sandbox/commit/4e802de87e729e5dc06f2da32f58469a83ea355e))

## [1.11.1](https://github.com/dryvist/nix-agent-sandbox/compare/v1.11.0...v1.11.1) (2026-11-02)


### Bug Fixes

* **entrypoint:** document that opencode requires AGENT_RUN_ID ([#173](https://github.com/dryvist/nix-agent-sandbox/issues/173)) ([2b9b96d](https://github.com/dryvist/nix-agent-sandbox/commit/2b9b96d838f0ea41596431e04733f152b0940518))

## [1.11.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.10.6...v1.11.0) (2026-11-02)


### Features

* **entrypoint:** select the OpenCode model from router order ([#171](https://github.com/dryvist/nix-agent-sandbox/issues/171)) ([3c981ac](https://github.com/dryvist/nix-agent-sandbox/commit/3c981ac074ebe399f5cf8870b654f65abc91ee74))

## [1.10.6](https://github.com/dryvist/nix-agent-sandbox/compare/v1.10.5...v1.10.6) (2026-11-02)


### Bug Fixes

* **opencode:** default the sandbox model to go-mimo-flash ([#169](https://github.com/dryvist/nix-agent-sandbox/issues/169)) ([fa01ba5](https://github.com/dryvist/nix-agent-sandbox/commit/fa01ba51f1af748ee33d815353b77fc162fc59f2))

## [1.10.5](https://github.com/dryvist/nix-agent-sandbox/compare/v1.10.4...v1.10.5) (2026-11-02)


### Bug Fixes

* **entrypoint:** take the Z.ai model only from OpenBao ZAI_MODEL ([#167](https://github.com/dryvist/nix-agent-sandbox/issues/167)) ([43baf59](https://github.com/dryvist/nix-agent-sandbox/commit/43baf59b613fe7be43aa4c84f300b9bf4f4dc72c))

## [1.10.4](https://github.com/dryvist/nix-agent-sandbox/compare/v1.10.3...v1.10.4) (2026-11-02)


### Bug Fixes

* **entrypoint:** pass a lowercase opencode log level ([#165](https://github.com/dryvist/nix-agent-sandbox/issues/165)) ([568ac5f](https://github.com/dryvist/nix-agent-sandbox/commit/568ac5f0be2efedf01ab5d7f1e9357fcfdd3a5f3))

## [1.10.3](https://github.com/dryvist/nix-agent-sandbox/compare/v1.10.2...v1.10.3) (2026-11-02)


### Bug Fixes

* **dispatch:** keep the container stderr stream in the run log ([#163](https://github.com/dryvist/nix-agent-sandbox/issues/163)) ([92322e5](https://github.com/dryvist/nix-agent-sandbox/commit/92322e591dc9c6a73cce5b1ff424a3b35f2081d3))

## [1.10.2](https://github.com/dryvist/nix-agent-sandbox/compare/v1.10.1...v1.10.2) (2026-11-02)


### Bug Fixes

* **tests:** expect opencode log flags in argv and read ENTRYPOINT ([3e86b57](https://github.com/dryvist/nix-agent-sandbox/commit/3e86b57e1ef4a48b07cdce693736ac7d5279c717))
* **tests:** expect opencode log flags in argv assertions ([#161](https://github.com/dryvist/nix-agent-sandbox/issues/161)) ([3e86b57](https://github.com/dryvist/nix-agent-sandbox/commit/3e86b57e1ef4a48b07cdce693736ac7d5279c717))

## [1.10.1](https://github.com/dryvist/nix-agent-sandbox/compare/v1.10.0...v1.10.1) (2026-11-02)


### Bug Fixes

* **entrypoint:** print opencode logs into the run log ([#159](https://github.com/dryvist/nix-agent-sandbox/issues/159)) ([81c686a](https://github.com/dryvist/nix-agent-sandbox/commit/81c686ae6222847d4ed2f6e2f07a604cafc90122))

## [1.10.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.9.1...v1.10.0) (2026-11-02)


### Features

* **dispatch:** return a redacted output tail and add zcode-job result --output ([#157](https://github.com/dryvist/nix-agent-sandbox/issues/157)) ([d25246f](https://github.com/dryvist/nix-agent-sandbox/commit/d25246f2d7548cc8f0f0cc0d3dc57e0f324d1794))

## [1.9.1](https://github.com/dryvist/nix-agent-sandbox/compare/v1.9.0...v1.9.1) (2026-11-02)


### Bug Fixes

* **opencode:** use the opencode-public-cheap and medium router groups; default ZCode to GLM-5.3 ([#155](https://github.com/dryvist/nix-agent-sandbox/issues/155)) ([05f6577](https://github.com/dryvist/nix-agent-sandbox/commit/05f6577873b98512b9279f02c273293cd93e40ee))

## [1.9.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.8.0...v1.9.0) (2026-11-01)


### Features

* run zcode and opencode jobs under per-tool OpenBao roles ([#153](https://github.com/dryvist/nix-agent-sandbox/issues/153)) ([31edec2](https://github.com/dryvist/nix-agent-sandbox/commit/31edec2113ecc0323cc1962f9b1f1723968d7756))

## [1.8.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.7.1...v1.8.0) (2026-11-01)


### Features

* **zcode-job:** wait for a one-line DONE or FAIL result ([#151](https://github.com/dryvist/nix-agent-sandbox/issues/151)) ([ffa4f99](https://github.com/dryvist/nix-agent-sandbox/commit/ffa4f99e8d9eea383a07a37363bcfd0c18cfd343))

## [1.7.1](https://github.com/dryvist/nix-agent-sandbox/compare/v1.7.0...v1.7.1) (2026-11-01)


### Bug Fixes

* **dispatch:** bypass the egress proxy for loopback and route OpenCode to public-cheap ([#149](https://github.com/dryvist/nix-agent-sandbox/issues/149)) ([ab4f346](https://github.com/dryvist/nix-agent-sandbox/commit/ab4f34647a04e998ad889bc1ac4f46137327e721))

## [1.7.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.6.0...v1.7.0) (2026-10-26)


### Features

* **dispatch:** refuse the write mint unless ai-untrusted-ok is true ([#147](https://github.com/dryvist/nix-agent-sandbox/issues/147)) ([6141ba4](https://github.com/dryvist/nix-agent-sandbox/commit/6141ba43ca8d91f193d40e58d7eb9b398fe6ad35))

## [1.6.0](https://github.com/dryvist/nix-agent-sandbox/compare/v1.5.5...v1.6.0) (2026-10-24)


### Features

* **sandbox:** ship git-town and ghq and branch from a fresh origin/HEAD ([#145](https://github.com/dryvist/nix-agent-sandbox/issues/145)) ([a880e8b](https://github.com/dryvist/nix-agent-sandbox/commit/a880e8bb0cc50755e90bcb64e16db73b44fdce25))

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
