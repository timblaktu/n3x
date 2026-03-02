# =============================================================================
# K3s Simple Network Test
# =============================================================================
#
# Tests the simple network profile on ISAR k3s server image.
# Uses single flat network via eth1 (192.168.1.0/24).
#
# REQUIREMENTS:
#   - ISAR image built with: kas/test-k3s-overlay.yml:kas/network/simple.yml
#   - Image must include netplan-k3s-config package with simple profile
#
# Usage:
#   # Build the test driver:
#   nix-build -E 'with import <nixpkgs> {}; callPackage ./k3s-network-simple.nix {}'
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
    name = "k3s-network-simple";

    # Single VLAN for simple profile
    vlans = [ 1 ];

    machines = {
      server = {
        image = isarArtifacts.qemuamd64.server.wic;
        memory = 4096;
        cpus = 4;
      };
    };

    # Note: testScript content must start at column 0 because testScripts.utils.all
    # contains Python code at column 0 (function definitions, imports).
    testScript = ''
      ${testScripts.utils.all}

      log_banner("ISAR K3s Network Simple Test", "network-simple", {
          "Layer": "4 (Network Profile)",
          "Profile": "simple",
          "Expected IP": "192.168.1.1/24 on eth1"
      })

      # Phase 1: Boot with GRUB serial protection
      ${bootPhase.debian.bootWithBackdoor { node = "server"; displayName = "ISAR K3s server"; }}

      # Phase 2: Wait for network configuration
      log_section("PHASE 2", "Network Configuration")

      server.wait_for_unit("systemd-networkd.service", timeout=60)
      tlog("  systemd-networkd is active")

      # Wait for networkd to configure eth1
      server.wait_until_succeeds("ip -4 addr show eth1 | grep inet", timeout=30)
      tlog("  eth1 interface configured")

      # Check systemd-networkd-config files
      log_section("CONFIG", "systemd-networkd-config files")
      networkd_files = server.succeed("ls -la /etc/systemd/network/ 2>&1 || true")
      tlog(networkd_files)

      # Phase 3: Verify network interfaces
      log_section("PHASE 3", "Network Interface Verification")

      interfaces = server.succeed("ip -br link")
      tlog("Interfaces:")
      for line in interfaces.strip().split("\n"):
          tlog(f"  {line}")

      ip_addrs = server.succeed("ip -br addr")
      tlog("\nIP Addresses:")
      for line in ip_addrs.strip().split("\n"):
          tlog(f"  {line}")

      # Verify eth1 has the expected IP (192.168.1.1/24 for server-1)
      log_section("VERIFY", "Cluster Interface Check")
      cluster_ip = server.succeed("ip -4 addr show eth1 | grep -oP '(?<=inet )\\S+'")
      tlog(f"eth1 IP: {cluster_ip.strip()}")
      assert "192.168.1.1" in cluster_ip, f"Expected 192.168.1.1, got {cluster_ip}"
      tlog("✓ eth1 has correct IP address")

      # Check routing table
      log_section("ROUTES", "Routing Table")
      routes = server.succeed("ip route")
      tlog(routes.strip())

      # Diagnostic: systemd-networkd status
      log_section("DIAG", "systemd-networkd status")
      code, networkd = server.execute("systemctl status systemd-networkd --no-pager 2>&1")
      tlog(networkd)

      # Check k3s configuration
      log_section("K3S", "K3s Network Configuration")
      code, k3s_config = server.execute("cat /etc/default/k3s-server 2>&1")
      tlog(k3s_config)

      code, k3s_flags = server.execute("cat /etc/rancher/k3s/config.yaml 2>&1 || echo 'No k3s config.yaml'")
      tlog(k3s_flags)

      log_summary("ISAR K3s Network Simple Test", "network-simple", [
          "eth1 configured with 192.168.1.1/24",
          "systemd-networkd active",
          "Simple network profile functional"
      ])
    '';
  };

in
test
