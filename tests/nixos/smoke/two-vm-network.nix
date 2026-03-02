# Layer 2: Two VM Network Smoke Test
#
# Can two VMs see each other over the test network?
# Expected duration: 30-60 seconds
#
# This test verifies:
# - Two VMs can boot in parallel
# - VDE network switch works
# - VMs get IP addresses
# - VMs can ping each other
#
# If this test fails, multi-VM K3s tests will fail.
#
# Usage:
#   nix build .#checks.x86_64-linux.smoke-two-vm-network
#   nix build .#checks.x86_64-linux.smoke-two-vm-network.driverInteractive

{ pkgs, lib, ... }:

let
  testScripts = import ../../lib/test-scripts { inherit lib; };
in

pkgs.testers.runNixOSTest {
  name = "smoke-two-vm-network";

  nodes = {
    vm1 = { ... }: {
      virtualisation = {
        memorySize = 512;
        cores = 1;
      };
      # Static IP to avoid DHCP delays
      networking.interfaces.eth1.ipv4.addresses = [{
        address = "192.168.1.1";
        prefixLength = 24;
      }];
    };

    vm2 = { ... }: {
      virtualisation = {
        memorySize = 512;
        cores = 1;
      };
      networking.interfaces.eth1.ipv4.addresses = [{
        address = "192.168.1.2";
        prefixLength = 24;
      }];
    };
  };

  testScript = ''
    ${testScripts.utils.all}
    import time
    start = time.time()

    log_section("SMOKE TEST", "Two VM Network")

    # Start both VMs in parallel
    tlog("[1/4] Starting both VMs...")
    vm1.start()
    vm2.start()

    # Wait for boot
    tlog("[2/4] Waiting for VMs to boot...")
    vm1.wait_for_unit("multi-user.target", timeout=30)
    vm2.wait_for_unit("multi-user.target", timeout=30)
    tlog("  Both VMs booted")

    # Check IPs are configured
    tlog("[3/4] Verifying IP configuration...")
    vm1.succeed("ip addr show eth1 | grep 192.168.1.1")
    vm2.succeed("ip addr show eth1 | grep 192.168.1.2")
    tlog("  IPs configured correctly")

    # Test connectivity (wait_until_succeeds handles VDE switch MAC learning)
    tlog("[4/4] Testing connectivity...")
    vm1.wait_until_succeeds("ping -c 1 -W 5 192.168.1.2", timeout=15)
    tlog("  vm1 -> vm2: OK")
    vm2.wait_until_succeeds("ping -c 1 -W 5 192.168.1.1", timeout=15)
    tlog("  vm2 -> vm1: OK")

    elapsed = time.time() - start
    tlog(f"SMOKE TEST PASSED in {elapsed:.1f}s")
  '';
}
