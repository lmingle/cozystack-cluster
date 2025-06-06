#!/bin/bash

# CozyStack Talos Bootstrap Script
# This script verifies dependencies and bootstraps a 3-node CozyStack cluster

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Node configuration
NODES=(
    "192.168.3.5"
    "192.168.3.6"
    "192.168.3.7"
)

echo -e "${BLUE}=== CozyStack Talos Bootstrap Script ===${NC}"
echo ""

# Function to check if a command exists
check_command() {
    local cmd=$1
    local package=$2

    if command -v "$cmd" &> /dev/null; then
        echo -e "${GREEN}✓${NC} $cmd is installed"
        return 0
    else
        echo -e "${RED}✗${NC} $cmd is not installed"
        echo -e "  Install with: ${YELLOW}$package${NC}"
        return 1
    fi
}

# Function to verify dependencies
verify_dependencies() {
    echo -e "${BLUE}Checking dependencies...${NC}"
    local missing=0

    # Check talosctl
    if ! check_command "talosctl" "curl -sL https://talos.dev/install | sh"; then
        missing=$((missing + 1))
    fi

    # Check dialog
    if ! check_command "dialog" "apt install dialog (Ubuntu/Debian) or yum install dialog (RHEL/CentOS)"; then
        missing=$((missing + 1))
    fi

    # Check nmap
    if ! check_command "nmap" "apt install nmap (Ubuntu/Debian) or yum install nmap (RHEL/CentOS)"; then
        missing=$((missing + 1))
    fi

    # Check talos-bootstrap
    if ! check_command "talos-bootstrap" "git clone https://github.com/cozystack/talos-bootstrap && cd talos-bootstrap && sudo make install"; then
        missing=$((missing + 1))
    fi

    echo ""

    if [ $missing -gt 0 ]; then
        echo -e "${RED}Error: $missing dependencies are missing. Please install them before continuing.${NC}"
        exit 1
    fi

    echo -e "${GREEN}All dependencies are installed!${NC}"
    echo ""
}

# Function to verify patch files exist
verify_patch_files() {
    echo -e "${BLUE}Checking patch files...${NC}"
    local missing=0

    local required_files=(
        "patch.yaml"
        "patch-controlplane.yaml"
    )

    for file in "${required_files[@]}"; do
        if [ -f "$file" ]; then
            echo -e "${GREEN}✓${NC} Found $file"
        else
            echo -e "${RED}✗${NC} Missing $file"
            missing=$((missing + 1))
        fi
    done

    echo ""

    if [ $missing -gt 0 ]; then
        echo -e "${RED}Error: $missing patch files are missing.${NC}"
        echo -e "${YELLOW}Please create the required patch files before running this script.${NC}"
        exit 1
    fi

    echo -e "${GREEN}All patch files found!${NC}"
    echo ""
}

# Function to check node connectivity
check_node_connectivity() {
    local node=$1
    echo -n "Checking connectivity to $node... "

    if ping -c 1 -W 2 "$node" &> /dev/null; then
        echo -e "${GREEN}✓${NC}"
        return 0
    else
        echo -e "${RED}✗${NC}"
        return 1
    fi
}

# Function to verify node connectivity
verify_connectivity() {
    echo -e "${BLUE}Checking node connectivity...${NC}"
    local unreachable=0

    for node in "${NODES[@]}"; do
        if ! check_node_connectivity "$node"; then
            unreachable=$((unreachable + 1))
        fi
    done

    echo ""

    if [ $unreachable -gt 0 ]; then
        echo -e "${YELLOW}Warning: $unreachable nodes are unreachable.${NC}"
        echo -e "${YELLOW}Make sure all nodes are powered on and accessible.${NC}"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Aborting..."
            exit 1
        fi
    else
        echo -e "${GREEN}All nodes are reachable!${NC}"
    fi
    echo ""
}

