# CI Pipeline

This document describes the n3x continuous integration pipeline: what it builds and tests, how caching works, runner requirements, and how to extend it.

## Pipeline Architecture

The pipeline runs 22 jobs across 5 tiers, all in parallel (no cross-tier dependencies). Every push, pull request, and manual dispatch triggers the full pipeline. In-progress runs for the same branch are cancelled automatically.

```
Tier 1 — Eval/lint (4 jobs)                    ← Nix only, fast, no builds
Tier 2 — Nix package build (2 jobs)             ← Nix builds .deb packages (x86_64 + aarch64)
Tier 3 — NixOS build + VM test (7 jobs)         ← Nix builds VMs and runs tests (KVM)
Tier 4 — ISAR build, all machines (4 jobs)      ← kas-container, build-only verification
Tier 5 — ISAR build + Debian VM test (5 jobs)   ← kas-container builds + Nix VM tests (KVM)
```

Tiers 3 and 5 both build images and run VM tests, but they use different build tools. Tier 3 is entirely within Nix — a single `nix build` command builds the NixOS VMs and runs the test. Tier 5 requires two tools: `kas-container` (ISAR/BitBake) builds the Debian disk images, then Nix registers and tests them. Tier 4 exists separately because it builds ISAR images for all machines — including hardware targets and architectures that have no VM tests in CI — as pure build verification.

All 22 jobs start simultaneously. The pipeline wall-clock time is determined by the slowest job (typically `Build: debian-qemuamd64` at ~27 minutes with warm cache).

### Why NixOS and Debian tests are structured differently

NixOS VM tests (Tier 3) are each a single `nix build` command. Nix builds the test VMs and runs the test script in one derivation — there is no separate "build" step because Nix manages the entire lifecycle.

Debian VM tests require a fundamentally different approach because ISAR images are built outside of Nix (via `kas-container`/BitBake). The ISAR build output (a `.wic` disk image) must be registered into the Nix store before any Nix-based test can reference it. This creates a two-tool pipeline that cannot be expressed as a single Nix derivation, and it drives the separation into two tiers:

- **Tier 4 (ISAR builds, all machines)**: Builds every ISAR variant for every target machine — including hardware targets (jetson-orin-nano, amd-v3c18i) and architectures (arm64) that have no corresponding VM tests in CI. This is pure build verification: does the image build succeed?

- **Tier 5 (Debian VM tests, qemuamd64 only)**: Builds only the specific qemuamd64 ISAR variants needed for each test group, registers them in the Nix store, then runs the NixOS VM test driver against the registered images. Only qemuamd64 variants are tested because VM tests require an emulatable architecture on the CI runner.

Tier 4 and Tier 5 intentionally overlap on qemuamd64 builds — both build some of the same variants. This duplication exists because Tier 5 jobs need the build artifacts locally (in the same job) to register them in the Nix store, while Tier 4 runs builds for all machines including those Tier 5 doesn't cover.

### Concurrency and cancellation

```yaml
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: true
```

Pushes to the same branch cancel any in-progress run, preventing wasted runner minutes on superseded commits.

**What happens at the resource level when a run is cancelled**: GitHub Actions runners are ephemeral VMs — each job gets a freshly provisioned VM that is destroyed after the job completes (or is cancelled). There is no persistent filesystem across jobs or runs. The only persistence mechanism is `actions/cache`, which has a 10 GB limit per repository.

When a running job is cancelled, GitHub sends SIGTERM to the runner process, then SIGKILL after a grace period. The critical question is whether this can corrupt the `actions/cache` data:

- **Cache writes are atomic**: `actions/cache` saves the cache in a "Post" step that runs after all main steps complete. The Post step compresses the cache directory and uploads it as a single blob. If the job is killed before the Post step runs — which is the normal case for cancellation — **no cache write occurs at all**. The previous cache entry remains intact.
- **Partial uploads are discarded**: Even if cancellation occurs during the Post step's upload, GitHub's cache API treats uploads as atomic — a partially uploaded cache entry is never served. The next run restores from the last successfully saved cache.
- **`magic-nix-cache-action`** (Nix store cache) follows the same pattern: it uploads cached store paths in its Post step. Cancellation before that step means no Nix cache update, but no corruption either.

