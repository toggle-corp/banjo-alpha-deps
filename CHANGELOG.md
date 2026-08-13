# Changelog

## [v0.2.0](https://github.com/toggle-corp/banjo-alpha-deps/compare/v0.1.0..v0.2.0) - 2026-08-13
### Changes:

#### 🚀  Features

- *(chart)* [**breaking**] Create tcpg extensions via post-install hook Job - ([a1fc3b6](https://github.com/toggle-corp/banjo-alpha-deps/commit/a1fc3b6c71df9fc8354a8fbb06c7b611ce93fb2c))
- *(chart)* [**breaking**] Replace MailHog with Mailpit - ([31c8e09](https://github.com/toggle-corp/banjo-alpha-deps/commit/31c8e098ac4a65f38976677516c817e66bb83c4c))
- *(chart)* Add per-instance MailHog SMTP catcher - ([f930e3c](https://github.com/toggle-corp/banjo-alpha-deps/commit/f930e3cca5175c9bfeb17d33ee8acbc4fc5be20b))
- *(chart)* Size Postgres from its resource limits, fix shutdown and /dev/shm - ([84878a3](https://github.com/toggle-corp/banjo-alpha-deps/commit/84878a3330a6ecb68861abe6cb88ec63c5bc228d))
- Add gitleaks - ([c3caadd](https://github.com/toggle-corp/banjo-alpha-deps/commit/c3caadd82d5a76695c915925dba0b4b519597a0b))

#### 🐛 Bug Fixes

- *(chart)* Quote mailhog label values - ([dccb615](https://github.com/toggle-corp/banjo-alpha-deps/commit/dccb615e601fee25d4779a5fbe3bda1b13b14dfd))
- *(chart)* Budget autovacuum memory, correct stale comments - ([56ea4cc](https://github.com/toggle-corp/banjo-alpha-deps/commit/56ea4cca5ef2243c37d6c069876e99a48cb28147))
- *(ci)* Build release notes from CHANGELOG.md instead of git-cliff --latest - ([41899a5](https://github.com/toggle-corp/banjo-alpha-deps/commit/41899a595f95c0c9ea7dba25159cabec578960c1))
- *(ci)* Fetch chart deps for the integration job, satisfy CI's shellcheck - ([abc5aef](https://github.com/toggle-corp/banjo-alpha-deps/commit/abc5aefdfd576ce1923dd6fa114c8a7cf98358ca))
- *(tests)* Stop the mailpit e2e racing the pod replacement - ([5ba5d32](https://github.com/toggle-corp/banjo-alpha-deps/commit/5ba5d32fe696d0f20079883903a8e070771c7e38))
- *(tests)* Tolerate log-flush lag when asserting a clean shutdown - ([ea167ff](https://github.com/toggle-corp/banjo-alpha-deps/commit/ea167ff5a6f33437916d6a8327520bbe118b2bd3))
- *(tests)* Wait for the final Postgres server, not the initdb temp one - ([255e7f3](https://github.com/toggle-corp/banjo-alpha-deps/commit/255e7f3618162a7aa3589c9a16835526526a2e75))

#### 🧪 Testing

- *(chart)* Add kind e2e suite; fix restricted-PSS Jobs, correct shutdown claim - ([258d7ff](https://github.com/toggle-corp/banjo-alpha-deps/commit/258d7ffff32f797341097ecdf80f09c39bf1f457))

#### ⚙️ Miscellaneous Tasks

- Widen pre-commit helm hook file filters - ([10d5103](https://github.com/toggle-corp/banjo-alpha-deps/commit/10d5103ef49f8dfdbd45db6e25908e60da3c23bf))

### 🍻 Pull Requests (1)
- (#1) [Feat(chart): size Postgres from its resource limits, bound memory, add kind e2e suite](https://github.com/toggle-corp/banjo-alpha-deps/pull/1)


## [v0.1.0] - 2026-07-28
### Changes:

#### 🚀  Features

- *(chart)* Label dependency ingresses for the deployment-metadata standard - ([f435105](https://github.com/toggle-corp/banjo-alpha-deps/commit/f4351059e3a619afed7a0ba73c56ffa89581cce1))
- *(chart)* Bootstrap credentials via Helm-hook Job, drop lookup pattern - ([2ed88b7](https://github.com/toggle-corp/banjo-alpha-deps/commit/2ed88b774d3900cedb9f7e0ff29f129f69cdea9e))
- *(ci)* Add release tooling via fugit, CI and release workflows - ([f93e9b4](https://github.com/toggle-corp/banjo-alpha-deps/commit/f93e9b45b47644a3eca789ccfab0cbf7f059c606))
- Cap MinIO S3 ingress body size via Traefik middleware - ([7d9e320](https://github.com/toggle-corp/banjo-alpha-deps/commit/7d9e3204eebc8a1af468faa3c3cf5b6a6161e006))
- Generate app-consumable S3 credentials secret for minio - ([1d8c176](https://github.com/toggle-corp/banjo-alpha-deps/commit/1d8c1761bb28e94212ada790b97fb987abb58bd5))
- Add minio - ([daf596b](https://github.com/toggle-corp/banjo-alpha-deps/commit/daf596bb211a05cc48094fd3321a9496b8077a1d))
- Adjust alpha configs - ([21f5872](https://github.com/toggle-corp/banjo-alpha-deps/commit/21f58726663af03b260057f8aeeaf6cc3bcc8cdd))
- Add garage - ([e8ba3fd](https://github.com/toggle-corp/banjo-alpha-deps/commit/e8ba3fdda1ff4fcf113db1e165745f8a426acc4d))
- Add dragonfly as subchart - ([a4adc17](https://github.com/toggle-corp/banjo-alpha-deps/commit/a4adc17a8778170528643bf179c2d5de3e07e40a))
- Setup umbrella chart - ([277335e](https://github.com/toggle-corp/banjo-alpha-deps/commit/277335eaf37716d6f2c6336cb6a2e4830f945997))
- Improvements - 03 - ([5bf2c01](https://github.com/toggle-corp/banjo-alpha-deps/commit/5bf2c0180a6b7ff56e2c6fc1d583d6b5207b78ce))
- Improvements - 02 - ([b9a228b](https://github.com/toggle-corp/banjo-alpha-deps/commit/b9a228b8a7c67a18265cd78bbfeb0502308ffa36))
- Improvements - ([a050245](https://github.com/toggle-corp/banjo-alpha-deps/commit/a0502451cfabd5e21ba61972695e352bdc0c2b33))

#### 🐛 Bug Fixes

- *(chart)* Stop ArgoCD pruning bootstrap-created credential Secrets - ([ff4b110](https://github.com/toggle-corp/banjo-alpha-deps/commit/ff4b1104baacc0791cb42bcfb3d791540069c02d))
- *(chart)* Make bootstrap Jobs runnable + address code-review - ([746fb68](https://github.com/toggle-corp/banjo-alpha-deps/commit/746fb68d6bc060b7a30ac7c5bcbbf7dfaa08f3b4))
- *(ci)* Unblock the first CI run - ([51dddf6](https://github.com/toggle-corp/banjo-alpha-deps/commit/51dddf62dfa6f7f1c58a9ba0a782409c091214bd))

#### 🚜 Refactor

- *(chart)* Drop the Garage subchart - ([a9ba69b](https://github.com/toggle-corp/banjo-alpha-deps/commit/a9ba69bb1e2f8eb84ff43faa7deff93edc867dce))
- *(chart)* Fold alpha overlay into values.yaml defaults - ([0b8cd4a](https://github.com/toggle-corp/banjo-alpha-deps/commit/0b8cd4a83fcf7ca6aca70d6d04a48f80a059f8a4))
- *(tcpg)* Rename init dump config to nested restore block - ([9831cea](https://github.com/toggle-corp/banjo-alpha-deps/commit/9831ceac5759d61a734b8c69d55208a07efd25df))
- *(tcpg)* Rename auth values block to init - ([d6e887d](https://github.com/toggle-corp/banjo-alpha-deps/commit/d6e887de4a47f990a5df9e0e1479c56c4144608e))

#### 📚 Documentation

- Prepare repo for public release on GitHub - ([744ea6e](https://github.com/toggle-corp/banjo-alpha-deps/commit/744ea6e2bfaac2e176b1f5a58b084c38b75d1c79))
- Fix stale usages.md references after the alpha merge - ([057f91a](https://github.com/toggle-corp/banjo-alpha-deps/commit/057f91ab57fd355aa98bf40c09df21d90cbb41c9))
- Treat MinIO S3 key as rotatable, not init-frozen - ([44e094d](https://github.com/toggle-corp/banjo-alpha-deps/commit/44e094d03004e1d37ed231ac1fa27b3d97a799f7))
- Document lookup-persist GitOps caveat for both secrets - ([4d68aa3](https://github.com/toggle-corp/banjo-alpha-deps/commit/4d68aa322cde2bea164b44123fc9078b6b4071ac))

#### 🧪 Testing

- Enable tcpg in tcpg unit suites - ([be0aaed](https://github.com/toggle-corp/banjo-alpha-deps/commit/be0aaed61db702ed3bd54088dd230a46d539b60d))

#### ⚙️ Miscellaneous Tasks

- Update helm chart sources - ([574671e](https://github.com/toggle-corp/banjo-alpha-deps/commit/574671e5c31ae743937d7d83c3ccbefe10df55e8))


<!-- generated by git-cliff -->