# Function to generate cluster configuration (only once)
generate_cluster_config() {
    echo -e "${BLUE}Generating cluster configuration...${NC}"

    # Check if configurations already exist
    if [ -f "controlplane.yaml" ] && [ -f "worker.yaml" ] && [ -f "talosconfig" ]; then
        echo -e "${YELLOW}Existing cluster configuration found.${NC}"
        read -p "Regenerate configuration? This will create a new cluster. (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}Using existing configuration.${NC}"
            return 0
        fi
    fi

    # Generate configuration using talosctl
    echo -e "${BLUE}Generating PKI and initial configuration...${NC}"

    # Use talosctl to generate the cluster configuration
    # Generate config with the first node as the endpoint
    if talosctl gen config cozystack-cluster https://${NODES[0]}:6443 --config-patch @patch.yaml --config-patch-control-plane @patch-controlplane.yaml; then
        echo -e "${GREEN}✓ Generated cluster configuration${NC}"

        # Fix the talosconfig endpoints to include our nodes
        echo -e "${BLUE}Updating talosconfig endpoints...${NC}"
        # Create a temporary file with the endpoint fix
        cp talosconfig talosconfig.backup

        # Use yq or sed to update the endpoints (if yq is available, otherwise use sed)
        if command -v yq &> /dev/null; then
            yq eval ".contexts.cozystack-cluster.endpoints = [\"${NODES[0]}\"]" -i talosconfig
            echo -e "${GREEN}✓ Updated endpoints using yq${NC}"
        else
            # Fallback to sed - replace empty endpoints array
            sed -i "s/endpoints: \[\]/endpoints: \[\"${NODES[0]}\"\]/" talosconfig
            echo -e "${GREEN}✓ Updated endpoints using sed${NC}"
        fi

        echo -e "${BLUE}Talosconfig endpoints now set to: ${NODES[0]}${NC}"
    else
        echo -e "${RED}✗ Failed to generate cluster configuration${NC}"
        exit 1
    fi

    echo ""
}

# Function to wait for a node to be ready
wait_for_node_ready() {
    local node_ip=$1
    local node_name=$2
    local max_attempts=60  # 10 minutes max
    local attempt=0

    echo -e "${BLUE}Waiting for $node_name to be ready...${NC}"

    while [ $attempt -lt $max_attempts ]; do
        # Try to get node status - this will succeed once the node is ready
        if talosctl version --talosconfig talosconfig --nodes "$node_ip" --endpoints "$node_ip" &>/dev/null; then
            echo -e "${GREEN}✓ $node_name is ready${NC}"
            return 0
        fi

        # Show progress every 5 attempts (30 seconds)
        if [ $((attempt % 5)) -eq 0 ]; then
            echo -e "${YELLOW}Attempt $((attempt + 1))/$max_attempts - waiting for $node_name...${NC}"
        fi

        sleep 10
        attempt=$((attempt + 1))
    done

    echo -e "${RED}✗ Timeout waiting for $node_name to be ready${NC}"
    return 1
}

# Function to install Talos on a node
install_talos_node() {
    local node_ip=$1
    local node_name=$2
    local is_first_node=$3

    echo -e "${BLUE}Installing Talos on $node_name ($node_ip)...${NC}"

    # Apply the controlplane configuration to the node
    if talosctl apply-config --insecure --file controlplane.yaml --talosconfig talosconfig --nodes "$node_ip" --endpoints "$node_ip"; then
        echo -e "${GREEN}✓ Applied configuration to $node_name${NC}"
    else
        echo -e "${RED}✗ Failed to apply configuration to $node_name${NC}"
        exit 1
    fi

    # Wait for the node to be ready
    if ! wait_for_node_ready "$node_ip" "$node_name"; then
        echo -e "${RED}✗ $node_name failed to become ready${NC}"
        exit 1
    fi

    # Bootstrap etcd only on the first node
    if [ "$is_first_node" == "true" ]; then
        echo -e "${BLUE}Bootstrapping etcd on first node...${NC}"

        # Wait a bit more for the API server to be fully ready
        echo -e "${YELLOW}Waiting for API server to be ready...${NC}"
        sleep 30

        local bootstrap_attempts=10
        local bootstrap_attempt=0

        while [ $bootstrap_attempt -lt $bootstrap_attempts ]; do
            if talosctl bootstrap --talosconfig talosconfig --nodes "$node_ip" --endpoints "$node_ip"; then
                echo -e "${GREEN}✓ Bootstrapped etcd on $node_name${NC}"
                break
            fi

            echo -e "${YELLOW}Bootstrap attempt $((bootstrap_attempt + 1))/$bootstrap_attempts failed, retrying...${NC}"
            sleep 15
            bootstrap_attempt=$((bootstrap_attempt + 1))
        done

        if [ $bootstrap_attempt -eq $bootstrap_attempts ]; then
            echo -e "${RED}✗ Failed to bootstrap etcd on $node_name after $bootstrap_attempts attempts${NC}"
            exit 1
        fi

        # Wait for etcd to be ready
        echo -e "${YELLOW}Waiting for etcd to be ready...${NC}"
        sleep 60
    fi

    echo ""
}

