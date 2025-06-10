#!/bin/bash

# CozyStack Talos Bootstrap Script
# This script verifies dependencies and bootstraps a CozyStack cluster

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration file
NODES_CONFIG_FILE="nodes.conf"

# Arrays to hold node information
declare -a NODE_IPS
declare -a NODE_ROLES
declare -a NODE_NAMES

# Variables to hold cluster configuration from patch files
CLUSTER_DNS_DOMAIN=""
CLUSTER_POD_SUBNET=""
CLUSTER_SERVICE_SUBNET=""
CLUSTER_ENDPOINT=""

echo -e "${BLUE}=== CozyStack Talos Bootstrap Script ===${NC}"
echo ""

# Function to validate node name
validate_node_name() {
    local name=$1

    # Check if name is lowercase
    if [[ "$name" != "${name,,}" ]]; then
        return 1
    fi

    # Check if name starts with a number
    if [[ "$name" =~ ^[0-9] ]]; then
        return 1
    fi

    # Check if name contains spaces
    if [[ "$name" =~ [[:space:]] ]]; then
        return 1
    fi

    # Check if name contains only valid characters (lowercase letters, numbers, hyphens)
    if [[ ! "$name" =~ ^[a-z][a-z0-9-]*$ ]]; then
        return 1
    fi

    return 0
}

# Function to create nodes configuration file interactively
create_nodes_config() {
    echo -e "${BLUE}Creating $NODES_CONFIG_FILE...${NC}"

    # Create the file with header and examples
    cat > "$NODES_CONFIG_FILE" << 'EOF'
# Node configuration file for CozyStack Talos Bootstrap
# Format: IP_ADDRESS:ROLE:NAME
# ROLE can be 'controller' or 'worker'
# NAME must be lowercase, cannot start with a number, and cannot contain spaces
#
# Examples:
# 192.168.3.5:controller:control-1
# 192.168.3.6:controller:control-2
# 192.168.3.7:controller:control-3
# 192.168.3.8:worker:worker-1
# 192.168.3.9:worker:worker-2

EOF

    echo -e "${GREEN}✓${NC} Created $NODES_CONFIG_FILE with example format"
    echo ""

    read -p "Would you like to add node entries now? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Please edit $NODES_CONFIG_FILE manually and re-run the script${NC}"
        exit 0
    fi

    echo ""
    echo -e "${BLUE}Adding node entries...${NC}"
    echo -e "${YELLOW}Note: Node names must be lowercase, cannot start with numbers, and cannot contain spaces${NC}"
    echo ""

    while true; do
        echo -e "${BLUE}Enter node details:${NC}"

        # Get IP address
        while true; do
            read -p "Node IP address: " node_ip
            if [[ "$node_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                break
            else
                echo -e "${RED}Invalid IP address format. Please enter a valid IPv4 address.${NC}"
            fi
        done

        # Get role
        while true; do
            read -p "Node role (c/controller or w/worker): " node_role
            node_role="${node_role,,}"  # Convert to lowercase

            # Convert single letter shortcuts to full words
            case "$node_role" in
                "c")
                    node_role="controller"
                    echo -e "${BLUE}Using: controller${NC}"
                    ;;
                "w")
                    node_role="worker"
                    echo -e "${BLUE}Using: worker${NC}"
                    ;;
            esac

            if [[ "$node_role" == "controller" || "$node_role" == "worker" ]]; then
                break
            else
                echo -e "${RED}Invalid role. Please enter 'c' for controller, 'w' for worker, or the full word.${NC}"
            fi
        done

        # Get name
        while true; do
            read -p "Node name (no spaces, cannot start with number): " node_name

            # Check if name contains uppercase letters and convert
            if [[ "$node_name" != "${node_name,,}" ]]; then
                original_name="$node_name"
                node_name="${node_name,,}"
                echo -e "${BLUE}Converted '$original_name' to lowercase: '$node_name'${NC}"
            fi

            if validate_node_name "$node_name"; then
                break
            else
                echo -e "${RED}Invalid node name. Must be lowercase, cannot start with a number, cannot contain spaces, and can only contain letters, numbers, and hyphens.${NC}"
                echo -e "${YELLOW}Examples: control-1, worker-node, my-server${NC}"
            fi
        done

        # Add entry to file
        echo "$node_ip:$node_role:$node_name" >> "$NODES_CONFIG_FILE"
        echo -e "${GREEN}✓${NC} Added: $node_name ($node_ip) - $node_role"

        # Ask if they want to add another
        echo ""
        read -p "Would you like to add another node? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            break
        fi
        echo ""
    done

    echo ""
    echo -e "${GREEN}Node configuration complete!${NC}"
    echo -e "${BLUE}Review your configuration in $NODES_CONFIG_FILE:${NC}"
    echo ""
    grep -v "^#" "$NODES_CONFIG_FILE" | grep -v "^$"
    echo ""
}

