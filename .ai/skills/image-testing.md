# Image Testing Skill

This skill covers running automated VM tests, interactive debugging, manual image booting, and troubleshooting for n3x NixOS and Debian backend images.

## Automated Testing

### Running Tests

```bash
# NixOS backend (direct kernel boot, fastest)
nix build '.#checks.x86_64-linux.k3s-cluster-simple' -L
nix build '.#checks.x86_64-linux.k3s-cluster-vlans' -L
nix build '.#checks.x86_64-linux.k3s-cluster-bonding-vlans' -L
nix build '.#checks.x86_64-linux.k3s-cluster-dhcp-simple' -L

# NixOS backend (UEFI/systemd-boot)
nix build '.#checks.x86_64-linux.k3s-cluster-simple-systemd-boot' -L

# Debian backend (firmware boot, production-like)
nix build '.#checks.x86_64-linux.debian-cluster-simple' -L
nix build '.#checks.x86_64-linux.debian-cluster-vlans' -L
nix build '.#checks.x86_64-linux.debian-cluster-bonding-vlans' -L
nix build '.#checks.x86_64-linux.debian-cluster-dhcp-simple' -L

# Debian backend (direct kernel boot)
nix build '.#checks.x86_64-linux.debian-cluster-simple-direct' -L

# Smoke tests (L1-L3)
nix build '.#checks.x86_64-linux.debian-vm-boot' -L          # L1
nix build '.#checks.x86_64-linux.debian-two-vm-network' -L   # L2
nix build '.#checks.x86_64-linux.debian-server-boot' -L      # L3

# Force re-execution (bypass nix cache)
nix build '.#checks.x86_64-linux.k3s-cluster-simple' --rebuild -L
```

### Test Tiers

| Tier | Tests | What | Pass Criteria |
|------|-------|------|---------------|
| L1 | `*-vm-boot` | QEMU/KVM boot | Backdoor shell connects |
| L2 | `*-two-vm-network` | VM-to-VM network | Ping between VMs |
| L3 | `*-server-boot`, `*-service` | k3s binary/service | Service starts |
| L4 | `*-cluster-*` | 2-server HA formation | All nodes "Ready" |

### Naming Conventions

- **NixOS tests**: `k3s-cluster-{profile}` or `k3s-cluster-{profile}-systemd-boot`
- **Debian tests**: `debian-cluster-{profile}` or `debian-cluster-{profile}-direct`
- **Profiles**: `simple`, `vlans`, `bonding-vlans`, `dhcp-simple`
- **16 L4 tests total**: 4 profiles x 2 boot modes x 2 backends

### Test Parallelism (Local Execution)

When running multiple VM tests locally, limit concurrency to avoid CPU saturation and inflated test times:

| Test Category | VMs/Test | Max Parallel | Example |
|---|---|---|---|
| L1-L3 single-VM (vm-boot, server-boot, service, network-*, swupdate-*) | 1 | 4 | 4 tests = 4 VMs |
| L2 two-VM (two-vm-network) | 2 | 2 | 2 tests = 4 VMs |
| L4 cluster (cluster-simple, cluster-vlans) | 2 | 2 | 2 tests = 4 VMs |
| L4 bonding cluster (cluster-bonding-vlans) | 2 | 1 | Bond + VLAN setup is CPU-heavy |

**Recommended batching for full Debian test suite:**

```bash
# Batch 1: Single-VM tests (4 parallel)
nix build '.#checks.x86_64-linux.debian-vm-boot' \
          '.#checks.x86_64-linux.debian-server-boot' \
          '.#checks.x86_64-linux.debian-service' \
          '.#checks.x86_64-linux.test-swupdate-bundle-validation' -L

# Batch 2: Single-VM tests continued (3 parallel)
nix build '.#checks.x86_64-linux.test-swupdate-apply' \
          '.#checks.x86_64-linux.debian-network-simple' \
          '.#checks.x86_64-linux.debian-network-vlans' -L

# Batch 3: Remaining single-VM + two-VM (2 parallel)
nix build '.#checks.x86_64-linux.debian-network-bonding' \
          '.#checks.x86_64-linux.debian-two-vm-network' -L

# Batch 4: Cluster tests (2 parallel max)
nix build '.#checks.x86_64-linux.debian-cluster-simple' \
          '.#checks.x86_64-linux.debian-cluster-simple-direct' -L

# Batch 5-7: Remaining cluster tests (2 parallel max each)
nix build '.#checks.x86_64-linux.debian-cluster-vlans' \
          '.#checks.x86_64-linux.debian-cluster-vlans-direct' -L

nix build '.#checks.x86_64-linux.debian-cluster-bonding-vlans' \
          '.#checks.x86_64-linux.debian-cluster-bonding-vlans-direct' -L
```

