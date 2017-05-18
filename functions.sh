
red=$'\e[1;31m'
grn=$'\e[1;32m'
yel=$'\e[1;33m'
blu=$'\e[1;34m'
mag=$'\e[1;35m'
cyn=$'\e[1;36m'
end=$'\e[0m'

exit_with_error() {
  printf "%s\n" "${red}[Error]${end} $@"
  exit 1
}

exit_on_error() {
  if [ $? -ne 0 ]; then
    exit_with_error "$@"
  fi
}

echo_ok() {
  printf "%s\n" "${grn}$@${end}"
}

echo_info() {
  printf "%s\n" "${cyn}$@${end}"
}

echo_msg() {
  msg="$@"
  printf "%s\n" "${blu}$msg${end}"
}

echo_err() {
  printf "%s\n" "${red}$@${end}"
}

echo_warn() {
  printf "%s\n" "${yel}$@${end}"
}

check_for_required_environment_variables() {
  retval=0

  for e in $@; do
    if [ -z "${!e}" ]; then
      echo "Required environment variable \"$e\" not defined."
      retval=1
    fi
  done

  if [ $retval -ne 0 ]; then
    echo_err "One or more required environment variables not defined, aborting."
    exit 1
  else
    echo "All required environment variables found."
  fi
}

check_for_required_tools() {
  echo "Checking for required tools..."

  for t in $@; do
    which $t >/dev/null 2>&1 ; exit_on_error "'$t' not found, aborting."
    echo "OK - Required tool '$t' found."
  done
}

prompt_to_continue() {
  while true; do
      read -p " Proceed? [y/n]: " yn
      case $yn in
          [Yy]*) return 0  ;;
          [Nn]*) echo_err "Aborted" ; exit  1 ;;
      esac
  done
}

init_model() {
  echo "Initializing juju model..."
  cmd="juju add-model $JUJU_MODEL $TARGET_CLOUD/$TARGET_REGION -c $JUJU_CONTROLLER"
  echo "  Running command: $cmd"
  $cmd
  exit_on_error "Unable to create model '$JUJU_MODEL', aborting."
}

deploy_kubernetes() {
  echo "Deploying Kubernetes cluster..."
  juju deploy $KUBERNETES_BUNDLE
  exit_on_error "Unable to deploy Kubernetes, aborting."

  do_wait_for_model "This may take 15 minutes or more."
}

deploy_ceph () {
  echo "Deploying Ceph cluster..."

  # Provision Ceph Cluster
  juju deploy $CEPH_MON_BUNDLE -n 3
  exit_on_error "Unable deploy ceph-mon, aborting."

  juju deploy $CEPH_OSD_BUNDLE -n 3
  exit_on_error "Unable to deploy ceph-osd, aborting."

  juju add-relation ceph-mon ceph-osd
  exit_on_error "Unable to relate ceph-mon to ceph-osd, aborting."

  do_wait_for_blocked_model ceph-osd

  juju storage-pools

  for i in `seq 0 2`; do
    juju add-storage ceph-osd/$i osd-devices=ebs,20G,1
    exit_on_error "Unable to add storage to ceph-osd/$i, aborting."
  done

  do_wait_for_model "This may take a few minutes or more."
}

do_wait_for_blocked_model() {
  svc=$1

  echo "Waiting for application '$svc' to block or become available..."

  for i in `seq 1 20`; do

    juju_output=$(
      juju status $svc --format json
    )

    status=$( echo "$juju_output" | jq -r '.applications[]."application-status".current' )

    if [ "$status" == "blocked" ] || [ "$status" == "active" ]; then
      echo "'$svc' status became '$status'."
      return 0
    fi
    secs=30
    echo "'$svc' status is '$status', waiting $secs seconds..."
    sleep $secs
  done

  echo_warn "Service '$svc' did not become active or blocked in the time expected."
  return 1
}

do_wait_for_model() {
  echo "Waiting for juju model '$JUJU_MODEL' to deploy and converge.  $1  You may run 'juju status' in another console to monitor the status of the juju deployment."
  juju wait -wm $JUJU_CONTROLLER:$JUJU_MODEL
  exit_on_error "Model did not deploy successfully, aborting."
}

connect_ceph_and_kube() {
  juju add-relation kubernetes-master ceph-mon
  exit_on_error "Unable to relate ceph-mon to kubernetes-master, aborting."

  do_wait_for_model
}

add_ceph_volumes () {
  echo "Adding $CEPH_NUM_VOLUMES volumes of size $CEPH_VOLUME_SIZE_MB MB..."

  for i in `seq 1 $CEPH_NUM_VOLUMES`; do
    juju run-action kubernetes-master/0 create-rbd-pv name=rbd-$i size=$CEPH_VOLUME_SIZE_MB
  done
}