This means cancellation is always safe: the worst case is that a cancelled run's build progress is lost (not cached), and the next run starts from the last successful cache state. There is no risk of corrupted sstate, corrupted downloads, or a broken Nix store cache.


## Job Reference

### Tier 1 — Eval/lint

Fast Nix-only checks that catch evaluation errors and formatting drift.

| Job | What it does | Runner |
|-----|-------------|--------|
| `Nix evaluation` | `nix flake metadata` + `nix eval` for devShells and packages attrNames | ubuntu-latest |
| `Nix formatting` | `nix build '.#checks.x86_64-linux.lint-nixpkgs-fmt'` | ubuntu-latest |
| `Debian package parity` | `nix build '.#checks.x86_64-linux.lint-debian-package-parity'` | ubuntu-latest |
| `VERSION file semver` | `nix build '.#checks.x86_64-linux.lint-version'` | ubuntu-latest |

**Why targeted eval instead of `nix flake check`**: `nix flake check` evaluates ALL flake outputs — not just `checks.*`, but also `packages.*`, `devShells.*`, `nixosConfigurations.*`, and others. It validates their types and, without `--no-build`, builds every check. The Nix evaluator's memory usage grows monotonically during evaluation (memory is not released between derivations). For this flake, evaluating every NixOS VM test derivation (~1-2 GB each for the NixOS module system) exceeds the runner's ~7 GB available RAM, causing OOM kills.

`nix flake check --no-build` would skip the builds but still performs the full evaluation, which is where the memory problem occurs. The targeted `nix eval` approach validates that the flake's key output attributes evaluate successfully without attempting to evaluate the entire output tree at once.

The remaining checks (formatting, package parity, packages) are run as individual `nix build '.#checks...'` commands in separate jobs. Each job evaluates only its own check derivation, keeping memory usage bounded. This pattern — targeted eval for validation plus individual check builds — is the standard approach used by major Nix projects (nixpkgs uses `nix-eval-jobs` with memory-bounded workers; DeterminateSystems projects split lint/build/test into separate jobs).