**Why this matters**: Running 3 cluster tests simultaneously (6 VMs) inflates each test from ~90s to ~320s due to CPU contention. Sequential or limited-parallel execution is faster overall.

### Key Source Files

| File | Purpose |
|------|---------|
| `tests/lib/mk-k3s-cluster-test.nix` | Parameterized NixOS cluster test builder |
| `tests/lib/debian/mk-debian-test.nix` | Debian backend test wrapper |
| `tests/lib/debian/mk-debian-vm-script.nix` | QEMU command generator for WIC images |
| `tests/lib/test-scripts/` | Shared Python test phases (boot, network, k3s) |
| `tests/README.md` | Full test framework documentation |

## Interactive Debugging

### Starting Interactive Mode

```bash
# NixOS tests
nix build '.#checks.x86_64-linux.k3s-cluster-simple.driverInteractive'
./result/bin/nixos-test-driver --interactive

# Debian tests
nix build '.#checks.x86_64-linux.debian-cluster-simple'
./result/bin/run-test-interactive
```

### Python REPL Commands

```python
# VM lifecycle
start_all()                              # Start all VMs
join_all()                               # Wait for all VMs to shut down

# Execute commands on VMs (node names: dashes → underscores)
server_1.succeed("k3s kubectl get nodes")     # Run command, fail on non-zero
code, out = server_1.execute("command")       # Run command, return (exit_code, stdout)
server_1.wait_for_unit("multi-user.target")   # Block until systemd unit active
server_1.wait_until_succeeds("curl ...", timeout=30)  # Retry until success

# Interactive shell on VM
server_1.shell_interact()                # Drop into VM shell (Ctrl-D to exit)
server_1.console_interact()              # Direct QEMU serial console

# Debugging
server_1.screenshot("debug.png")         # Capture VM display
server_1.get_screen_text()               # OCR the VM screen
serial_stdout_on()                       # Print serial output to terminal
serial_stdout_off()                      # Disable serial output
```

### Keep VM State Between Runs

```bash
./result/bin/nixos-test-driver --keep-vm-state --interactive
# State in /tmp/vm-state-<name>/
# Clean stale state: rm -rf /tmp/vm-state-*
```

## Manual Image Booting

### Boot a WIC Image with QEMU (Firmware/UEFI)

```bash
# Find OVMF firmware paths (from nixpkgs)
OVMF_CODE="$(nix build '.#OVMF.fd' --print-out-paths)/FV/OVMF_CODE.fd"
OVMF_VARS_SRC="$(nix build '.#OVMF.fd' --print-out-paths)/FV/OVMF_VARS.fd"

# Create writable copy of OVMF_VARS (modified during boot)
cp "$OVMF_VARS_SRC" /tmp/ovmf_vars.fd
chmod 644 /tmp/ovmf_vars.fd

# Launch QEMU with UEFI firmware
qemu-system-x86_64 \
  -machine q35 -cpu host -enable-kvm \
  -m 4096 -smp 4 \
  -display none -serial stdio \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file=/tmp/ovmf_vars.fd \
  -drive file=path/to/image.wic,format=raw,if=virtio,snapshot=on
```

### Boot a WIC Image with QEMU (Direct Kernel)

```bash
# Extract kernel and initrd from WIC image first, then:
qemu-system-x86_64 \
  -machine q35 -cpu host -enable-kvm \
  -m 4096 -smp 4 \
  -display none -serial stdio \
  -kernel path/to/vmlinuz \
  -initrd path/to/initrd.img \
  -append "root=/dev/vda2 rootwait console=ttyS0,115200 net.ifnames=0 biosdevname=0 quiet loglevel=1" \
  -drive file=path/to/image.wic,format=raw,if=virtio,snapshot=on
```

### Notes on Manual Booting

- Use `snapshot=on` to avoid modifying the original image
- `-serial stdio` gives you console access directly in the terminal
- The test framework adds virtio-serial + virtconsole for backdoor protocol — manual boot doesn't have this
- For network access, add `-netdev user,id=net0 -device virtio-net-pci,netdev=net0`

## Default Credentials

| Backend | Method | Details |
|---------|--------|---------|
| NixOS | Root password | `test` (set in `mk-k3s-cluster-test.nix` line 372) |
| NixOS | SSH | Root login enabled, password auth enabled |
| Debian/ISAR | Backdoor service | `nixos-test-backdoor.service` (from `kas/test-k3s-overlay.yml`) |
| Debian/ISAR | Root login | Via test overlay `kas/packages/debug.yml` (openssh-server) |

The NixOS test driver uses a backdoor shell over virtconsole (`hvc0`) — this is how `succeed()`, `execute()`, and `shell_interact()` work. No SSH required for test commands.

## Boot Modes

### Firmware Boot (UEFI/OVMF)

```
OVMF_CODE.fd → UEFI firmware → GRUB/systemd-boot → vmlinuz → kernel
```