get_kubeconfig() {
  echo "Fetching kubeconfig from Kubernetes cluster..."
  juju scp -m $JUJU_CONTROLLER:$JUJU_MODEL kubernetes-master/0:config $KUBECONFIG_FILE
  exit_on_error "Could not download kubernetes configuration, aborting."

  echo "Configuration saved to $KUBECONFIG_FILE."
}

check_kube_cluster() {
  KUBE_CLUSTER_INFO=$($KUBECTL cluster-info)
  echo "$KUBE_CLUSTER_INFO"

  KUBE_MASTER_URL=$(
    echo "$KUBE_CLUSTER_INFO" | sed "s,\x1B\[[0-9;]*[a-zA-Z],,g" | grep "^Kubernetes master" | awk '{print $6}'
  )

  exit_on_error "Error getting kubernetes cluster info, aborting."
}

deploy_gestalt() {

  local pod="gestalt-cdk-install"
  local gestalt_cdk_install_image="galacticfog/gestalt-cdk-install:kube-1.1.0"

  check_for_required_environment_variables \
    GESTALT_EXTERNAL_GATEWAY_DNSNAME \
    GESTALT_EXTERNAL_GATEWAY_PROTOCOL

  echo "Iniating deployment of Gestalt Platform..."
  # Get Kubeconfig data
  KUBECONFIG_DATA=`$KUBECTL config view --raw | base64 | tr -d '\n'`

  cat > gestalt-cdk-install.yaml <<EOF
# This is a pod w/ restartPolicy=Never so that the installer only runs once.
apiVersion: v1
kind: Pod
metadata:
  name: $pod
  labels:
    gestalt-app: cdk-install
spec:
  restartPolicy: Never
  containers:
  - name: $pod
    image: "$gestalt_cdk_install_image"
    imagePullPolicy: Always
    # 'deploy' arg signals deployment of gestalt platform
    args: ["deploy"]
    env:
    - name: CONTAINER_IMAGE_RELEASE_TAG
      value: kube-1.0.0
    - name: EXTERNAL_GATEWAY_DNSNAME
      value: "$GESTALT_EXTERNAL_GATEWAY_DNSNAME"
    - name: EXTERNAL_GATEWAY_PROTOCOL
      value: "$GESTALT_EXTERNAL_GATEWAY_PROTOCOL"
    - name: KUBECONFIG_DATA
      value: "$KUBECONFIG_DATA"
    - name: GESTALT_INSTALL_MODE
      value: "$GESTALT_INSTALL_MODE"
EOF

  # Invoke Installer
  cmd="$KUBECTL create -f gestalt-cdk-install.yaml"
  echo "Running command: $cmd"
  $cmd
  exit_on_error "Failed to deploy gestalt-cdk-install pod, aborting."

  echo "Deployed pod '$pod' using image '$gestalt_cdk_install_image'."
}


wait_for_service() {
  echo "Waiting for services to start..."

  local name=$1
  local tries=100

  for i in `seq 1 $tries`; do

    response=$(
      $KUBECTL get services --all-namespaces -ojson | \
        jq ".items[] | select(.metadata.name ==\"$name\")"
    )

    if [ -z "$response" ]; then
      secs=30
      echo "Service '$name' not found yet, waiting $secs seconds... (attempt $i of $tries)"
      sleep $secs
    else
      echo "Found service '$name'."
      return 0
    fi
  done
  exit_with_error "Service '$name' didn't start, aborting."
}

get_service_nodeport() {

  local svc=$1
  local portName=$2

  echo "Querying for Service '$svc' NodePort named '$portName'..."

  local svcdef=$( $KUBECTL get services --all-namespaces -ojson | \
    jq " .items[] | select(.metadata.name ==\"$svc\")" )

  [ -z "$svcdef" ] && exit_with_error "Service '$svc' not found, aborting."

  local nodeport=$(
    echo "$svcdef" | jq ".spec.ports[] | select(.name==\"$portName\" ) | .nodePort"
  )
  [ -z "$nodeport" ] && exit_with_error "Service '$svc' NodePort not found, aborting."

  echo "Service '$svc' NodePort found: $nodeport"

  SERVICE_NODEPORT=$nodeport

  echo "Done."
}

run() {
  SECONDS=0
  echo_msg "[Running '$@']"

  # Run function
  $@

  echo_msg "['$@' finished in $SECONDS seconds]"
  echo ""
}

KUBECONFIG_FILE="$(dirname $0)/kubeconfig-juju"
KUBECTL="kubectl --kubeconfig=$KUBECONFIG_FILE"
