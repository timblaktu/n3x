# Internal Fork Context

This file provides additional context specific to the internal fork's infrastructure, deployment targets, and project management. It is loaded automatically by Claude Code alongside CLAUDE.md.

On the public repo, this file does not exist (`.claude/rules/` contains only `.gitkeep`). The internal fork adds this file following the additive pattern described in CLAUDE.md.

## Project Status — Plan Tracking

- **Plan 034**: Dev Environment Validation — COMPLETE — `.claude/user-plans/034-dev-environment-and-adoption.md`
- **Plan 033**: CI Pipeline Refactoring — COMPLETE (T8 deferred) — `.claude/user-plans/033-ci-pipeline-refactoring.md`
- **Plan 032**: Public Repo Publication and Internal Fork — IN_PROGRESS — `.claude/user-plans/032-public-repo-and-internal-fork.md`
- **Plan 030**: Architecture Diagrams — COMPLETE — `.claude/user-plans/030-architecture-diagrams.md`
- **Plan 025**: Cross-Architecture Build Environment — ACTIVE (4/7) — `.claude/user-plans/025-cross-arch-build-environment.md`
- **Plan 023**: CI Infrastructure and Runner Deployment — ACTIVE (15/23) — `.claude/user-plans/023-ci-infrastructure-deployment.md`

## Target CI Architecture (Future)

Self-managed EC2 runners (x86_64 + Graviton) for ISAR/Nix builds, plus on-prem NixOS bare metal for VM tests (KVM required) and HIL tests. Harmonia + ZFS binary cache, Caddy reverse proxy with internal CA.

See `docs/nix-binary-cache-architecture-decision.md` for the full ADR.

## Technical Learnings — Internal Infrastructure

### ZFS Replication Limitations

**ZFS does NOT support multi-master replication.** Key findings:
- `zfs send/recv` requires single-master topology (one writer, read-only replicas)
- If both source and destination have written past the last shared snapshot, they've "diverged" and cannot be merged
- Tools like zrep/zrepl are active-passive with failover, not simultaneous read-write

**For Nix binary caches with multiple active builders:**
- Use HTTP substituters instead of ZFS replication
- Each node: independent ZFS-backed `/nix/store` (for compression benefits)
- Each node: Harmonia serving local store
- Before building, Nix queries all substituters; downloads if found, builds if not
- Nix's content-addressing prevents conflicts (same derivation = same store path)

**ZFS value without replication:**
- zstd compression: 1.5-2x savings (500GB → 750-1000GB effective)
- Checksumming: Detects bit rot
- Snapshots: Pre-GC safety, instant rollback
- ARC cache: Intelligent read caching

### AWS AMI Registration (register-ami.sh)

- AWS `register-image --architecture` accepts `x86_64` or `arm64` (NOT `aarch64`)
- Script maps: `--arch aarch64` → `AWS_ARCH="arm64"` for the API call
- Uses `jq` (not python3) for JSON parsing — lighter dependency
- EXIT trap handles S3 cleanup on script failure

### Infra-Specific Flake Input Notes

- **Caddyfile v2 syntax**: Use named matchers (`@name path /...`) for path-specific headers, not nested `{path ...}` inside header values.

### NixOS 25.11 Migration — gitlab-runner Workaround

**gitlab-runner `authenticationTokenConfigFile`** (commit `53f7032`)
- `registrationConfigFile` deprecated in GitLab 16.0+, removed in 18.0
- File: `infra/nixos-runner/modules/gitlab-runner.nix`
- Added new option + mutual exclusion assertion. Both old and new work.

## Internal References

- [.claude/user-plans/034-dev-environment-and-adoption.md](.claude/user-plans/034-dev-environment-and-adoption.md) - Dev environment validation and team adoption plan
- [.claude/user-plans/033-ci-pipeline-refactoring.md](.claude/user-plans/033-ci-pipeline-refactoring.md) - CI pipeline refactoring plan
- [.claude/user-plans/032-public-repo-and-internal-fork.md](.claude/user-plans/032-public-repo-and-internal-fork.md) - Public repo publication and internal fork plan
- [.claude/user-plans/023-ci-infrastructure-deployment.md](.claude/user-plans/023-ci-infrastructure-deployment.md) - CI infrastructure deployment plan
