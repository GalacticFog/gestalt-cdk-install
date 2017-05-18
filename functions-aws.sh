AWS="aws --region $TARGET_REGION"
LB_PROTOCOL=HTTPS # HTTPS by default, no need to change
LB_PORT=443       # 443 by default, no need to change

# 'aws_*' functions are entrypoints called by main install script

aws_precheck() {
  check_for_required_environment_variables \
    AWS_DNS_HOSTED_ZONE_ID \
    AWS_DNS_DOMAIN \
    AWS_LB_ZONES \
    LB_PROTOCOL \
    LB_PORT \
    AWS_GESTALT_UI_LB_NAME \
    AWS_GESTALT_UI_DNS_NAME \
    AWS_GESTALT_KONG_LB_NAME \
    AWS_GESTALT_KONG_DNS_NAME

  if [ "${LB_PROTOCOL^^}" == "HTTPS" ]; then
    check_for_required_environment_variables \
      AWS_LB_CERT_ARN
  fi

  check_for_required_tools aws

  # Check for existing AWS resources that would conflict w/ deployment
  echo "Checking for existing ELBs..."
  check_for_existing_lb $AWS_GESTALT_UI_LB_NAME
  check_for_existing_lb $AWS_GESTALT_KONG_LB_NAME
}

aws_prompt() {
  echo "The following AWS resources will be created for ${cyn}$TARGET_REGION${end}"
  echo "Route53 DNS Records:"
  echo "  ${cyn}$AWS_GESTALT_UI_DNS_NAME.$AWS_DNS_DOMAIN${end}"
  echo "  ${cyn}$AWS_GESTALT_KONG_DNS_NAME.$AWS_DNS_DOMAIN${end}"
  echo "Elastic Load Balancers:"
  echo "  ${cyn}$AWS_GESTALT_UI_LB_NAME${end}"
  echo "  ${cyn}$AWS_GESTALT_KONG_LB_NAME${end}"
}

aws_predeploy() {
  echo_msg "Target cloud is AWS. Deploying ELBs for external access."

  # UI ELB and DNS record
  run create_elb $AWS_GESTALT_UI_LB_NAME
  run register_kube_workers_with_elb $AWS_GESTALT_UI_LB_NAME
  run create_route53_dns_record $AWS_GESTALT_UI_DNS_NAME $LB_DNSNAME
  GESTALT_UI_LB_DNSNAME=$LB_DNSNAME

  # Kong ELB and DNS record
  run create_elb $AWS_GESTALT_KONG_LB_NAME
  run register_kube_workers_with_elb $AWS_GESTALT_KONG_LB_NAME
  run create_route53_dns_record $AWS_GESTALT_KONG_DNS_NAME $LB_DNSNAME
  GESTALT_KONG_LB_DNSNAME=$LB_DNSNAME

  echo "AWS Resources created in $TARGET_REGION"
  echo " DNS Records:"
  echo "  - $AWS_GESTALT_UI_DNS_NAME.$AWS_DNS_DOMAIN"
  echo "  - $AWS_GESTALT_KONG_DNS_NAME.$AWS_DNS_DOMAIN"
  echo " ELBs:"
  echo "  - $AWS_GESTALT_UI_LB_NAME ($GESTALT_UI_LB_DNSNAME)"
  echo "  - $AWS_GESTALT_KONG_LB_NAME ($GESTALT_KONG_LB_DNSNAME)"
  echo

  # Set 'GESTALT_EXTERNAL_GATEWAY_{HOSTNAME,PROTOCOL}' variables for Gestalt deployment step
  GESTALT_EXTERNAL_GATEWAY_DNSNAME=$AWS_GESTALT_KONG_DNS_NAME.$AWS_DNS_DOMAIN
  GESTALT_EXTERNAL_GATEWAY_PROTOCOL=${LB_PROTOCOL,,}
}

