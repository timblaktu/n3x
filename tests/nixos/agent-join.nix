# NixOS Integration Test: K3s Agent Joining Server
# Tests that a K3s agent node can successfully join a K3s server cluster
#
# Run with:
#   nix build .#checks.x86_64-linux.k3s-agent-join
#   nix build .#checks.x86_64-linux.k3s-agent-join.driverInteractive  # For debugging

{ pkgs, lib, ... }:

let
  testScripts = import ../lib/test-scripts { inherit lib; };
in

pkgs.testers.runNixOSTest {
  name = "k3s-agent-join";

  nodes = {
    server = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/common/networking.nix
        ../../backends/nixos/modules/roles/k3s-common.nix
      ];

      # VM resource allocation for server
      virtualisation = {
        memorySize = 4096; # 4GB RAM for K3s control plane
        cores = 2;
        diskSize = 20480; # 20GB disk
      };

      # K3s server configuration
      services.k3s = {
        enable = true;
        role = "server";
        clusterInit = true;

        # Use static token for testing (INSECURE - test only)
        tokenFile = pkgs.writeText "k3s-token" "test-cluster-token-insecure";

        extraFlags = [
          "--write-kubeconfig-mode=0644"
          "--disable=traefik"
          "--disable=servicelb"
          "--cluster-cidr=10.42.0.0/16"
          "--service-cidr=10.43.0.0/16"
          "--node-ip=192.168.1.1"
        ];
      };

      # Network configuration
      networking = {
        firewall = {
          enable = true;
          allowedTCPPorts = [
            6443 # Kubernetes API server
            10250 # Kubelet API
            2379 # etcd client
            2380 # etcd peer
          ];
          allowedUDPPorts = [
            8472 # Flannel VXLAN
          ];
        };
        interfaces.eth1.ipv4.addresses = [{
          address = "192.168.1.1";
          prefixLength = 24;
        }];
      };

      environment.systemPackages = with pkgs; [
        k3s
        kubectl
      ];
    };

    agent = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/common/networking.nix
        ../../backends/nixos/modules/roles/k3s-common.nix
      ];

      # VM resource allocation for agent
      virtualisation = {
        memorySize = 2048; # 2GB RAM for agent
        cores = 2;
        diskSize = 20480; # 20GB disk
      };

      # K3s agent configuration
      services.k3s = {
        enable = true;
        role = "agent";

        # Point to the server
        serverAddr = "https://192.168.1.1:6443";

        # Use same token as server (INSECURE - test only)
        tokenFile = pkgs.writeText "k3s-token" "test-cluster-token-insecure";

        extraFlags = [
          "--node-ip=192.168.1.2"
        ];
      };

      # Network configuration
      networking = {
        firewall = {
          enable = true;
          allowedTCPPorts = [
            10250 # Kubelet API
          ];
          allowedUDPPorts = [
            8472 # Flannel VXLAN
          ];
        };
        interfaces.eth1.ipv4.addresses = [{
          address = "192.168.1.2";
          prefixLength = 24;
        }];
      };

      environment.systemPackages = with pkgs; [
        k3s
      ];
    };
  };

  testScript = ''
    ${testScripts.utils.all}

    log_section("TEST", "K3s Agent Join")

    # Start all nodes
    tlog("[1/8] Starting VMs...")
    start_all()
    server.wait_for_unit("multi-user.target")
    agent.wait_for_unit("multi-user.target")
    tlog("  Both VMs booted successfully")

    # Wait for server K3s service to start
    tlog("[2/8] Waiting for K3s server to start...")
    server.wait_for_unit("k3s.service")
    tlog("  K3s server service is active")

    # Wait for server API to be available
    tlog("[3/8] Waiting for Kubernetes API server...")
    server.wait_for_open_port(6443)
    server.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=120)
    tlog("  Kubernetes API server is ready")

    # Verify server node is Ready
    tlog("[4/8] Waiting for server node to be Ready...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep server | grep -w Ready",
        timeout=120
    )
    tlog("  Server node is Ready")

    # Wait for agent K3s service to start
    tlog("[5/8] Waiting for K3s agent to start...")
    agent.wait_for_unit("k3s.service")
    tlog("  K3s agent service is active")

    # Wait for agent to join the cluster
    tlog("[6/8] Waiting for agent to join cluster...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep agent",
        timeout=120
    )
    tlog("  Agent node registered in cluster")

    # Wait for agent node to be Ready
    tlog("[7/8] Waiting for agent node to be Ready...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep agent | grep -w Ready",
        timeout=120
    )
    tlog("  Agent node is Ready")

    # Verify cluster state
    tlog("[8/8] Verifying final cluster state...")
    nodes_output = server.succeed("k3s kubectl get nodes -o wide")
    tlog("Cluster nodes:")
    tlog(nodes_output)

    # Verify we have exactly 2 nodes
    node_count = server.succeed(
        "k3s kubectl get nodes --no-headers | wc -l"
    ).strip()
    assert node_count == "2", f"Expected 2 nodes, got {node_count}"
    tlog(f"  Cluster has {node_count} nodes")

    # Verify both nodes are Ready
    ready_count = server.succeed(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l"
    ).strip()
    assert ready_count == "2", f"Expected 2 Ready nodes, got {ready_count}"
    tlog(f"  All {ready_count} nodes are Ready")

    # Get all pods status
    pods_output = server.succeed("k3s kubectl get pods -A -o wide")
    tlog("All pods:")
    tlog(pods_output)

    # Test workload scheduling on agent
    tlog("Testing workload scheduling on agent...")
    server.succeed(
        "k3s kubectl create deployment nginx-test --image=nginx:alpine --replicas=2"
    )

    server.wait_until_succeeds(
        "k3s kubectl get deployment nginx-test -o jsonpath='{.status.readyReplicas}' | grep 2",
        timeout=120
    )
    tlog("  Test deployment with 2 replicas is ready")

    # Verify pods are distributed
    pods_on_nodes = server.succeed(
        "k3s kubectl get pods -l app=nginx-test -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}'"
    )
    tlog("Pods distributed across nodes:")
    tlog(pods_on_nodes)

    # Clean up
    server.succeed("k3s kubectl delete deployment nginx-test")

    tlog("")
    tlog("K3s Agent Join Test - PASSED")
  '';
}
