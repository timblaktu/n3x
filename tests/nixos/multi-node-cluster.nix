# NixOS Integration Test: Multi-node K3s Cluster
# Tests a 3-node K3s cluster with 1 server and 2 agents
#
# Run with:
#   nix build .#checks.x86_64-linux.k3s-multi-node
#   nix build .#checks.x86_64-linux.k3s-multi-node.driverInteractive  # For debugging

{ pkgs, lib, ... }:

let
  testScripts = import ../lib/test-scripts { inherit lib; };
in

pkgs.testers.runNixOSTest {
  name = "k3s-multi-node-cluster";

  nodes = {
    server = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/common/networking.nix
        ../../backends/nixos/modules/roles/k3s-common.nix
      ];

      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 20480;
      };

      services.k3s = {
        enable = true;
        role = "server";
        clusterInit = true;
        tokenFile = pkgs.writeText "k3s-token" "multi-node-test-token";

        extraFlags = [
          "--write-kubeconfig-mode=0644"
          "--disable=traefik"
          "--disable=servicelb"
          "--cluster-cidr=10.42.0.0/16"
          "--service-cidr=10.43.0.0/16"
          "--node-ip=192.168.1.1"
        ];
      };

      networking = {
        firewall = {
          enable = true;
          allowedTCPPorts = [ 6443 10250 2379 2380 ];
          allowedUDPPorts = [ 8472 ];
        };
        interfaces.eth1.ipv4.addresses = [{
          address = "192.168.1.1";
          prefixLength = 24;
        }];
      };

      environment.systemPackages = with pkgs; [ k3s kubectl ];
    };

    agent1 = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/common/networking.nix
        ../../backends/nixos/modules/roles/k3s-common.nix
      ];

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 20480;
      };

      services.k3s = {
        enable = true;
        role = "agent";
        serverAddr = "https://192.168.1.1:6443";
        tokenFile = pkgs.writeText "k3s-token" "multi-node-test-token";
        extraFlags = [ "--node-ip=192.168.1.10" ];
      };

      networking = {
        firewall = {
          enable = true;
          allowedTCPPorts = [ 10250 ];
          allowedUDPPorts = [ 8472 ];
        };
        interfaces.eth1.ipv4.addresses = [{
          address = "192.168.1.10";
          prefixLength = 24;
        }];
      };

      environment.systemPackages = with pkgs; [ k3s ];
    };

    agent2 = { config, pkgs, modulesPath, ... }: {
      imports = [
        ../../backends/nixos/modules/common/base.nix
        ../../backends/nixos/modules/common/nix-settings.nix
        ../../backends/nixos/modules/common/networking.nix
        ../../backends/nixos/modules/roles/k3s-common.nix
      ];

      virtualisation = {
        memorySize = 2048;
        cores = 2;
        diskSize = 20480;
      };

      services.k3s = {
        enable = true;
        role = "agent";
        serverAddr = "https://192.168.1.1:6443";
        tokenFile = pkgs.writeText "k3s-token" "multi-node-test-token";
        extraFlags = [ "--node-ip=192.168.1.11" ];
      };

      networking = {
        firewall = {
          enable = true;
          allowedTCPPorts = [ 10250 ];
          allowedUDPPorts = [ 8472 ];
        };
        interfaces.eth1.ipv4.addresses = [{
          address = "192.168.1.11";
          prefixLength = 24;
        }];
      };

      environment.systemPackages = with pkgs; [ k3s ];
    };
  };

  testScript = ''
    ${testScripts.utils.all}

    log_section("TEST", "K3s Multi-node Cluster (1 Server + 2 Agents)")

    # Start all nodes
    tlog("[1/10] Starting all VMs...")
    start_all()
    server.wait_for_unit("multi-user.target")
    agent1.wait_for_unit("multi-user.target")
    agent2.wait_for_unit("multi-user.target")
    tlog("  All 3 VMs booted successfully")

    # Wait for server K3s
    tlog("[2/10] Waiting for K3s server...")
    server.wait_for_unit("k3s.service")
    server.wait_for_open_port(6443)
    server.wait_until_succeeds("k3s kubectl get --raw /readyz", timeout=120)
    tlog("  K3s server is ready")

    # Wait for server node to be Ready
    tlog("[3/10] Waiting for server node to be Ready...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep server | grep -w Ready",
        timeout=120
    )
    tlog("  Server node is Ready")

    # Start agents
    tlog("[4/10] Waiting for agent services...")
    agent1.wait_for_unit("k3s.service")
    agent2.wait_for_unit("k3s.service")
    tlog("  Both agent services are active")

    # Wait for agents to join
    tlog("[5/10] Waiting for agent1 to join...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep agent1",
        timeout=120
    )
    tlog("  Agent1 joined the cluster")

    tlog("[6/10] Waiting for agent2 to join...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep agent2",
        timeout=120
    )
    tlog("  Agent2 joined the cluster")

    # Wait for all nodes to be Ready
    tlog("[7/10] Waiting for all nodes to be Ready...")
    server.wait_until_succeeds(
        "k3s kubectl get nodes --no-headers | grep -w Ready | wc -l | grep 3",
        timeout=180
    )
    tlog("  All 3 nodes are Ready")

    # Show cluster state
    tlog("[8/10] Cluster state:")
    nodes_output = server.succeed("k3s kubectl get nodes -o wide")
    tlog(nodes_output)

    pods_output = server.succeed("k3s kubectl get pods -A -o wide")
    tlog("System pods:")
    tlog(pods_output)

    # Test workload distribution
    tlog("[9/10] Testing workload distribution...")
    server.succeed(
        "k3s kubectl create deployment nginx-test --image=nginx:alpine --replicas=3"
    )

    server.wait_until_succeeds(
        "k3s kubectl get deployment nginx-test -o jsonpath='{.status.readyReplicas}' | grep 3",
        timeout=180
    )
    tlog("  3 replicas deployed successfully")

    # Check pod distribution
    pod_distribution = server.succeed(
        "k3s kubectl get pods -l app=nginx-test -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | sort | uniq -c"
    )
    tlog("Pod distribution across nodes:")
    tlog(pod_distribution)

    # Verify system pods are running
    tlog("[10/10] Verifying system components...")
    server.succeed("k3s kubectl get pods -n kube-system -l k8s-app=kube-dns")
    tlog("  CoreDNS is running")

    server.succeed("k3s kubectl get pods -n kube-system -l app=local-path-provisioner")
    tlog("  Local-path-provisioner is running")

    # Clean up
    server.succeed("k3s kubectl delete deployment nginx-test")

    tlog("")
    tlog("K3s Multi-node Cluster Test - PASSED")
  '';
}