# Function to load node configuration
load_node_config() {
    echo -e "${BLUE}Loading node configuration from $NODES_CONFIG_FILE...${NC}"

    if [ ! -f "$NODES_CONFIG_FILE" ]; then
        echo -e "${RED}✗${NC} Configuration file $NODES_CONFIG_FILE not found"
        echo ""
        read -p "Would you like to create the configuration file now? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            create_nodes_config
        else
            echo -e "${YELLOW}Please create $NODES_CONFIG_FILE manually and re-run the script${NC}"
            exit 1
        fi
    fi

    # Temporary arrays for sorting
    local temp_ips=()
    local temp_roles=()
    local temp_names=()

    local line_num=0
    while IFS= read -r line || [ -n "$line" ]; do
        line_num=$((line_num + 1))

        # Skip empty lines and comments
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # Parse line format: IP:ROLE:NAME
        if [[ "$line" =~ ^([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):([a-zA-Z]+):([a-zA-Z0-9-]+)$ ]]; then
            local ip="${BASH_REMATCH[1]}"
            local role="${BASH_REMATCH[2],,}"  # Convert to lowercase
            local name="${BASH_REMATCH[3],,}"  # Convert to lowercase

            # Validate role
            if [[ "$role" != "controller" && "$role" != "worker" ]]; then
                echo -e "${RED}✗${NC} Invalid role '$role' on line $line_num. Must be 'controller' or 'worker'"
                exit 1
            fi

            # Validate node name
            if ! validate_node_name "$name"; then
                echo -e "${RED}✗${NC} Invalid node name '$name' on line $line_num"
                echo -e "${YELLOW}Node names must be lowercase, cannot start with numbers, cannot contain spaces, and can only contain letters, numbers, and hyphens${NC}"
                exit 1
            fi

            temp_ips+=("$ip")
            temp_roles+=("$role")
            temp_names+=("$name")

        else
            echo -e "${RED}✗${NC} Invalid format on line $line_num: $line"
            echo -e "${YELLOW}Expected format: IP_ADDRESS:ROLE:NAME${NC}"
            exit 1
        fi
    done < "$NODES_CONFIG_FILE"

    if [ ${#temp_ips[@]} -eq 0 ]; then
        echo -e "${RED}✗${NC} No valid nodes found in $NODES_CONFIG_FILE"
        exit 1
    fi

    # Sort nodes: controllers first, then workers
    echo -e "${BLUE}Sorting nodes (controllers first, then workers)...${NC}"

    # Add controllers first
    for i in "${!temp_roles[@]}"; do
        if [[ "${temp_roles[$i]}" == "controller" ]]; then
            NODE_IPS+=("${temp_ips[$i]}")
            NODE_ROLES+=("${temp_roles[$i]}")
            NODE_NAMES+=("${temp_names[$i]}")
            echo -e "${GREEN}✓${NC} Loaded controller: ${temp_names[$i]} (${temp_ips[$i]})"
        fi
    done

    # Add workers second
    for i in "${!temp_roles[@]}"; do
        if [[ "${temp_roles[$i]}" == "worker" ]]; then
            NODE_IPS+=("${temp_ips[$i]}")
            NODE_ROLES+=("${temp_roles[$i]}")
            NODE_NAMES+=("${temp_names[$i]}")
            echo -e "${GREEN}✓${NC} Loaded worker: ${temp_names[$i]} (${temp_ips[$i]})"
        fi
    done

    echo -e "${GREEN}Loaded ${#NODE_IPS[@]} nodes from configuration (sorted by role)${NC}"
    echo ""
}

# Function to get first controller node IP
get_first_controller() {
    for i in "${!NODE_ROLES[@]}"; do
        if [[ "${NODE_ROLES[$i]}" == "controller" ]]; then
            echo "${NODE_IPS[$i]}"
            return 0
        fi
    done
    echo ""
}

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

# Function to extract cluster configuration from patch files
extract_cluster_config() {
    echo -e "${BLUE}Extracting cluster configuration from patch files...${NC}"
    
    # Set defaults
    CLUSTER_DNS_DOMAIN="cluster.local"
    CLUSTER_POD_SUBNET="10.244.0.0/16"
    CLUSTER_SERVICE_SUBNET="10.96.0.0/12"
    
    # Extract DNS domain from patch.yaml
    if [ -f "patch.yaml" ]; then
        local dns_domain
        dns_domain=$(grep -E "^\s*dnsDomain:" patch.yaml 2>/dev/null | sed 's/.*dnsDomain:\s*//' | tr -d '"' | head -1 || echo "")
        if [[ -n "$dns_domain" ]]; then
            CLUSTER_DNS_DOMAIN="$dns_domain"
        fi
        
        # Extract pod subnet
        local pod_subnet
        pod_subnet=$(grep -E "^\s*podSubnet:" patch.yaml 2>/dev/null | sed 's/.*podSubnet:\s*//' | tr -d '"' | head -1 || echo "")
        if [[ -n "$pod_subnet" ]]; then
            CLUSTER_POD_SUBNET="$pod_subnet"
        fi
        
        # Extract service subnet  
        local service_subnet
        service_subnet=$(grep -E "^\s*serviceSubnet:" patch.yaml 2>/dev/null | sed 's/.*serviceSubnet:\s*//' | tr -d '"' | head -1 || echo "")
        if [[ -n "$service_subnet" ]]; then
            CLUSTER_SERVICE_SUBNET="$service_subnet"
        fi
    fi
    
    # Set cluster endpoint to first controller
    CLUSTER_ENDPOINT=$(get_first_controller)
    if [[ -n "$CLUSTER_ENDPOINT" ]]; then
        CLUSTER_ENDPOINT="${CLUSTER_ENDPOINT}:6443"
    fi
    
    echo -e "${GREEN}✓${NC} DNS Domain: ${CLUSTER_DNS_DOMAIN}"
    echo -e "${GREEN}✓${NC} Pod Subnet: ${CLUSTER_POD_SUBNET}"  
    echo -e "${GREEN}✓${NC} Service Subnet: ${CLUSTER_SERVICE_SUBNET}"
    if [[ -n "$CLUSTER_ENDPOINT" ]]; then
        echo -e "${GREEN}✓${NC} Control Plane Endpoint: ${CLUSTER_ENDPOINT}"
    fi
    echo ""
}

# Function to verify patch files exist and extract configuration
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

    for ip in "${NODE_IPS[@]}"; do
        if ! check_node_connectivity "$ip"; then
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

    # Get first controller node
    local first_controller
    first_controller=$(get_first_controller)

    if [ -z "$first_controller" ]; then
        echo -e "${RED}✗${NC} No controller nodes found in configuration"
        exit 1
    fi

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
    # Generate config with the first controller node as the endpoint
    if talosctl gen config cozystack-cluster https://${first_controller}:6443 --config-patch @patch.yaml --config-patch-control-plane @patch-controlplane.yaml; then
        echo -e "${GREEN}✓ Generated cluster configuration${NC}"

        # Fix the talosconfig endpoints to include our first controller
        echo -e "${BLUE}Updating talosconfig endpoints...${NC}"
        # Create a temporary file with the endpoint fix
        cp talosconfig talosconfig.backup

        # Use yq or sed to update the endpoints (if yq is available, otherwise use sed)
        if command -v yq &> /dev/null; then
            yq eval ".contexts.cozystack-cluster.endpoints = [\"${first_controller}\"]" -i talosconfig
            echo -e "${GREEN}✓ Updated endpoints using yq${NC}"
        else
            # Fallback to sed - replace empty endpoints array
            sed -i "s/endpoints: \[\]/endpoints: \[\"${first_controller}\"\]/" talosconfig
            echo -e "${GREEN}✓ Updated endpoints using sed${NC}"
        fi

        echo -e "${BLUE}Talosconfig endpoints now set to: ${first_controller}${NC}"
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
    local node_role=$3
    local is_first_controller=$4

    echo -e "${BLUE}Installing Talos on $node_name ($node_ip) as $node_role...${NC}"

    # Choose the appropriate configuration file based on role
    local config_file
    if [[ "$node_role" == "controller" ]]; then
        config_file="controlplane.yaml"
    else
        config_file="worker.yaml"
    fi

    # Apply the configuration to the node
    if talosctl apply-config --insecure --file "$config_file" --talosconfig talosconfig --nodes "$node_ip" --endpoints "$node_ip"; then
        echo -e "${GREEN}✓ Applied $node_role configuration to $node_name${NC}"
    else
        echo -e "${RED}✗ Failed to apply configuration to $node_name${NC}"
        exit 1
    fi

    # Wait for the node to be ready
    if ! wait_for_node_ready "$node_ip" "$node_name"; then
        echo -e "${RED}✗ $node_name failed to become ready${NC}"
        exit 1
    fi

    # Bootstrap etcd only on the first controller node
    if [ "$is_first_controller" == "true" ]; then
        echo -e "${BLUE}Bootstrapping etcd on first controller node...${NC}"

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

    # Get first controller node
    local first_controller
    first_controller=$(get_first_controller)

    # Wait for all nodes to be ready
    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if talosctl kubeconfig kubeconfig --talosconfig talosconfig --nodes "$first_controller" --endpoints "$first_controller" 2>/dev/null; then
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

# Function to display cluster summary
show_cluster_summary() {
    echo -e "${BLUE}Cluster Configuration Summary:${NC}"
    echo "=============================="

    local controller_count=0
    local worker_count=0

    for i in "${!NODE_IPS[@]}"; do
        local role_display="${NODE_ROLES[$i]}"
        if [[ "${NODE_ROLES[$i]}" == "controller" ]]; then
            controller_count=$((controller_count + 1))
        else
            worker_count=$((worker_count + 1))
        fi

        echo -e "${NODE_NAMES[$i]}: ${NODE_IPS[$i]} (${role_display})"
    done

    echo ""
    echo -e "${BLUE}Total: ${#NODE_IPS[@]} nodes (${controller_count} controllers, ${worker_count} workers)${NC}"
    echo ""
}

# Function to execute post-bootstrap steps
execute_post_bootstrap_steps() {
    local first_controller
    first_controller=$(get_first_controller)
    
    echo -e "${BLUE}=== Post-Bootstrap Steps ===${NC}"
    echo ""
    
    # Step 1: Export kubeconfig
    read -p "Execute Step 1: Export kubeconfig to current shell? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Exporting KUBECONFIG...${NC}"
        export KUBECONFIG="$PWD/kubeconfig"
        echo -e "${GREEN}✓ KUBECONFIG exported to: $KUBECONFIG${NC}"
        echo -e "${YELLOW}Note: This only affects the current shell session${NC}"
    else
        echo -e "${YELLOW}Skipped: Remember to export KUBECONFIG manually${NC}"
    fi
    echo ""
    
    # Step 2: Check node status
    read -p "Execute Step 2: Check cluster node status? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Checking cluster nodes...${NC}"
        if command -v kubectl &> /dev/null && [[ -n "$KUBECONFIG" ]]; then
            kubectl get nodes -o wide || echo -e "${YELLOW}Note: Nodes may show as NotReady until CozyStack CNI is installed${NC}"
        else
            echo -e "${YELLOW}kubectl not available or KUBECONFIG not set${NC}"
        fi
    else
        echo -e "${YELLOW}Skipped: Check nodes manually with: kubectl get nodes -w${NC}"
    fi
    echo ""
    
    # Step 3: CozyStack installation prompt
    read -p "Execute Step 3: Open CozyStack documentation? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Opening CozyStack documentation...${NC}"
        if command -v xdg-open &> /dev/null; then
            xdg-open "https://cozystack.io/docs/installation/" 2>/dev/null &
            echo -e "${GREEN}✓ Opened documentation in browser${NC}"
        elif command -v open &> /dev/null; then
            open "https://cozystack.io/docs/installation/" 2>/dev/null &
            echo -e "${GREEN}✓ Opened documentation in browser${NC}"
        else
            echo -e "${YELLOW}Cannot auto-open browser. Please visit: https://cozystack.io/docs/installation/${NC}"
        fi
    else
        echo -e "${YELLOW}Skipped: Follow CozyStack documentation manually${NC}"
    fi
    echo ""
    
    # Step 4: Talos health check
    read -p "Execute Step 4: Check Talos cluster health? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Checking Talos cluster health...${NC}"
        if talosctl --talosconfig talosconfig --nodes "${first_controller}" health; then
            echo -e "${GREEN}✓ Talos cluster health check completed${NC}"
        else
            echo -e "${YELLOW}⚠ Health check completed with warnings (this may be normal during initial setup)${NC}"
        fi
    else
        echo -e "${YELLOW}Skipped: Check Talos health manually${NC}"
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
    local first_controller
    first_controller=$(get_first_controller)
    echo -e "   ${YELLOW}talosctl --talosconfig talosconfig --nodes ${first_controller} health${NC}"
    echo ""
    echo -e "${BLUE}Cluster Information:${NC}"
    echo -e "Control Plane Endpoint: ${CLUSTER_ENDPOINT}"
    echo -e "DNS Domain: ${CLUSTER_DNS_DOMAIN}"
    echo -e "Pod Subnet: ${CLUSTER_POD_SUBNET}"
    echo -e "Service Subnet: ${CLUSTER_SERVICE_SUBNET}"
    echo ""
    echo -e "${BLUE}Important Files:${NC}"
    echo -e "- talosconfig: Talos configuration for cluster management"
    echo -e "- kubeconfig: Kubernetes configuration for kubectl"
    echo -e "- controlplane.yaml: Controller node configuration"
    echo -e "- worker.yaml: Worker node configuration"
    echo -e "- $NODES_CONFIG_FILE: Node configuration file"
    echo ""
    
    # Ask if user wants to execute post-bootstrap steps
    read -p "Would you like to execute these next steps interactively? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        execute_post_bootstrap_steps
    else
        echo -e "${YELLOW}You can run these steps manually using the commands shown above.${NC}"
    fi
}

# Main execution
main() {
    # Run verification steps first (before loading node config)
    verify_dependencies
    verify_patch_files
    
    # Load node configuration
    load_node_config

    # Extract cluster configuration from patch files
    extract_cluster_config

    # Show cluster summary
    show_cluster_summary

    # Verify connectivity
    verify_connectivity

    # Confirm before proceeding
    echo -e "${YELLOW}Ready to bootstrap cluster with the above configuration${NC}"
    read -p "Continue with cluster bootstrap? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Aborting..."
        exit 0
    fi
    echo ""

    # Generate cluster configuration (PKI, certificates, tokens) - only once
    generate_cluster_config

    # Install Talos on each node
    local first_controller_processed=false
    for i in "${!NODE_IPS[@]}"; do
        local is_first_controller="false"

        # Check if this is the first controller node
        if [[ "${NODE_ROLES[$i]}" == "controller" && "$first_controller_processed" == "false" ]]; then
            is_first_controller="true"
            first_controller_processed=true
        fi

        install_talos_node "${NODE_IPS[$i]}" "${NODE_NAMES[$i]}" "${NODE_ROLES[$i]}" "$is_first_controller"
    done

    # Wait for cluster to be ready and get kubeconfig
    wait_for_cluster

    # Export kubeconfig and test connection
    export_kubeconfig

    # Show final instructions
    show_final_instructions
}

# Run main function
main "$@"
