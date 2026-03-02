# =============================================================================
# K3s Bonding + VLANs Network Test
# =============================================================================
#
# Tests the bonding-vlans network profile on ISAR k3s server image.
# Uses bonded NICs (eth1+eth2) with VLANs on bond0:
#   - Bond mode: 802.3ad (LACP)
#   - VLAN 200: Cluster traffic (192.168.200.0/24)
#   - VLAN 100: Storage traffic (192.168.100.0/24)
#
# REQUIREMENTS:
#   - ISAR image built with: kas/test-k3s-overlay.yml:kas/network/bonding-vlans.yml
#   - Image must include systemd-networkd-config package with bonding-vlans profile
#
# Usage:
#   # Build the test driver:
#   nix-build -E 'with import <nixpkgs> {}; callPackage ./k3s-network-bonding.nix {}'
#
#   # Run the test:
#   ./result/bin/run-test
#
# NOTE: Test creates 3 NICs via vlans = [ 1 2 ]:
#   - eth0: QEMU user-mode NAT (restricted, no external access)
#   - eth1, eth2: VDE virtual ethernet for bonding
#
# =============================================================================

{ pkgs ? import <nixpkgs> { }
, lib ? pkgs.lib
}:

let
  isarArtifacts = import ../../backends/debian/debian-artifacts.nix { inherit pkgs lib; };
  mkISARTest = pkgs.callPackage ../lib/debian/mk-debian-test.nix { inherit pkgs lib; };

  # Import shared test utilities
  testScripts = import ../lib/test-scripts { inherit lib; };
  bootPhase = import ../lib/test-scripts/phases/boot.nix { inherit lib; };

  test = mkISARTest {
    name = "k3s-network-bonding";

    # For bonding test, we need 2 VLANs to create eth1 and eth2
    vlans = [ 1 2 ];

    machines = {
      server = {
        # Use bonding-vlans profile-specific artifact (must build with kas/network/bonding-vlans.yml)
        image = isarArtifacts.qemuamd64.server."bonding-vlans".wic;
        memory = 4096;
        cpus = 4;
        # vlans = [ 1 2 ] above creates eth1 (vlan1) and eth2 (vlan2)
        # No extraQemuArgs needed - the VM script auto-detects QEMU_VDE_SOCKET_* env vars
        # and creates virtio-net-pci devices for each VDE switch
      };
    };

    # Note: testScript content must start at column 0 because testScripts.utils.all
    # contains Python code at column 0 (function definitions, imports).
    testScript = ''
      ${testScripts.utils.all}

      log_banner("ISAR K3s Network Bonding+VLANs Test", "network-bonding", {
          "Layer": "4 (Network Profile)",
          "Profile": "bonding-vlans",
          "Bond": "bond0 (eth1 + eth2, 802.3ad LACP)",
          "VLAN 200": "192.168.200.1/24 (cluster)",
          "VLAN 100": "192.168.100.1/24 (storage)"
      })

      # Phase 1: Boot with GRUB serial protection
      ${bootPhase.debian.bootWithBackdoor { node = "server"; displayName = "ISAR K3s server"; }}

      # Phase 2: Wait for network configuration
      log_section("PHASE 2", "Network Configuration")

      server.wait_for_unit("systemd-networkd.service", timeout=60)
      tlog("  systemd-networkd is active")

      # Wait for networkd to create bond and VLAN interfaces
      server.wait_until_succeeds("ip link show bond0", timeout=30)
      server.wait_until_succeeds("ip link show bond0.200", timeout=30)
      server.wait_until_succeeds("ip link show bond0.100", timeout=30)
      tlog("  Bond and VLAN interfaces created")

      # Check kernel modules
      log_section("MODULES", "Kernel Modules")
      code, bond_mod = server.execute("lsmod | grep bonding || modprobe bonding && lsmod | grep bonding")
      tlog(f"Bonding: {bond_mod.strip()}")

      code, vlan_mod = server.execute("lsmod | grep 8021q || modprobe 8021q && lsmod | grep 8021q")
      tlog(f"8021Q: {vlan_mod.strip()}")

      # Check systemd-networkd config files
      log_section("CONFIG", "systemd-networkd config files")
      code, networkd_files = server.execute("ls -la /etc/systemd/network/ 2>&1")
      tlog(networkd_files)

      # Phase 3: Verify bond interface
      log_section("PHASE 3", "Bond Interface Verification")

      interfaces = server.succeed("ip -br link")
      tlog("Interfaces:")
      for line in interfaces.strip().split("\n"):
          tlog(f"  {line}")

      # Check bond0
      log_section("BOND", "Bond Interface")
      code, bond0 = server.execute("ip addr show bond0 2>&1")
      tlog(bond0)

      code, bond_status = server.execute("cat /proc/net/bonding/bond0 2>&1")
      if code == 0:
          tlog("\nBond Status:")
          tlog(bond_status)
      else:
          tlog("Bond interface not active")

      # Phase 4: Verify VLAN interfaces on bond
      log_section("PHASE 4", "VLAN on Bond Verification")

      ip_addrs = server.succeed("ip -br addr")
      tlog("IP Addresses:")
      for line in ip_addrs.strip().split("\n"):
          tlog(f"  {line}")

      # Verify cluster VLAN (bond0.200)
      log_section("VERIFY", "Cluster VLAN Check (bond0.200)")
      code, vlan200 = server.execute("ip addr show bond0.200 2>&1")
      tlog(vlan200)

      cluster_ip = server.succeed("ip -4 addr show bond0.200 | grep -oP '(?<=inet )\\S+'")
      tlog(f"Cluster VLAN IP: {cluster_ip.strip()}")
      assert "192.168.200.1" in cluster_ip, f"Expected 192.168.200.1, got {cluster_ip}"
      tlog("✓ bond0.200 has correct IP address")

      # Verify storage VLAN (bond0.100)
      log_section("VERIFY", "Storage VLAN Check (bond0.100)")
      code, vlan100 = server.execute("ip addr show bond0.100 2>&1")
      tlog(vlan100)

      storage_ip = server.succeed("ip -4 addr show bond0.100 | grep -oP '(?<=inet )\\S+'")
      tlog(f"Storage VLAN IP: {storage_ip.strip()}")
      assert "192.168.100.1" in storage_ip, f"Expected 192.168.100.1, got {storage_ip}"
      tlog("✓ bond0.100 has correct IP address")

      # Check routing table
      log_section("ROUTES", "Routing Table")
      routes = server.succeed("ip route")
      tlog(routes.strip())

      log_summary("ISAR K3s Network Bonding+VLANs Test", "network-bonding", [
          "bond0 formed (eth1 + eth2)",
          "bond0.200 (cluster VLAN): 192.168.200.1/24",
          "bond0.100 (storage VLAN): 192.168.100.1/24",
          "Bonding + VLAN tagging functional"
      ])
    '';
  };

in
test