- **NixOS**: Uses systemd-boot when `useSystemdBoot = true`
- **Debian/ISAR**: Uses GRUB (configured in `kas/boot/grub.yml`)
- **Default for**: Debian tests (production-like), NixOS `*-systemd-boot` tests
- **Speed**: Slower (firmware init + bootloader)
- **Validates**: Full boot chain, bootloader config, EFI partition

### Direct Kernel Boot

```
QEMU -kernel/-initrd → vmlinuz → kernel (bypasses firmware entirely)
```

- **Default for**: NixOS tests (fastest), Debian `*-direct` tests
- **Speed**: Faster (no firmware/bootloader overhead)
- **Tradeoff**: Doesn't validate bootloader configuration
- **Kernel params**: `root=/dev/vda2 rootwait console=ttyS0,115200 net.ifnames=0 biosdevname=0 quiet loglevel=1`

### When to Use Each

| Scenario | Boot Mode | Why |
|----------|-----------|-----|
| Quick iteration / CI | Direct | Fastest boot |
| Bootloader changes | Firmware | Must test GRUB/systemd-boot |
| Production parity | Firmware | Matches real hardware boot |
| Network debugging | Either | Both provide same network stack |
| Backdoor issues | Direct | Avoids GRUB serial corruption |

## Common Test Failures

### Timing Bugs

**Symptom**: Test passes sometimes, fails other times.

```python
# WRONG: Fixed delay — too short under load, wasteful otherwise
time.sleep(30)
server_1.succeed("k3s kubectl get nodes")

# RIGHT: Poll for expected condition with timeout
server_1.wait_until_succeeds("k3s kubectl get nodes | grep -q Ready", timeout=300)
```

**TCP warm-up** (bonding-vlans profiles): ICMP works but TCP fails initially.
```python
# Warm up TCP before starting service
for attempt in range(3):
    code, out = server_2.execute("timeout 15 curl -sk https://server-1:6443/cacerts")
    if code == 0:
        break
    time.sleep(2)
```

### Missing Backdoor

**Symptom**: `wait_for_unit("nixos-test-backdoor.service")` times out.

**Cause**: ISAR images missing the `nixos-test-backdoor` package.

**Fix**: Ensure build includes `kas/test-k3s-overlay.yml` in the kas config chain:
```bash
kas-build kas/base.yml:kas/machine/qemu-amd64.yml:...:kas/test-k3s-overlay.yml:...
```

The overlay installs `nixos-test-backdoor` which provides the systemd service that listens on `hvc0` (virtconsole).

### GRUB Serial Corruption

**Symptom**: First command after boot returns garbage or fails with base64 decode error.

**Cause**: GRUB outputs ANSI escape sequences to virtconsole (same channel as backdoor protocol).

**Solution** (already implemented in test framework):
```python
# Disable serial capture during GRUB boot
serial_stdout_off()
start_all()
node.wait_for_unit("nixos-test-backdoor.service")
serial_stdout_on()
# Wait for GRUB output to drain
node.wait_until_succeeds("true", timeout=10)
```

If writing custom test scripts for Debian images, always use this pattern. See `tests/lib/test-scripts/phases/boot.nix` for the canonical implementation.

### Network Convergence

**Symptom**: Nodes can't reach each other immediately after boot.

**Causes and fixes by profile**:

| Profile | Issue | Fix |
|---------|-------|-----|
| simple | Interface not ready | `wait_until_succeeds("ping -c1 <ip>")` |
| vlans | VLAN sub-interface slow | Check `ip -d link show` for VLAN ID |
| bonding-vlans | Bond carrier negotiation | Check `/proc/net/bonding/bond0` carrier status |
| dhcp-simple | DHCP lease delay | Wait for `systemd-networkd-wait-online` |

**Bond state verification**:
```python
server_1.wait_until_succeeds(
    "grep -q 'MII Status: up' /proc/net/bonding/bond0",
    timeout=60
)
```

### Cached Test Results

**Symptom**: Test "passes" in 6-10 seconds without running.

**Cause**: Nix cached previous successful result.

**Fix**: Force re-execution:
```bash
nix build '.#checks.x86_64-linux.k3s-cluster-simple' --rebuild -L
```

| Indicator | Cached | Actually Ran |
|-----------|--------|-------------|
| Duration | 6-10s | 2-15 min |
| Boot logs | None | `systemd[1]: Initializing...` |
| Test output | None | `must succeed:`, `wait_for` |

### Orphaned Processes

**Symptom**: Test hangs at start, port conflicts, or "KVM device already in use".

**Fix**: Check and kill orphaned processes before running tests:
```bash
pgrep -a qemu 2>/dev/null || echo "No QEMU"
pgrep -a nixos-test-driver 2>/dev/null || echo "No drivers"
# Kill with SIGTERM first (not SIGKILL)
kill -TERM <pid>; sleep 5
```
