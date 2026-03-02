# NixOS Integration Test: Single K3s Server
# Tests that a K3s server node boots, initializes, and is functional
#
# Run with:
#   nix build .#checks.x86_64-linux.k3s-single-server
#   nix build .#checks.x86_64-linux.k3s-single-server.driverInteractive  # For debugging

{ pkgs, lib, inputs, ... }:

let
  testScripts = import ../lib/test-scripts { inherit lib; };
in

pkgs.testers.runNixOSTest {
  name = "k3s-single-server";

  nodes = {
    server = { config, pkgs, modulesPath, ... }: {
      _module.args = { inherit inputs; };
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/common/networking.nix
        ../../backends/nixos/modules/roles/k3s-common.nix
      ];

      # VM resource allocation
      virtualisation = {
        memorySize = 4096; # 4GB RAM for K3s control plane
        cores = 2;
        diskSize = 20480; # 20GB disk
      };

      # K3s server configuration
      services.k3s = {
        enable = true;
        role = "server";

        # Initialize a new cluster
        clusterInit = true;

        # Use static token for testing (INSECURE - test only)
        tokenFile = pkgs.writeText "k3s-token" "test-server-token-insecure";

        # K3s configuration flags
        extraFlags = [
          "--write-kubeconfig-mode=0644" # Allow non-root kubectl access
          "--disable=traefik" # We'll deploy our own ingress
          "--disable=servicelb" # We'll use MetalLB
          "--cluster-cidr=10.42.0.0/16" # Pod network CIDR
          "--service-cidr=10.43.0.0/16" # Service network CIDR
        ];
      };

      # Firewall configuration for K3s
      networking.firewall = {
        enable = true;
        allowedTCPPorts = [
          6443 # Kubernetes API server
          10250 # Kubelet API
          2379 # etcd client requests
          2380 # etcd peer communication
        ];
        allowedUDPPorts = [
          8472 # Flannel VXLAN overlay network
        ];
      };

      # Add kubectl to system packages for testing
      environment.systemPackages = with pkgs; [
        k3s
        kubectl
      ];
    };
  };

  testScript = ''
    ${testScripts.utils.all}

    log_section("TEST", "K3s Single Server")

    # Start the server VM
    tlog("[1/6] Starting server VM...")
    server.start()
    server.wait_for_unit("multi-user.target")
    tlog("  Server VM booted successfully")

    # Wait for K3s service to start
    tlog("[2/6] Waiting for K3s service to start...")
    server.wait_for_unit("k3s.service")
    tlog("  K3s service is active")

    # Wait for Kubernetes API to be available
    tlog("[3/6] Waiting for Kubernetes API server...")
    server.wait_for_open_port(6443)
    server.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=120)
    tlog("  Kubernetes API server is ready")

    # Verify the server node is registered
    tlog("[4/6] Verifying node registration...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes | grep server",
        timeout=60
    )

    # Get node status
    node_status = server.succeed("k3s kubectl get nodes -o wide")
    tlog("Node status:")
    tlog(node_status)

    # Wait for node to be Ready
    tlog("[5/6] Waiting for node to reach Ready state...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | awk '{print $2}' | grep -w Ready",
        timeout=120
    )
    tlog("  Node is Ready")

    # Verify core system pods are running
    tlog("[6/6] Verifying system pods...")
    server.wait_until_succeeds(
        "k3s kubectl get pods -n kube-system --no-headers | grep -v Completed",
        timeout=120
    )

    # Get all pods status
    pods_status = server.succeed("k3s kubectl get pods -A -o wide")
    tlog("All pods:")
    tlog(pods_status)

    # Count running pods in kube-system
    running_pods = server.succeed(
        "k3s kubectl get pods -n kube-system --field-selector=status.phase=Running --no-headers | wc -l"
    ).strip()

    tlog(f"Found {running_pods} running system pods")

    # Verify critical components are present
    tlog("Verifying critical components...")
    server.succeed("k3s kubectl get pods -n kube-system -l k8s-app=kube-dns")
    tlog("  CoreDNS is running")

    server.succeed("k3s kubectl get pods -n kube-system -l app=local-path-provisioner")
    tlog("  Local-path-provisioner is running")

    # Test basic workload deployment
    tlog("Testing workload deployment...")
    server.succeed(
        "k3s kubectl create deployment nginx-test --image=nginx:alpine"
    )

    # Wait for deployment to be ready
    server.wait_until_succeeds(
        "k3s kubectl get deployment nginx-test -o jsonpath='{.status.readyReplicas}' | grep 1",
        timeout=120
    )
    tlog("  Test deployment is ready")

    # Get deployment status
    deployment_status = server.succeed("k3s kubectl get deployments,pods -l app=nginx-test")
    tlog("Test deployment:")
    tlog(deployment_status)

    # Verify pod is running
    pod_phase = server.succeed(
        "k3s kubectl get pods -l app=nginx-test -o jsonpath='{.items[0].status.phase}'"
    ).strip()
    assert pod_phase == "Running", f"Expected pod phase 'Running', got '{pod_phase}'"
    tlog("  Test pod is Running")

    # Clean up test deployment
    server.succeed("k3s kubectl delete deployment nginx-test")

    tlog("")
    tlog("K3s Single Server Test - PASSED")
  '';
}
