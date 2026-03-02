# Layer 3: K3s Service Starts Smoke Test
#
# Can K3s service start and open port 6443?
# Expected duration: 60-90 seconds
#
# This test verifies:
# - K3s binary is present
# - K3s service starts without crashing
# - Port 6443 opens (API server listening)
#
# We DO NOT verify:
# - Node reaches Ready state (that's a separate test)
# - Cluster formation
# - Pod scheduling
#
# If this test fails, K3s is misconfigured or has dependency issues.
#
# Usage:
#   nix build .#checks.x86_64-linux.smoke-k3s-service-starts
#   nix build .#checks.x86_64-linux.smoke-k3s-service-starts.driverInteractive

{ pkgs, lib, ... }:

let
  testScripts = import ../../lib/test-scripts { inherit lib; };
in

pkgs.testers.runNixOSTest {
  name = "smoke-k3s-service-starts";

  nodes = {
    server = { config, pkgs, ... }: {
      virtualisation = {
        memorySize = 2048; # K3s needs more memory than minimal VM
        cores = 2;
        diskSize = 8192;
      };

      services.k3s = {
        enable = true;
        role = "server";
        clusterInit = true;
        tokenFile = pkgs.writeText "k3s-token" "smoke-test-token";
        extraFlags = [
          "--write-kubeconfig-mode=0644"
          "--disable=traefik"
          "--disable=servicelb"
        ];
      };

      environment.systemPackages = [ pkgs.k3s ];
    };
  };

  testScript = ''
    ${testScripts.utils.all}
    import time
    start = time.time()

    log_section("SMOKE TEST", "K3s Service Starts")

    # Step 1: Boot VM
    tlog("[1/5] Starting VM...")
    server.start()
    server.wait_for_unit("multi-user.target", timeout=45)
    tlog(f"  Booted in {time.time() - start:.1f}s")

    # Step 2: Verify k3s binary
    tlog("[2/5] Checking k3s binary...")
    server.succeed("test -x /run/current-system/sw/bin/k3s")
    version = server.succeed("k3s --version").strip()
    tlog(f"  {version}")

    # Step 3: Wait for k3s service to be active
    tlog("[3/5] Waiting for k3s.service to start...")
    server.wait_for_unit("k3s.service", timeout=60)
    tlog(f"  k3s.service active at {time.time() - start:.1f}s")

    # Step 4: Wait for port 6443 (API server)
    tlog("[4/5] Waiting for API server port 6443...")
    server.wait_for_open_port(6443, timeout=30)
    tlog(f"  Port 6443 open at {time.time() - start:.1f}s")

    # Step 5: Quick API health check (may not be fully ready)
    tlog("[5/5] Testing API responsiveness...")
    code, output = server.execute("curl -sk https://localhost:6443/livez 2>&1")
    tlog(f"  /livez response: {output.strip()}")
    # Note: We don't assert on this - just logging. Full readiness is a separate test.

    elapsed = time.time() - start
    tlog(f"SMOKE TEST PASSED in {elapsed:.1f}s")
    tlog("  k3s service started and API port is open")
  '';
}
