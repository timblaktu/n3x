# =============================================================================
# K3s VLANs Network Test
# =============================================================================
#
# Tests the VLANs network profile on ISAR k3s server image.
# Uses 802.1Q VLAN tagging on eth1 trunk:
#   - VLAN 200: Cluster traffic (192.168.200.0/24)
#   - VLAN 100: Storage traffic (192.168.100.0/24)
#
# REQUIREMENTS:
#   - ISAR image built with: kas/test-k3s-overlay.yml:kas/network/vlans.yml
#   - Image must include systemd-networkd-config package with vlans profile
#
# Usage:
#   # Build the test driver:
#   nix-build -E 'with import <nixpkgs> {}; callPackage ./k3s-network-vlans.nix {}'
#
#   # Run the test:
#   ./result/bin/run-test
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
    name = "k3s-network-vlans";

    # VLAN test uses single underlying network
    # VLANs are created on top of eth1 within the VM
    vlans = [ 1 ];

    machines = {
      server = {
        # Use vlans profile-specific artifact (must build with kas/network/vlans.yml)
        image = isarArtifacts.qemuamd64.server.vlans.wic;
        memory = 4096;
        cpus = 4;
      };
    };

    # Note: testScript content must start at column 0 because testScripts.utils.all
    # contains Python code at column 0 (function definitions, imports).
    testScript = ''
      ${testScripts.utils.all}

      log_banner("ISAR K3s Network VLANs Test", "network-vlans", {
          "Layer": "4 (Network Profile)",
          "Profile": "vlans",
          "VLAN 200": "192.168.200.1/24 (cluster)",
          "VLAN 100": "192.168.100.1/24 (storage)"
      })

      # Phase 1: Boot with GRUB serial protection
      ${bootPhase.debian.bootWithBackdoor { node = "server"; displayName = "ISAR K3s server"; }}

      # Phase 2: Wait for network configuration
      log_section("PHASE 2", "Network Configuration")

      server.wait_for_unit("systemd-networkd.service", timeout=60)
      tlog("  systemd-networkd is active")

      # Wait for networkd to create VLAN interfaces
      server.wait_until_succeeds("ip link show eth1.200", timeout=30)
      server.wait_until_succeeds("ip link show eth1.100", timeout=30)
      tlog("  VLAN interfaces created")

      # Check if 8021q module is loaded
      log_section("MODULE", "8021Q VLAN Module")
      code, vlan_mod = server.execute("lsmod | grep 8021q || modprobe 8021q && lsmod | grep 8021q")
      tlog(vlan_mod)

      # Check systemd-networkd config files
      log_section("CONFIG", "systemd-networkd config files")
      code, networkd_files = server.execute("ls -la /etc/systemd/network/ 2>&1")
      tlog(networkd_files)

      # Phase 3: Verify VLAN interfaces
      log_section("PHASE 3", "VLAN Interface Verification")

      interfaces = server.succeed("ip -br link")
      tlog("Interfaces:")
      for line in interfaces.strip().split("\n"):
          tlog(f"  {line}")

      # Check VLAN details
      log_section("VLAN", "VLAN Interface Details")
      code, vlan_interfaces = server.execute("ip -d link show | grep -A1 'vlan\\|802\\.1Q' 2>&1")
      if code == 0:
          tlog(vlan_interfaces)
      else:
          tlog("No VLAN interfaces found")

      ip_addrs = server.succeed("ip -br addr")
      tlog("\nIP Addresses:")
      for line in ip_addrs.strip().split("\n"):
          tlog(f"  {line}")

      # Verify cluster VLAN (eth1.200)
      log_section("VERIFY", "Cluster VLAN Check (eth1.200)")
      code, vlan200 = server.execute("ip addr show eth1.200 2>&1")
      tlog(vlan200)

      cluster_ip = server.succeed("ip -4 addr show eth1.200 | grep -oP '(?<=inet )\\S+'")
      tlog(f"Cluster VLAN IP: {cluster_ip.strip()}")
      assert "192.168.200.1" in cluster_ip, f"Expected 192.168.200.1, got {cluster_ip}"
      tlog("✓ eth1.200 has correct IP address")

      # Verify storage VLAN (eth1.100)
      log_section("VERIFY", "Storage VLAN Check (eth1.100)")
      code, vlan100 = server.execute("ip addr show eth1.100 2>&1")
      tlog(vlan100)

      storage_ip = server.succeed("ip -4 addr show eth1.100 | grep -oP '(?<=inet )\\S+'")
      tlog(f"Storage VLAN IP: {storage_ip.strip()}")
      assert "192.168.100.1" in storage_ip, f"Expected 192.168.100.1, got {storage_ip}"
      tlog("✓ eth1.100 has correct IP address")

      # Check routing table
      log_section("ROUTES", "Routing Table")
      routes = server.succeed("ip route")
      tlog(routes.strip())

      log_summary("ISAR K3s Network VLANs Test", "network-vlans", [
          "eth1.200 (cluster VLAN): 192.168.200.1/24",
          "eth1.100 (storage VLAN): 192.168.100.1/24",
          "802.1Q VLAN tagging functional"
      ])
    '';
  };

in
test