aws_postdeploy() {
  # AWS-specific actions - set up ELBs for UI and Kong services

  # UI
  run wait_for_service "gestalt-ui"
  run get_service_nodeport "gestalt-ui" "http"
  run modify_elb_listeners_port $AWS_GESTALT_UI_LB_NAME $SERVICE_NODEPORT
  run modify_juju_security_group_for_elb $AWS_GESTALT_UI_LB_NAME $SERVICE_NODEPORT

  # Kong
  run wait_for_service "default-kong"
  run get_service_nodeport "default-kong" "public-url"
  run modify_elb_listeners_port $AWS_GESTALT_KONG_LB_NAME $SERVICE_NODEPORT
  run modify_juju_security_group_for_elb $AWS_GESTALT_KONG_LB_NAME $SERVICE_NODEPORT
}

aws_gestalt_access_info() {
  echo_info "${LB_PROTOCOL,,}://$AWS_GESTALT_UI_DNS_NAME.$AWS_DNS_DOMAIN:$LB_PORT/"
}

create_elb() {
  local lbname=$1

  if [ -z "$lbname" ]; then
    exit_with_error "Error creating ELB, no name specified, aborting."
  fi

  if [ "$LB_PROTOCOL" == "HTTPS" ]; then
    local suffix=",SSLCertificateId=$AWS_LB_CERT_ARN"
  elif [ "$LB_PROTOCOL" == "HTTP" ]; then
    local suffix=""
  else
    exit_with_error "Error creating ELB '$lbname' - did not understand LB_PROTOCOL = '$LB_PROTOCOL', aborting."
  fi

  local response=$(
    $AWS elb create-load-balancer --load-balancer-name $lbname \
    --listeners "Protocol=$LB_PROTOCOL,LoadBalancerPort=$LB_PORT,InstanceProtocol=HTTP,InstancePort=80${suffix}" \
    --availability-zones $AWS_LB_ZONES
  )

  exit_on_error "Error creating ELB '$lbname', aborting."

  # Output
  LB_DNSNAME=$( echo "$response" | jq -r '.DNSName' )

  echo "ELB $lbname ($LB_DNSNAME) created."
}

register_kube_workers_with_elb() {

  lbname=$1

  # Below is the old method (not using json output), keeping around just for reference
        # Get instances by scraping output from 'juju status' and 'juju machines'.  Note that juju -o json outputs
        # don't seem to work...
        #
        # machine_ids=$( juju show-status kubernetes-worker | grep 'kubernetes-worker/' | awk '{print $4}')
        # machine_list=$( juju machines )
        # instance_ids=$( for i in $machine_ids; do echo "$machine_list" | awk "(\$1)==$i" | awk '{print $4}'; done )

  juju_output=$( juju status kubernetes-worker --format json )

  exit_on_error "Error running juju status, aborting."

  # New method (using --format json)
  instance_ids=$( echo "$juju_output" | jq -r '.machines[]."instance-id"' )

  echo "Kubernetes workers found: `echo $instance_ids`"

  # Register instances w/ ELB
  response=$(
    $AWS elb register-instances-with-load-balancer --load-balancer-name $lbname --instances `echo $instance_ids`
  )
  exit_on_error "Error registering instances with ELB '$lbname', aborting."

  echo "Registered instances with '$lbname': `echo $instance_ids`"
}

modify_elb_listeners_port() {
  local lbname=$1
  local newport=$2

  if [ -z "$lbname" ]; then
    exit_with_error "Error modifying ELB, no name specified, aborting."
  fi
  if [ -z "$newport" ]; then
    exit_with_error "Error modifying ELB, no listener port specified, aborting."
  fi


  if [ "$LB_PROTOCOL" == "HTTPS" ]; then
    local suffix=",SSLCertificateId=$AWS_LB_CERT_ARN"
  elif [ "$LB_PROTOCOL" == "HTTP" ]; then
    local suffix=""
  else
    exit_with_error "Error creating ELB '$lbname' - did not understand LB_PROTOCOL = '$LB_PROTOCOL', aborting."
  fi

  echo "Deleting existing load balancer '$lbname' listener for port $LB_PORT."
  $AWS elb delete-load-balancer-listeners --load-balancer-name $lbname --load-balancer-ports $LB_PORT

  exit_on_error "Error deleting ELB '$lbname' listeners, aborting."

  echo "Creating load balancer '$lbname' listener for port $LB_PORT."

  # Re-create listeners
  $AWS elb create-load-balancer-listeners --load-balancer-name $lbname \
    --listeners "Protocol=$LB_PROTOCOL,LoadBalancerPort=$LB_PORT,InstanceProtocol=HTTP,InstancePort=${newport}${suffix}"

  exit_on_error "Error re-creating ELB '$lbname' listeners for port $port, aborting."

  echo "Done modifying ELB '$lbname' for port $newport."
}