# Function to wait for cluster to be ready
wait_for_cluster() {
    echo -e "${BLUE}Waiting for cluster to be ready...${NC}"

    # Wait for all nodes to be ready
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if talosctl kubeconfig kubeconfig --talosconfig talosconfig --nodes "${NODES[0]}" --endpoints "${NODES[0]}" 2>/dev/null; then
            echo -e "${GREEN}✓ Kubeconfig retrieved${NC}"
            break
        fi

        echo -e "${YELLOW}Attempt $((attempt + 1))/$max_attempts - waiting for cluster...${NC}"
        sleep 10
        attempt=$((attempt + 1))
    done

    if [ $attempt -eq $max_attempts ]; then
        echo -e "${RED}✗ Timeout waiting for cluster to be ready${NC}"
        exit 1
    fi
}

# Function to export kubeconfig
export_kubeconfig() {
    echo -e "${BLUE}Exporting kubeconfig...${NC}"

    if [ -f "kubeconfig" ]; then
        export KUBECONFIG="$PWD/kubeconfig"
        echo -e "${GREEN}✓ KUBECONFIG exported to: $KUBECONFIG${NC}"

        # Verify cluster connection
        echo -e "${BLUE}Testing cluster connection...${NC}"
        local max_attempts=10
        local attempt=0

        while [ $attempt -lt $max_attempts ]; do
            if kubectl get nodes &> /dev/null; then
                echo -e "${GREEN}✓ Successfully connected to cluster${NC}"
                echo ""
                echo -e "${BLUE}Cluster nodes:${NC}"
                kubectl get nodes -o wide
                return 0
            fi

            echo -e "${YELLOW}Attempt $((attempt + 1))/$max_attempts - waiting for cluster API...${NC}"
            sleep 10
            attempt=$((attempt + 1))
        done

        echo -e "${YELLOW}⚠ Cluster connection test failed (nodes may still be initializing)${NC}"
    else
        echo -e "${RED}✗ kubeconfig file not found${NC}"
        exit 1
    fi

    echo ""
}

# Function to display final instructions
show_final_instructions() {
    echo -e "${GREEN}=== Bootstrap Complete! ===${NC}"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo "1. Export the kubeconfig in your shell:"
    echo -e "   ${YELLOW}export KUBECONFIG=$PWD/kubeconfig${NC}"
    echo ""
    echo "2. Wait for all nodes to be ready (may show as NotReady until CozyStack CNI is installed):"
    echo -e "   ${YELLOW}kubectl get nodes -w${NC}"
    echo ""
    echo "3. Continue with CozyStack installation:"
    echo -e "   ${YELLOW}Follow the CozyStack documentation from the 'Install Cozystack' section${NC}"
    echo ""
    echo "4. You can also check Talos node status with:"
    echo -e "   ${YELLOW}talosctl --talosconfig talosconfig --nodes ${NODES[0]} health${NC}"
    echo ""
    echo -e "${BLUE}Cluster Information:${NC}"
    echo -e "Control Plane Nodes: ${NODES[*]}"
    echo -e "DNS Domain: cozy.local"
    echo -e "Pod Subnet: 10.244.0.0/16"
    echo -e "Service Subnet: 10.96.0.0/16"
    echo ""
    echo -e "${BLUE}Important Files:${NC}"
    echo -e "- talosconfig: Talos configuration for cluster management"
    echo -e "- kubeconfig: Kubernetes configuration for kubectl"
    echo -e "- controlplane.yaml: Node configuration (keep safe for future nodes)"
}

# Main execution
main() {
    # Check if we're in the right directory
    if [ ! -f "patch-controlplane.yaml" ]; then
        echo -e "${RED}Error: patch-controlplane.yaml not found in current directory${NC}"
        echo -e "${YELLOW}Please run this script from your cluster configuration directory${NC}"
        exit 1
    fi

    # Run all verification steps
    verify_dependencies
    verify_patch_files
    verify_connectivity

    # Confirm before proceeding
    echo -e "${YELLOW}Ready to bootstrap cluster with nodes: ${NODES[*]}${NC}"
    read -p "Continue with cluster bootstrap? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting..."
        exit 0
    fi
    echo ""

    # Generate cluster configuration (PKI, certificates, tokens) - only once
    generate_cluster_config

    # Install Talos on each node using the same configuration
    install_talos_node "${NODES[0]}" "Node 1 (Control Plane)" "true"
    install_talos_node "${NODES[1]}" "Node 2 (Control Plane)" "false"
    install_talos_node "${NODES[2]}" "Node 3 (Control Plane)" "false"

    # Wait for cluster to be ready and get kubeconfig
    wait_for_cluster

    # Export kubeconfig and test connection
    export_kubeconfig

    # Show final instructions
    show_final_instructions
}

# Run main function
main "$@"