**Future improvement**: [NixOS/nix#8881](https://github.com/NixOS/nix/issues/8881) (171 upvotes, open since 2023) requests selective `nix flake check` execution (e.g., `nix flake check .#my-check`). If implemented, this would allow running `nix flake check` per-check in CI while retaining full schema validation. The `checks.*` output is currently a flat namespace (no nested attrsets allowed), but our naming convention (`lint-*`, `pkg-*`, `nixos-*`, `debian-*`) already supports pattern-based grouping for CI matrix generation.

### Tier 2 — Nix package build

| Job | What it does | Runner |
|-----|-------------|--------|
| `Debian packages (x86_64)` | `nix build '.#checks.x86_64-linux.pkg-debian-x86_64'` | ubuntu-latest |
| `Debian packages (aarch64)` | `nix build '.#checks.aarch64-linux.pkg-debian-aarch64'` | ubuntu-24.04-arm |

Validates that the custom `.deb` packages build successfully for both architectures. The x86_64 check validates k3s and k3s-system-config packages. The aarch64 check validates only the k3s package (k3s-system-config is `Architecture: all` and only needs one build). The aarch64 job runs on GitHub's native ARM64 runner, avoiding the need for QEMU emulation.

**Why this is a "check" and not a "package"**: The `pkg-debian-*` entries live in `checks.*` rather than `packages.*` because their purpose is build verification — they build the packages and assert the expected `.deb` files exist. The packages themselves are also available as `packages.{x86_64,aarch64}-linux.k3s` etc. for direct use.

### Tier 3 — NixOS VM tests

7 NixOS integration tests using the NixOS VM test driver. Each test builds NixOS VM(s) from the Nix flake and runs a Python test script against them under QEMU/KVM.

| Job | VMs | What it tests |
|-----|-----|--------------|
| `nixos-smoke-vm-boot` | 1 | Basic NixOS VM boots and reaches multi-user target |
| `nixos-smoke-two-vm-network` | 2 | Two VMs can communicate over VDE virtual network |
| `nixos-smoke-k3s-service-starts` | 1 | k3s service starts and API server responds |
| `nixos-k3s-cluster-simple` | 2 | 2-node k3s cluster with flat networking |
| `nixos-k3s-cluster-vlans` | 2 | 2-node cluster over VLAN-tagged interfaces |
| `nixos-k3s-cluster-bonding-vlans` | 2 | 2-node cluster over bonded+VLAN interfaces |
| `nixos-k3s-cluster-dhcp-simple` | 2 | 2-node cluster with DHCP-assigned addresses |

All tests run on `ubuntu-latest` (x86_64) with KVM enabled via `system-features = nixos-test benchmark big-parallel kvm`.

### Tier 4 — ISAR builds (build-only)

4 jobs, one per target machine. Each job builds all ISAR image variants for its machine sequentially, maximizing BitBake sstate cache hits within the job.

| Job | Machine | Runner | Arch | Variants |
|-----|---------|--------|------|----------|
| `Build: debian-qemuamd64` | qemuamd64 | ubuntu-latest | x86_64 | 11 (base, base-swupdate, agent, 4×server-{profile}-server-{1,2}) |
| `Build: debian-qemuarm64` | qemuarm64 | ubuntu-24.04-arm | arm64 | 2 (base, server) |
| `Build: debian-jetson-orin-nano` | jetson-orin-nano | ubuntu-24.04-arm | arm64 | 2 (base, server) |
| `Build: debian-amd-v3c18i` | amd-v3c18i | ubuntu-latest | x86_64 | 1 (agent) |

**Native vs cross-compilation**: The CI workflow detects when runner architecture matches target architecture. When they match (e.g., arm64 runner building arm64 targets), it appends `kas/opt/native-build.yml` to disable ISAR cross-compilation and use the native toolchain directly.

**Architecture-to-runner mapping**: arm64 targets (qemuarm64, jetson-orin-nano) run on `ubuntu-24.04-arm` (Cobalt 100 ARM). x86_64 targets run on `ubuntu-latest`.

### Tier 5 — Debian VM tests (build + test)

5 jobs grouped by network profile. Each job builds the required ISAR variants for `qemuamd64`, registers them in the Nix store, then runs the associated VM tests.

| Job | ISAR variants built | Tests run |
|-----|-------------------|-----------|
| `Test: debian-swupdate` | base-swupdate | debian-vm-boot, debian-two-vm-network, test-swupdate-bundle-validation, test-swupdate-apply |
| `Test: debian-simple` | server-simple-server-{1,2} | debian-server-boot, debian-service, debian-network-simple, debian-cluster-simple, debian-cluster-simple-direct |
| `Test: debian-vlans` | server-vlans-server-{1,2} | debian-network-vlans, debian-cluster-vlans, debian-cluster-vlans-direct |
| `Test: debian-bonding` | server-bonding-vlans-server-{1,2} | debian-network-bonding, debian-cluster-bonding-vlans, debian-cluster-bonding-vlans-direct |
| `Test: debian-dhcp` | server-dhcp-simple-server-{1,2} | debian-cluster-dhcp-simple, debian-cluster-dhcp-simple-direct |

**Three-phase execution**:
1. **Build**: `kas-container --isar build` with CI cache overlay
2. **Register**: `isar-build-all --rename-existing` copies output to unique filenames and registers in Nix store
3. **Test**: `nix build '.#checks.x86_64-linux.<test>'` runs the NixOS VM test driver against the registered ISAR images

Build and register are interleaved per variant (not batched) because ISAR variants sharing the same role produce identical output filenames. See [ci-test-failure-modes.md](ci-test-failure-modes.md#fm-3-isar-output-filename-collision-in-multi-variant-builds) for details.

## Measured Timings

All timings from CI run 5 (2026-02-22, `github-actions` branch, 20/20 PASS, warm cache).

**Pipeline wall-clock**: 27 minutes (limited by `Build: debian-qemuamd64`).

### Per-job durations

**Tier 1 — Eval/lint**:
| Job | Duration |
|-----|----------|
| Nix evaluation | 22s |
| Nix formatting | 55s |
| Debian package parity | 53s |
| VERSION file semver | ~20s |

**Tier 2 — Nix packages**:
| Job | Duration | Runner |
|-----|----------|--------|
| Debian packages (x86_64) | 59s | ubuntu-latest |
| Debian packages (aarch64) | — | ubuntu-24.04-arm |

**Tier 3 — NixOS VM tests**:
| Job | Duration | Notes |
|-----|----------|-------|
| nixos-smoke-vm-boot | 1m 53s | |
| nixos-smoke-two-vm-network | 2m 13s | |
| nixos-smoke-k3s-service-starts | 2m 37s | |
| nixos-k3s-cluster-bonding-vlans | 10m 8s | |
| nixos-k3s-cluster-vlans | 13m 44s | |
| nixos-k3s-cluster-simple | 17m 0s | Includes Nix derivation build |
| nixos-k3s-cluster-dhcp-simple | 17m 13s | Includes Nix derivation build |

Smoke tests are fast because the NixOS test derivation is small. Cluster tests build multi-VM derivations that share common closures — the first cluster test to run pays the Nix build cost, subsequent tests benefit from the magic-nix-cache.

**Tier 4 — ISAR builds**:
| Job | Duration | Build step | Notes |
|-----|----------|-----------|-------|
| debian-qemuarm64 | 3m 44s | 2m 35s | 2 variants, native arm64 build |
| debian-amd-v3c18i | 5m 48s | — | 1 variant |
| debian-jetson-orin-nano | 6m 26s | — | 2 variants, native arm64 build |
| debian-qemuamd64 | 26m 51s | 23m 38s | 11 variants (pipeline bottleneck) |

**Tier 5 — Debian VM tests**:
| Job | Duration | Build+register | Run tests |
|-----|----------|---------------|-----------|
| debian-swupdate | 9m 20s | — | — |
| debian-vlans | 13m 57s | — | — |
| debian-dhcp | 14m 31s | — | — |
| debian-simple | 14m 57s | 6m 26s | 4m 43s |
| debian-bonding | 15m 21s | — | — |

Tier 5 jobs each include ~3 minutes of disk space cleanup overhead (`jlumbroso/free-disk-space`) before building starts.

### Cold cache vs warm cache

The timings above reflect warm-cache runs where sstate and downloads are restored from GitHub Actions cache. Cold-cache runs (first push, or after cache eviction) are significantly slower because every ISAR recipe must be built from source.

## Build Caching

### ISAR caches (Tiers 4 and 5)

Two caches are persisted between CI runs via `actions/cache`:

1. **Download cache** (`DL_DIR`): Source tarballs, binary downloads (k3s, swupdate, etc.)
   - Key: `isar-dl-{ARCH}-{hash(kas/**)}`
   - Split by runner architecture to avoid k3s binary collision (the k3s BitBake recipe uses `downloadfilename=k3s` for both x86_64 and arm64)

2. **Shared-state cache** (`SSTATE_DIR`): Pre-built BitBake task outputs
   - Key: `isar-sstate-{machine}-{hash(kas/**,meta-n3x/**)}`
   - Per-machine for targeted cache hits

### How caching works

The `kas/opt/ci-cache.yml` overlay overrides BitBake's `DL_DIR` and `SSTATE_DIR` to point at the container-mounted cache paths:

```yaml
local_conf_header:
  zzz-ci-cache: |
    DL_DIR = "/downloads"
    SSTATE_DIR = "/sstate"
```

The `zzz-` prefix ensures this key sorts alphabetically after `base.yml`'s `shared-cache` key. BitBake uses last-assignment-wins, so the CI paths override the defaults.

When `DL_DIR` and `SSTATE_DIR` environment variables are set on the host, `kas-container` automatically mounts those host directories at `/downloads` and `/sstate` inside the container.

### Nix caches (Tiers 1-3, 5)

DeterminateSystems' `magic-nix-cache-action` provides transparent Nix store caching via GitHub Actions cache. This avoids rebuilding NixOS VM test derivations from scratch on each run.

## Runner Requirements

### Standard runners (`ubuntu-latest`, x86_64)

- 4 vCPU, 16 GB RAM, ~14 GB free disk after cleanup
- KVM available (required for Tiers 3 and 5)
- Docker available with `--privileged` support (required for Tiers 4 and 5)
- Used by: all jobs except arm64 builds

### ARM64 runners (`ubuntu-24.04-arm`)

- Cobalt 100 ARM processor, KVM available
- Docker available with `--privileged` support
- `jlumbroso/free-disk-space` action does NOT support ARM64 — manual cleanup used instead
- Used by: `Build: debian-qemuarm64`, `Build: debian-jetson-orin-nano`

### Why `--privileged` is required

ISAR builds use `kas-container --isar build`, which runs inside a Docker container. Inside that container, `mmdebstrap` uses `unshare(2)` to create mount namespace isolation for Debian root filesystem assembly. This system call requires `--privileged` mode (or specific capabilities: `SYS_ADMIN`, `SYS_CHROOT`).

Without `--privileged`, the build fails at the `mmdebstrap` step with:
```
unshare: unshare failed: Operation not permitted
```

### Disk space

ISAR builds consume significant disk space. The pipeline uses `jlumbroso/free-disk-space` (x86_64) or manual cleanup (arm64) to reclaim ~35 GB by removing pre-installed SDKs (Android, .NET, Haskell, etc.). Docker images and swap are preserved.

### KVM

NixOS VM tests (Tier 3) and Debian VM tests (Tier 5) run QEMU VMs that require KVM for acceptable performance. The `extra_nix_config` in the workflow advertises `kvm` as a system feature so Nix can use it:

```yaml
extra_nix_config: |
  system-features = nixos-test benchmark big-parallel kvm
```

Each test step verifies `/dev/kvm` exists before running.

**vCPU oversubscription**: Cluster tests run 2 QEMU VMs each requesting 4 vCPU on a runner with only 4 real vCPUs. This works but creates CPU pressure that can trigger timing-sensitive failures. See [ci-test-failure-modes.md](ci-test-failure-modes.md) for diagnosis guidance.

## How to Add a New Build Variant

1. **Define the variant** in `lib/debian/build-matrix.nix` — add an entry to the `variants` list with machine, role, network profile, and node identity.

2. **Add artifact hashes** in `lib/debian/artifact-hashes.nix` — add placeholder entries (`lib.fakeSha256`) for each artifact the variant produces.

3. **Build locally** with `nix run '.' -- --variant <id>` to populate the hashes.

4. **CI picks it up automatically**: Tier 4 jobs enumerate variants per machine via `nix eval '.#lib.debian.buildMatrix'`. New variants for existing machines appear in the next CI run with no workflow changes.

5. **If adding a new machine**: Add a `matrix.include` entry in the `build-isar` job with the machine name and appropriate runner.

## How to Add a New Test

### NixOS VM test (Tier 3)

1. Create the test in the Nix flake (typically in `tests/`).
2. Register it as a flake check: `checks.x86_64-linux.<test-name>`.
3. Add the test name to the `nixos-test` job's `matrix.test` list in `ci.yml`.

### Debian VM test (Tier 5)

1. Create the test in the Nix flake.
2. Register it as a flake check.
3. Determine which ISAR variant(s) the test needs (check which images the test's `mk-debian-test.nix` or `mk-debian-cluster-test.nix` references).
4. Either:
   - Add the test to an existing group's `tests` list (if it uses the same variants), or
   - Create a new `matrix.include` entry with the appropriate `group`, `variants`, and `tests`.

## Cost Model

### Public repository

GitHub provides unlimited free runner minutes for public repositories on standard runners (ubuntu-latest, ubuntu-24.04-arm). The pipeline costs $0/month.

### Private repository

If the repository is private, runner minutes are billed:

| Runner | Rate | Multiplier |
|--------|------|-----------|
| ubuntu-latest (x86_64) | Per-minute | 1x |
| ubuntu-24.04-arm (arm64) | Per-minute | 2x |

**Estimated per-run consumption** (from CI run 5, warm cache):
- 18 x86_64 jobs: ~169 billable minutes total
- 2 arm64 jobs: ~10 actual minutes × 2x = ~20 billable minutes
- **Total: ~189 billable minutes per run**

Free tier allowances: 2,000 min/month (free), 3,000 min/month (Pro).
At 2 runs/week: ~1,512 min/month (within free tier).
At daily runs: ~5,670 min/month (exceeds free tier).

## Known Limitations

These are inherent constraints of the CI environment, not missing features.

1. **qemuamd64 is the pipeline bottleneck**: With 11 variants built sequentially, this job takes ~27 minutes and determines total pipeline wall-clock time. Splitting into multiple jobs would reduce wall-clock time but increase cache misses (less sstate sharing within a single job).

2. **vCPU oversubscription in cluster tests**: 2 QEMU VMs × 4 vCPU on a 4-vCPU runner creates CPU pressure that occasionally triggers timing-sensitive failures. Resilience fixes (etcd quorum tolerance, stale state cleanup) mitigate this but don't eliminate the underlying resource constraint. See [ci-test-failure-modes.md](ci-test-failure-modes.md) for details.

3. **ARM64 VM tests not in CI**: Only x86_64 (qemuamd64) images are tested in CI VM tests. ARM64 images (qemuarm64, jetson-orin-nano) are built but not tested — ARM64 VM tests would require native arm64 KVM runners with sufficient resources for nested QEMU, which GitHub-hosted ARM runners do not provide.

## Release Process

Releases are fully automated. The VERSION file in the repo root is the single release trigger.

**To create a release:**

1. Open a PR that changes `VERSION` to the new version (e.g., `0.0.2`)
2. Merge the PR to main

That's it. Two workflows handle the rest:

1. **auto-tag.yml** detects the VERSION file change on main, validates the format, and creates an annotated git tag
2. **release.yml** triggers on the new tag, builds release images for all 4 machines in parallel, and creates a GitHub Release with the built assets attached

**Release assets** follow the naming pattern `n3x-{variant}-{machine}-{version}{ext}`. For example, version `0.0.1` produces:

- `n3x-base-qemuamd64-0.0.1.wic.zst` / `.wic.bmap`
- `n3x-base-swupdate-qemuamd64-0.0.1.wic.zst` / `.wic.bmap`
- `n3x-base-qemuarm64-0.0.1.wic.zst` / `.wic.bmap`
- `n3x-agent-amd-v3c18i-0.0.1.wic.zst` / `.wic.bmap`
- `n3x-base-jetson-orin-nano-0.0.1.tar.gz`

**Versioning**: The project uses semantic versioning without a `v` prefix. The VERSION file is also read by Nix at eval time (`builtins.readFile ./VERSION`) since `.git/` is not available inside the Nix sandbox.

**Why a VERSION file instead of git tags alone**: Nix flakes strip the `.git/` directory during evaluation. `git describe` and tag lookups are impossible at Nix eval time. The VERSION file provides a universally readable version source — Nix, shell, BitBake, and CI can all read it with no `.git/` dependency.

### Version string behavior during the release PR

When a PR bumps `VERSION` from `0.0.1` to `0.0.2`, the version strings on the PR branch are:

- **Nix**: `0.0.2+<commit-hash>` — correct, the `+hash` suffix distinguishes it from the tagged release
- **`git describe`**: `0.0.1-N-g<hash>` — references the previous tag, which is expected on an untagged branch
- **`cat VERSION`**: `0.0.2` — the intended next version

After merge, auto-tag.yml creates the `0.0.2` tag and `git describe` resolves to `0.0.2`. The Nix version becomes `0.0.2+<merge-commit-hash>`. Release assets (built only from tagged commits) use the bare `0.0.2`.

The commit hash suffix will always differ between the PR branch and the merge commit (different SHAs). Identical builds across that boundary are not possible with git — the VERSION file content is the part that stays consistent.

### Alternative: workflow_dispatch (atomic versioning)

If the gap between VERSION change and tag creation is unacceptable, the auto-tag workflow can be converted to a `workflow_dispatch` trigger. Instead of changing VERSION in a PR, you would run:

```bash
gh workflow run auto-tag --field version=0.0.2
```

The workflow atomically updates VERSION, commits, tags, and pushes. VERSION is never ahead of the tag. The downside is that release intent is not visible in PR code review — releases happen via CLI/UI action rather than a reviewable code change.

### Alternative: release-please

For projects with multiple contributors or a need for automated changelogs, Google's [release-please](https://github.com/googleapis/release-please) is a more feature-rich alternative. It monitors Conventional Commits on main and auto-generates a "Release PR" with changelog updates and version bumps. Merging that PR creates the tag and release automatically. To migrate from the current approach:

1. Replace `auto-tag.yml` and `release.yml` with `release-please-action`
2. Add `.release-please-manifest.json` and `release-please-config.json`
3. Adopt [Conventional Commits](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `chore:`, etc.)

## Dev Shell Validation

A separate workflow (`.github/workflows/dev-shells.yml`) validates that the `nix develop` dev shell works correctly — or correctly rejects — across every host-environment configuration the project claims to support. This workflow is independent of the main CI pipeline.

### What the shellHook validates

The dev shell's `shellHook` performs three behavioral checks against whatever container runtime is installed on the host:

1. **Binary on PATH**: `command -v docker` / `command -v podman`
2. **Identity check**: `docker -v | grep -qi nerdctl` — detects nerdctl masquerading as docker (Rancher Desktop containerd mode, Colima containerd mode)
3. **Daemon reachability**: `docker info` / `podman info` — verifies the runtime can actually execute containers

These checks produce one of two outcomes: the shell enters successfully with `KAS_CONTAINER_ENGINE` exported, or it exits with a descriptive error message and installation guidance.

### Contract-based coverage model

The shellHook tests **behavioral contracts**, not specific products. This is a deliberate design choice that enables broad coverage with a small number of CI fixtures.

A "contract" is the set of observable behaviors the shellHook checks for. Any product satisfying the same contract is indistinguishable to the shellHook. Testing with one product validates all products in that equivalence class.

| Contract | What the shellHook checks | CI fixture(s) | Products covered by equivalence |
|---|---|---|---|
| Docker-compatible daemon | `command -v docker` succeeds, `docker -v` doesn't contain "nerdctl", `docker info` succeeds | F1 (Linux), F8 (macOS Colima) | Docker Desktop, Colima, Rancher Desktop (dockerd mode), OrbStack |
| nerdctl masquerading as docker | `docker -v` output contains "nerdctl" | F5 (Linux) | Rancher Desktop (containerd mode), Colima containerd mode |
| Docker daemon stopped | `docker info` fails while `command -v docker` succeeds | F2 (Linux) | Any stopped docker daemon |
| System podman running | `command -v podman` succeeds, path is not `/nix/store/*` | F3 (Linux) | System podman (apt/dnf), Podman Machine |
| Nix-store podman on non-NixOS | `command -v podman` returns `/nix/store/*` path, `/etc/NIXOS` absent | F6 (Linux) | Nix-installed podman on Ubuntu/Debian/Fedora |
| No container runtime | Both `command -v docker` and `command -v podman` fail | F4 (Linux), F7 (macOS) | Clean system, incomplete install |

### Fixture tiers

Fixtures are organized into three tiers based on CI feasibility:

**Tier 1** (F1-F7): Immediately feasible on standard GitHub-hosted runners. Uses real package management (`apt-get install/remove`, `systemctl stop`) on `ubuntu-24.04` and `macos-latest` runner VMs. No mocked binaries, no container jobs, no fake scripts.

**Tier 2** (F8-F10): Feasible with validated approach. macOS fixtures use Colima on `macos-15-intel` runners (the only GH Actions macOS runner supporting nested virtualization). NixOS (F12) and WSL (F13-F14) fixtures were removed (2026-02-25) — these Nix-based environments are trivially validated locally.

**Tier 3** (F11, F15-F18): Require self-hosted runners or cannot run in CI. Each Tier 3 fixture maps to a Tier 1 or Tier 2 fixture that validates the same behavioral contract:

| Tier 3 fixture | Why not in CI | CI equivalent | Shared contract |
|---|---|---|---|
| F11: macOS + Podman Machine | Requires nested virt (confirmed by Podman maintainer, Discussion #26859) | F3 (Linux podman) | `command -v podman` + `podman info` |
| F15: macOS + Rancher Desktop (dockerd) | GUI Electron app, no headless mode | F8 (macOS Colima docker) | Docker daemon |
| F16: macOS + Rancher Desktop (containerd) | GUI Electron app | F9 (macOS Colima containerd) | nerdctl as docker |
| F17: macOS + OrbStack | Commercial license | F8 (macOS Colima docker) | Docker daemon |
| F18: Real WSL2 on Windows | Requires Windows runner + WSL2 + Nix. NixOS/WSL trivially validated locally. | Local validation only | WSL env var + runtime |

### Why no mocked binaries

The previous version of this workflow used mocked approaches — moving docker binaries, creating fake nerdctl scripts, setting `WSL_DISTRO_NAME` on regular Ubuntu runners. This tested bash branching logic, not real environments. The current design uses genuine package state changes on runner VMs because the goal is to prove the dev shell works on actual developer machines, not that the bash conditionals are syntactically correct.

### macOS container runtime constraints

Every macOS container runtime requires a Linux VM (containers are Linux). GH Actions macOS runners are themselves VMs, so nested virtualization is required. Only Intel macOS runners (`macos-15-intel`) support this. ARM runners (`macos-14`, `macos-15`) cannot run any container runtime.

Colima is the only confirmed working container runtime on GH Actions macOS runners. It supports both Docker mode (`colima start`) and containerd mode (`colima start --runtime containerd`), making it a CI proxy for Docker Desktop, Rancher Desktop, and OrbStack via contract equivalence.

See the [plan file](plans/034-dev-environment-and-adoption.md) for the full macOS runtime survey (11 tools evaluated) and per-fixture setup details.

### Manual testing for Tier 3 environments

Certain environments cannot be tested in CI. Developers on these platforms should verify the dev shell manually after any changes to the shellHook or container engine detection logic in `flake.nix`.

**macOS + Podman Machine** (F11 — validates Darwin+Podman path):

```bash
# Install and start Podman Machine
brew install podman
podman machine init
podman machine start

# Test: shell should enter with KAS_CONTAINER_ENGINE=podman
nix develop --command bash -c 'echo "ENGINE=$KAS_CONTAINER_ENGINE"'
# Expected: exit 0, ENGINE=podman

# Stop Podman Machine (and ensure no Docker is available)
podman machine stop

# Test: shell should reject with guidance
nix develop --command bash -c 'echo unreachable' 2>&1
# Expected: exit 1, "Podman Machine not running"
```

**macOS + Docker Desktop** (F15-equivalent — validates Darwin+Docker path):

```bash
# Start Docker Desktop
open -a Docker

# Test: shell should enter with KAS_CONTAINER_ENGINE=docker
nix develop --command bash -c 'echo "ENGINE=$KAS_CONTAINER_ENGINE"'
# Expected: exit 0, ENGINE=docker

# Quit Docker Desktop
osascript -e 'quit app "Docker"'
sleep 5

# Test: shell should reject with guidance
nix develop --command bash -c 'echo unreachable' 2>&1
# Expected: exit 1, "Docker daemon not running"
```

**macOS + both Docker and Podman** (preference test):

```bash
# Start both Docker Desktop and Podman Machine
open -a Docker && podman machine start

# Test: docker should be preferred (consistent with Linux non-WSL behavior)
nix develop --command bash -c 'echo "ENGINE=$KAS_CONTAINER_ENGINE"'
# Expected: exit 0, ENGINE=docker
```

## Related Documentation

- [ci-test-failure-modes.md](ci-test-failure-modes.md) — Catalog of CI failure patterns with diagnosis and remediation
- [tests/README.md](../tests/README.md) — Test framework documentation
- [ISAR-L4-TEST-ARCHITECTURE.md](ISAR-L4-TEST-ARCHITECTURE.md) — Debian cluster test architecture
- [plans/034-dev-environment-and-adoption.md](plans/034-dev-environment-and-adoption.md) — Dev shell fixture matrix and macOS runtime research