get_instance_security_group() {
  aws ec2 describe-instances --query 'Reservations[*].Instances[*].SecurityGroups[*]' --output json --region us-east-2 --instance-ids i-0a67522e691cb7a23 | jq ' .[][][]'
}

modify_juju_security_group_for_elb() {

  lbname=$1
  port=$2

  elb_sg=`do_get_elb_security_group $lbname`
  exit_on_error "Error getting ELB security group, aborting."

  juju_sg=`do_get_juju_security_group`
  exit_on_error "Error getting juju security group, aborting."

  do_authorize_sg_ingress $juju_sg $elb_sg $port
  exit_on_error "Error authorizing security group ingress: $juju_sg, $elb_sg, $port. Aborting."

  echo "Security group for ELB '$lbname' modified for port $port."
}

check_for_existing_lb() {
  $AWS elb describe-load-balancers --load-balancer-name $1 >/dev/null 2>&1

  if [ $? -eq 0 ]; then
    exit_with_error "ELB '$1' already exists, please delete first. Aborting."
  fi
  echo "OK - No ELB with name '$1' exists."
}

do_authorize_sg_ingress() {

  target_sg=$1
  source_sg=$2
  port=$3

  $AWS ec2 authorize-security-group-ingress \
    --group-id $target_sg --source-group $source_sg \
    --protocol tcp --port $port
}

do_get_juju_security_group_name() {

  response=$( juju models --format json )
  [ $? -ne 0 ] && return 1

  uuid=$( echo "$response" | \
    jq -r ".models[] | select(.name == \"$JUJU_MODEL\") | .\"model-uuid\""
  )

  echo "juju-"$uuid
}

do_get_juju_security_group() {

  name=`do_get_juju_security_group_name`
  [ $? -ne 0 ] && return 1

  response=$(
    $AWS ec2 describe-security-groups  --group-names $name \
    --query 'SecurityGroups[*].GroupId'
  )
  [ $? -ne 0 ] && return 1

  sg=$( echo "$response" | jq -r '.[]' )

  echo $sg
}

do_get_elb_security_group() {
  lbname=$1

  if [ -z "$lbname" ]; then
    return 1
  fi

  response=$(
    $AWS elb describe-load-balancers --load-balancer-names $lbname
  )

  if [ $? -ne 0 ]; then
    return 1
  fi

  # Output
  group=$( echo "$response" | jq -r '.LoadBalancerDescriptions[].SecurityGroups[0]' )

  echo $group
}

create_route53_dns_record() {
  local name=$1.$AWS_DNS_DOMAIN
  local val=$2

  mkdir -p tmp
  cat > ./tmp/update-record.json <<EOF
  {
    "Comment": "Generated by CDK JuJu installer at `date`",
    "Changes": [
      {
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "$name",
          "Type": "CNAME",
          "TTL": 300,
          "ResourceRecords": [
            {
              "Value": "$val"
            }
          ]
        }
      }
    ]
  }
EOF
  exit_on_error "Unable to create ./tmp/update-record.json, aborting."

  echo "Creating Route53 DNS record: $name --> $val"

  aws route53 change-resource-record-sets --hosted-zone-id $AWS_DNS_HOSTED_ZONE_ID \
    --change-batch file://./tmp/update-record.json

  exit_on_error "Unable to create Route53 record, aborting."
}
