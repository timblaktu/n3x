# Release Process

n3x uses [Semantic Versioning](https://semver.org/) with automated release pipelines. The [`VERSION`](VERSION) file in the repository root is the single source of truth for the current version and the sole trigger for the release process.

## Why a VERSION File?

Nix flakes provide a well-defined set of source metadata during evaluation: commit hash (`self.rev`, `self.shortRev`), dirty state (`self.dirtyRev`), commit timestamp (`self.lastModified`), and ancestor count (`self.revCount`). Git tags, however, are not part of this metadata set. There is no `self.tag` or `self.gitDescribe` attribute, and flake evaluation enforces purity — shelling out to `git describe` is not permitted.

This is a deliberate design boundary in Nix's git fetcher, which extracts source content and a minimal set of commit-level metadata without resolving tag references. The sandboxed build environment similarly has no access to the `.git` directory or the network, so derivations cannot query tags either. This is well-documented in [NixOS/nix#7201](https://github.com/NixOS/nix/issues/7201) and has been discussed on [NixOS Discourse](https://discourse.nixos.org/t/git-describe-like-attributes-for-flakes/10805) since 2021.

The [`VERSION`](VERSION) file bridges this gap cleanly. It is a tracked file in the working tree, so it participates in flake evaluation like any other source file. [`flake.nix`](flake.nix) reads it at eval time and composes a full version string:

```nix
baseVersion = lib.trim (builtins.readFile ./VERSION);
version =
  if self ? rev then "${baseVersion}+${self.shortRev}"
  else "${baseVersion}-dirty";
```

This produces versions like `0.0.3+a1b2c3d` for clean builds and `0.0.3-dirty` for uncommitted working trees — combining the human-meaningful release version with Nix's native commit identity. The [`VERSION`](VERSION) file is also validated at eval time by the [`lint-version`](flake.nix) check, which rejects non-semver content via `lib.seq` + `throw` (so `nix flake check --no-build` catches format errors immediately).

The CI pipeline then closes the loop: when [`VERSION`](VERSION) changes on `main`, [`auto-tag.yml`](.github/workflows/auto-tag.yml) creates the corresponding git tag, keeping the file and the tag in permanent agreement.

## How to Release

1. **Create a PR** that bumps the [`VERSION`](VERSION) file to the new version (e.g., `0.0.3` → `0.1.0`)
2. **Merge the PR** to `main`
3. The rest is automatic:
   - [`auto-tag.yml`](.github/workflows/auto-tag.yml) detects the [`VERSION`](VERSION) change and creates an annotated git tag
   - The tag push triggers [`release.yml`](.github/workflows/release.yml)
   - [`release.yml`](.github/workflows/release.yml) builds ISAR images for all machines in parallel, generates release notes from conventional commits, and publishes a GitHub Release with all artifacts attached

No manual tag creation or release drafting is required.

## Version Format

Versions must be valid semver: `MAJOR.MINOR.PATCH` with an optional pre-release suffix.

```
0.1.0           # standard release
1.0.0-rc1       # pre-release
```

[`auto-tag.yml`](.github/workflows/auto-tag.yml) validates the format and rejects anything that doesn't match `N.N.N` or `N.N.N-suffix`.

## Release Scope

Each release builds and publishes **base/production images** for all supported machines:

| Machine | Architecture | Variants | Artifacts |
|---------|-------------|----------|-----------|
| qemuamd64 | x86_64 | base, base-swupdate | `.wic.zst`, `.wic.bmap` |
| qemuarm64 | aarch64 | base | `.wic.zst`, `.wic.bmap` |
| amd-v3c18i | x86_64 | agent | `.wic.zst`, `.wic.bmap` |
| jetson-orin-nano | aarch64 | base | `.tar.gz` |

Profile-specific server/agent images (with network topology baked in) are **not** included in releases. Users build those locally with `nix run '.'` for their specific deployment topology.

## Release Asset Naming

```
n3x-{variant}-{machine}-{version}{ext}
```

Examples:
- `n3x-base-qemuamd64-0.1.0.wic.zst`
- `n3x-base-swupdate-qemuamd64-0.1.0.wic.zst`
- `n3x-base-jetson-orin-nano-0.1.0.tar.gz`

## Release Notes

Release notes are auto-generated from [Conventional Commits](https://www.conventionalcommits.org/) between the previous and current tag. Commits are grouped by type (Features, Bug Fixes, Documentation, etc.) with breaking changes highlighted at the top. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for commit message conventions.

## Pipeline Details

### [`auto-tag.yml`](.github/workflows/auto-tag.yml)

- **Trigger**: Push to `main` that changes [`VERSION`](VERSION)
- **Validates**: Semver format, tag doesn't already exist
- **Creates**: Annotated git tag matching [`VERSION`](VERSION) content
- **Auth**: Uses `RELEASE_PAT` secret (not `GITHUB_TOKEN`) because GitHub Actions events created by `GITHUB_TOKEN` don't trigger other workflows

### [`release.yml`](.github/workflows/release.yml)

- **Trigger**: Push of a version tag matching `[0-9]*`
- **Validates**: Tag matches [`VERSION`](VERSION) file content at the tagged commit
- **Builds**: All release variants per-machine in parallel (x86_64 on `ubuntu-latest`, aarch64 on `ubuntu-24.04-arm`)
- **Concurrency**: Only one release runs at a time (`cancel-in-progress: false`)
- **Timeout**: 120 minutes per machine build, 10 minutes for the release job

### [`release.yml`](.github/release.yml) (config)

Configures GitHub's auto-generated release notes categories. This is only used if a release is created manually through the GitHub UI — the automated pipeline generates its own notes from git history.

## Future Considerations

The [`auto-tag.yml`](.github/workflows/auto-tag.yml) header documents two alternative approaches for when the project evolves:

- **[release-please](https://github.com/googleapis/release-please)**: Auto-generates Release PRs with changelogs from conventional commits. Recommended if the project grows to multiple contributors or needs richer changelog management.
- **workflow_dispatch**: Fully atomic versioning where [`VERSION`](VERSION) update, commit, tag, and push happen in a single workflow run. Useful if the gap between [`VERSION`](VERSION) change and tag creation becomes a problem for `git describe`.
