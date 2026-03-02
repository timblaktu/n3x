# =============================================================================
# K3s Service Test
# =============================================================================
#
# Tests that the ISAR k3s-server.service starts and API responds.
# This fills the gap between network config tests (L3 network) and cluster tests (L4+).
#
# Test validates:
# - k3s binary is present and executable
# - k3s-server.service starts successfully
# - API server port 6443 is listening
# - kubectl can query the API (local node shows Ready)
#
# REQUIREMENTS:
#   - ISAR image built with: kas/test-k3s-overlay.yml
#   - k3s-server service must be enabled
#
# Usage:
#   nix build '.#checks.x86_64-linux.debian-service'
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
  k3sPhase = import ../lib/test-scripts/phases/k3s.nix { inherit lib; };

  test = mkISARTest {
    name = "k3s-service";

    # Single VLAN - not testing network profiles, just k3s service
    vlans = [ 1 ];

    # Longer timeout for k3s startup (downloads images, initializes etcd)
    globalTimeout = 900;

    machines = {
      server = {
        image = isarArtifacts.qemuamd64.server.wic;
        memory = 4096; # k3s needs memory for containers
        cpus = 4;
      };
    };

    # Note: testScript content must start at column 0 because testScripts.utils.all
    # contains Python code at column 0 (function definitions, imports).
    testScript = ''
      ${testScripts.utils.all}

      log_banner("ISAR K3s Service Test", "k3s-service", {
          "Layer": "3 (K3s Service Starts)",
          "Image": "qemuamd64 server",
          "Service": "k3s-server.service",
          "Validates": "k3s binary, service start, API response"
      })

      # Phase 1: Boot with GRUB serial protection
      ${bootPhase.debian.bootWithBackdoor { node = "server"; displayName = "ISAR K3s server"; }}

      # Phase 2: Verify k3s binary
      ${k3sPhase.debian.verifyK3sBinary { node = "server"; }}

      # K3s requires a default route to start (checks /proc/net/route).
      # In nixos-test-driver VMs with isolated VLANs, there's no gateway.
      # Add a dummy default route via eth1 to satisfy k3s route check.
      # This is test-only - production images have real gateways.
      log_section("NETWORK", "Waiting for networkd and adding default route for k3s")

      # Stop k3s if it's trying to start (it may have started on boot and failed)
      server.execute("systemctl stop k3s-server.service 2>&1 || true")

      # Wait for systemd-networkd to configure eth1 with its baked-in profile IP.
      # Without this, eth1 may not have an IP and route add fails silently.
      server.wait_for_unit("systemd-networkd.service", timeout=60)
      tlog("  systemd-networkd is active")

      import time as time_mod
      time_mod.sleep(2)
      server.succeed("true")  # flush serial buffer after sleep

      # Verify eth1 has an IP before adding route
      server.wait_until_succeeds("ip addr show eth1 | grep 'inet '", timeout=30)
      eth1_ip = server.succeed("ip -4 addr show eth1 | grep -oP '(?<=inet )\\S+'")
      tlog(f"  eth1 IP: {eth1_ip.strip()}")

      code, routes_before = server.execute("ip route show 2>&1")
      tlog(f"  Routes before:\n{routes_before.strip()}")

      # Add default route via eth1's network (192.168.1.254 is arbitrary gateway in subnet)
      code, route_out = server.execute("ip route add default via 192.168.1.254 dev eth1 2>&1")
      if code != 0:
          tlog(f"  WARNING: route add returned {code}: {route_out.strip()}")
          # Try alternative: route via the configured subnet
          server.execute("ip route add default dev eth1 2>&1")

      # Verify the default route is actually in /proc/net/route (what k3s checks)
      server.wait_until_succeeds("grep -q '00000000' /proc/net/route", timeout=10)
      tlog("  Default route confirmed in /proc/net/route")

      code, routes_after = server.execute("ip route show 2>&1")
      tlog(f"  Routes after:\n{routes_after.strip()}")

      # k3s kubelet needs /dev/kmsg for kernel message logging
      # In test VMs, /dev/kmsg may not be accessible. Create a writable symlink to /dev/null.
      log_section("KMSG", "Fixing /dev/kmsg for k3s kubelet")
      code, kmsg_check = server.execute("ls -la /dev/kmsg 2>&1")
      tlog(f"  Current /dev/kmsg: {kmsg_check.strip()}")

      # Remove existing kmsg and create a link to /dev/null
      # This satisfies kubelet's open() call without needing actual kernel messages
      server.execute("rm -f /dev/kmsg && ln -s /dev/null /dev/kmsg")

      code, kmsg_after = server.execute("ls -la /dev/kmsg 2>&1")
      tlog(f"  Fixed /dev/kmsg: {kmsg_after.strip()}")

      # Check disk space - k3s needs to extract ~200MB of embedded binaries
      log_section("DISK", "Checking disk space")
      df_output = server.succeed("df -h /var/lib/rancher")
      tlog(f"  {df_output.strip()}")

      # Phase 3: Ensure k3s-server.service starts
      log_section("PHASE 3", "Starting k3s-server.service")

      # Check initial status
      code, initial_status = server.execute("systemctl is-active k3s-server.service 2>&1")
      tlog(f"  Initial service state: {initial_status.strip()}")

      # If service isn't active, try to start it
      if code != 0:
          tlog("  Service not active, attempting to start...")
          code, start_output = server.execute("systemctl start k3s-server.service 2>&1")
          if code != 0:
              # Show journal if start failed
              tlog("  Start command returned non-zero, checking journal...")
              code, journal = server.execute("journalctl -u k3s-server -n 50 --no-pager 2>&1")
              tlog(f"  Journal:\n{journal}")

      # Wait for the service to be active (with timeout)
      server.wait_for_unit("k3s-server.service", timeout=120)
      tlog("  k3s-server.service is active")

      # Phase 4: Wait for API server port
      log_section("PHASE 4", "Waiting for API server")

      # k3s takes time to extract embedded binaries and start containerd/etcd
      run_with_retry(
          server, "ss -tlnp | grep 6443",
          max_attempts=30, delay=10, log_every=6,
          description="API port 6443"
      )

      tlog("  API server port 6443 is open")

      # Phase 5: Wait for kubeconfig and verify kubectl works
      log_section("PHASE 5", "Verifying kubectl access")

      # Wait for kubeconfig to be created
      result = run_with_retry(
          server, "test -f /etc/rancher/k3s/k3s.yaml",
          max_attempts=30, delay=5, on_failure="warn",
          description="kubeconfig"
      )

      # Try kubectl get nodes
      code, nodes_output = server.execute("kubectl get nodes -o wide 2>&1")
      if code == 0:
          tlog(f"  Nodes:\n{nodes_output}")
      else:
          tlog(f"  kubectl failed: {nodes_output}")
          # Show API server logs for debugging
          code, logs = server.execute("journalctl -u k3s-server -n 30 --no-pager 2>&1")
          tlog(f"  Recent k3s-server logs:\n{logs}")

      # Phase 6: Verify node is Ready (may take a moment)
      log_section("PHASE 6", "Waiting for node Ready state")

      server.wait_until_succeeds(
          "kubectl get nodes --no-headers 2>&1 | grep -w Ready",
          timeout=180
      )
      tlog("  Node is Ready")

      # Show final node status
      nodes = server.succeed("kubectl get nodes -o wide")
      tlog(f"\n  Final node status:\n{nodes}")

      # Show system pods
      code, pods = server.execute("kubectl get pods -A -o wide 2>&1")
      tlog(f"\n  System pods:\n{pods}")

      # Memory usage
      log_section("MEMORY", "Resource usage")
      mem = server.succeed("free -h")
      tlog(f"{mem.strip()}")

      log_summary("ISAR K3s Service Test", "k3s-service", [
          "k3s binary present and executable",
          "k3s-server.service started successfully",
          "API server responding on port 6443",
          "kubectl working with kubeconfig",
          "Node reached Ready state"
      ])
    '';
  };

in
test
