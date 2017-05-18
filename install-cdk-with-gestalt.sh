#!/bin/bash
# Installer for Canonical Kubernetes + Galactic Fog Gestalt Platform + Ceph
# for Storage.

DIR=$(dirname $0)

. "$DIR/functions.sh"

# Installer must be run from the current directory (TODO)
if [ "$DIR" != "." ]; then
  exit_with_error "Installer must be run from the installer directory. Please switch into the '$DIR' directory and run the installer as './$(basename $0)'"
fi

# Load config file
CONFIG_FILE="$DIR/deploy-config.rc"
if [ ! -f "$CONFIG_FILE" ]; then
  exit_with_error "A deployment configuration file ($CONFIG_FILE) must be provided for the installer."
fi

echo "Sourcing configuration file $CONFIG_FILE."
. $CONFIG_FILE

check_for_required_environment_variables \
  JUJU_CONTROLLER \
  JUJU_MODEL \
  TARGET_CLOUD \
  TARGET_REGION \
  CEPH_NUM_VOLUMES \
  CEPH_VOLUME_SIZE_MB \
  KUBERNETES_BUNDLE \
  CEPH_MON_BUNDLE \
  CEPH_OSD_BUNDLE

check_for_required_tools \
  juju kubectl sed grep awk

# Load cloud-specific functions
file="$DIR/functions-${TARGET_CLOUD}.sh"
if [ -f "$file" ]; then
  echo "Sourcing '$file'"
  . $file
else
  echo_warn "File '$file' not found."
fi

${TARGET_CLOUD}_precheck  # Run precheck

echo ""
echo "This script will install Canonical Kubernetes with Gestalt Platform and Ceph for persistent volumes."
echo "The following settings will be used:"
echo "  Target Cloud: ${cyn}$TARGET_CLOUD${end}"
echo "  Target Region: ${cyn}$TARGET_REGION${end}"
echo "  JuJu controller: ${cyn}$JUJU_CONTROLLER${end}"
echo "  JuJu model: ${cyn}$JUJU_MODEL${end}"
echo "  Ceph volumes: ${cyn}$CEPH_NUM_VOLUMES volumes, $CEPH_VOLUME_SIZE_MB MB each${end}"
echo "  Kubernetes bundle: ${cyn}$KUBERNETES_BUNDLE${end}"
echo ""

${TARGET_CLOUD}_prompt

prompt_to_continue

### Phase 1 - deploy infrastructure: Ceph, Kubernetes ###

# Initialize
run init_model

# Deploy infrastructure
run deploy_ceph
run deploy_kubernetes
run connect_ceph_and_kube
run add_ceph_volumes

# Check Access
run get_kubeconfig
run check_kube_cluster

### Phase 2 - deploy Gestalt Paltform ###

run ${TARGET_CLOUD}_predeploy  # Cloud-specific pre-deploy steps
run deploy_gestalt            # Deploy Gestalt Platform
run ${TARGET_CLOUD}_postdeploy # Cloud-specific post-deploy steps

### Done, display access info
echo_ok   "Deployment completed."
echo_ok   ""
echo_ok   "Kubernetes master is accessible at:"
echo_info "  $KUBE_MASTER_URL/ui"
echo_ok   ""
echo_ok   "Run the following command to view Gestalt Platform install status:"
echo_info "  $KUBECTL logs gestalt-deployer --namespace gestalt-system"
echo_ok   ""
echo_ok   "Gestalt platform is accessible at:"

# Run cloud specific access information
echo "  `${TARGET_CLOUD}_gestalt_access_info`"

echo_ok   ""
