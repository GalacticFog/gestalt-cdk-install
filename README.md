# Installer for Canonical Kubernetes + Gestalt Platform + Ceph Storage

## Overview

Command-line installer for Canonical's distribution of Kubernetes (CDK) with Gestalt Platform.  This installer runs on Ubuntu and configures the Kubernetes cluster with Ceph for persistent volume support.  The installer deploys Kubernetes and Ceph by orchestrating Canonical's `juju` deployment tool, and deploys Gestalt by deploying an installer Pod to the Kubernetes cluster.  If the target provider is AWS, the installer also creates ELBs with SSL for Gestalt services and updates Route53 DNS.  The installation typically takes 15-30 minutes (or more).

## Requirements
* A target cloud environment supported by JuJu (public or private)
* The installer must be run from Ubuntu >= 16.04
* `juju` and `kubectl` must be installed

### AWS-Specific Requirements
* Route53 domain configured
* SSL certificate created for the domain (required for ELB SSL configuration)
* 'aws' command line utility installed, configured with AWS key and secret

## Install and Configure Dependencies

Perform the following from an Ubuntu instance.

### 1 - Clone the Installer Repository
Get the installer using `git clone`:

```sh
git clone https://github.com/GalacticFog/gestalt-cdk-install.git
```

### 2 - Install JuJu

```sh
sudo snap install juju --classic
```

### 3 - Install kubectl

```sh
curl -LO https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl
chmod +x ./kubectl
sudo mv ./kubectl /usr/local/bin/kubectl
```

### 4 - Install AWS CLI (Amazon Web Services only)

For Amazon Web Services, install the AWS CLI:
```sh
sudo apt install python-pip
sudo apt install virtualenv
pip install --upgrade --user awscli
complete -C aws_completer aws

# Verify installation
aws --version
aws <press tab to see command completion>
```

And configure credentials by running `aws configure` following the example:

```
$ aws configure
AWS Access Key ID []: **************************
AWS Secret Access Key []: *************************
Default region name [None]:
Default output format [None]:
```


## Executing the Deployment

### 1 - Deploy a JuJu Controller

Deploy the controller in desired cloud/region.  Run `juju bootstrap` following the example:

```sh
# juju bootstratp aws/<region> <controller name>
juju bootstrap aws/us-east-1 my-aws-us-east-1-controller --config bootstrap-timeout=1200
```

Note: You may also use an existing controller if you have one already - list controllers by running `juju controllers`.

### 2 - Configure the Installer

Modify `deploy-config.rc`. Set `JUJU_CONTROLLER` to the name of the JuJu controller (e.g. 'my-aws-us-east-2-controller'), and `TARGET_CLOUD` and `TARGET_REGION` to the desired target location (must match the location of the Juju controller).

For other configuration options, including AWS-specific settings, see *Configuration* section below.


### 3 - Run the Installer

```sh
cd gestalt-cdk-install

./install-cdk-with-gestalt.sh
```

## Configuration
Configuration parameters must be defined in `deploy-config.rc`.

### General Configuration
#### JuJu settings
* `JUJU_CONTROLLER` - Name of the JuJu controller to use. Run `juju controllers` for a list of controllers.
* `JUJU_MODEL` - Name of the target model to create (e.g. 'my-cdk-with-gestalt').  A model with this name should not already be present in the juju controller.
* `TARGET_CLOUD` - As supported by JuJu, e.g. `aws`. For a list, run `juju clouds`.
* `TARGET_REGION` - The target region associated with `TARGET_CLOUD`. For a list, run `juju regions <cloud>`

#### Ceph settings
* `CEPH_VOLUME_SIZE_MB` - Size of Ceph volumes to create (these show in Kubernetes as PVs)
* `CEPH_NUM_VOLUMES` - Number of Ceph volumes to create

#### JuJu bundles
* `KUBERNETES_BUNDLE` - The JuJu bundle to use for Kubernetes (e.g. `cs:bundle/canonical-kubernetes`, can be obtained from https://jujucharms.com/canonical-kubernetes)
* `CEPH_MON_BUNDLE` - The JuJu bundle to use for Ceph Monitor (typically no need to change).
* `CEPH_OSD_BUNDLE` - The JuJu bundle to use for Ceph OSD (typically no need to change).

### AWS-Specific configuration
These parameters apply if `TARGET_CLOUD` is set to `aws`.

#### DNS settings
* `AWS_DNS_DOMAIN` - The target domain hosting Gestalt services
* `AWS_DNS_HOSTED_ZONE_ID` - Route53 hosted zone ID

#### ELB settings
* `AWS_LB_CERT_ARN` - ARN of SSL certificate corresponding to AWS_DNS_DOMAIN.  
* `AWS_LB_ZONES` - List of Availability zones for ELBs.  These must correspond to TARGET_DOMAIN

#### Resource names
* `AWS_GESTALT_UI_LB_NAME` - AWS resource name to use when creating the Gestalt UI load balancer.
* `AWS_GESTALT_UI_DNS_NAME` - DNS name to use for Gestalt UI.
* `AWS_GESTALT_KONG_LB_NAME` - AWS resource name to use when creating the Kong load balancer.
* `AWS_GESTALT_KONG_DNS_NAME` - DNS name to use for Kong service.

## What the Installer Does

1. Checks for pre-requisite tools (juju, kubectl) and environment variables
- Creates a new JuJu model for the deployment and deploys Canonical Kubernetes in its default configuration (juju)
- Deploys a Ceph cluster and attaches it to the Kubernetes cluster for persistent volume support (juju)
- Creates several Ceph volumes, which are presented as Kuberntes PVs (juju)
- Initiates the deployment of Gestalt Platform (kubectl) to the cluster (which runs the helm-based installer)

### AWS-Specific Steps
- Creates ELBs for Gestalt-UI and Kong services using SSL.
- Creates Route53 DNS entries for Gestalt UI and Kong services.

## Example Run of the Installer

```

$ ./install-cdk-with-gestalt.sh
All required environment variables found.
Checking for required tools...
OK - Required tool 'juju' found.
OK - Required tool 'kubectl' found.
OK - Required tool 'sed' found.
OK - Required tool 'grep' found.
OK - Required tool 'awk' found.
Sourcing './functions-aws.sh'
All required environment variables found.
All required environment variables found.
Checking for required tools...
OK - Required tool 'aws' found.
Checking for existing ELB named 'gestalt-cdk-ui'...
OK - No ELB with name 'gestalt-cdk-ui' exists.
Checking for existing ELB named 'gestalt-cdk-apis'...
OK - No ELB with name 'gestalt-cdk-apis' exists.

This script will install Canonical Kubernetes with Gestalt Platform and Ceph for persistent volumes.  The following settings will be used:
  Target Cloud: aws
  Target Region: us-east-2
  Juju controller:    my-aws-us-east-2-controller, model: my-kube-ceph-gestalt-deployment
  Ceph volumes:       10 volumes, 1280 MB each.
  Kubernetes bundle:  cs:bundle/canonical-kubernetes

The following AWS resources will be created:
Route53 DNS Records:
  gestalt-ui.cdk-test.galacticfog.com
  gestalt-apis.cdk-test.galacticfog.com
Elastic Load Balancers:
  gestalt-cdk-ui
  gestalt-cdk-apis

 Proceed? [y/n]: y
[Running 'init_model']
Initializing juju model...
  Running command: juju add-model my-kube-ceph-gestalt-deployment aws/us-east-2 -c my-aws-us-east-2-controller
Added 'my-kube-ceph-gestalt-deployment' model on aws/us-east-2 with credential 'default' for user 'admin'
['init_model' finished in 2 seconds]

[Running 'deploy_ceph']
Deploying Ceph cluster...
Located charm "cs:ceph-mon-9".
Deploying charm "cs:ceph-mon-9".
Located charm "cs:ceph-osd-241".
Deploying charm "cs:ceph-osd-241".
Waiting for application 'ceph-osd' to block or become available...
'ceph-osd' status is 'waiting', waiting 30 seconds...
'ceph-osd' status is 'waiting', waiting 30 seconds...
'ceph-osd' status is 'waiting', waiting 30 seconds...
'ceph-osd' status is 'waiting', waiting 30 seconds...
'ceph-osd' status is 'maintenance', waiting 30 seconds...
'ceph-osd' status became 'blocked'.
Name     Provider  Attrs
ebs      ebs       
ebs-ssd  ebs       volume-type=ssd
loop     loop      
rootfs   rootfs    
tmpfs    tmpfs     

added "osd-devices"
added "osd-devices"
added "osd-devices"
Waiting for juju model 'my-kube-ceph-gestalt-deployment' to deploy and converge.  This may take a few minutes or more.  You may run 'juju status' in another console to monitor the status of the juju deployment.
INFO:root:All units idle since 2017-05-17 22:42:22.047737Z (ceph-mon/0, ceph-mon/1, ceph-mon/2, ceph-osd/0, ceph-osd/1, ceph-osd/2)
['deploy_ceph' finished in 258 seconds]

[Running 'deploy_kubernetes']
Deploying Kubernetes cluster...
Located bundle "cs:bundle/canonical-kubernetes-38"
Deploying charm "cs:~containers/easyrsa-9"
added resource easyrsa
Deploying charm "cs:~containers/etcd-34"
added resource etcd
added resource snapshot
Deploying charm "cs:~containers/flannel-15"
added resource flannel
Deploying charm "cs:~containers/kubeapi-load-balancer-11"
application kubeapi-load-balancer exposed
Deploying charm "cs:~containers/kubernetes-master-19"
added resource kube-controller-manager
added resource kube-scheduler
added resource kubectl
added resource cdk-addons
added resource kube-apiserver
Deploying charm "cs:~containers/kubernetes-worker-23"
added resource kubelet
added resource cni
added resource kube-proxy
added resource kubectl
application kubernetes-worker exposed
Related "kubernetes-master:kube-api-endpoint" and "kubeapi-load-balancer:apiserver"
Related "kubernetes-master:loadbalancer" and "kubeapi-load-balancer:loadbalancer"
Related "kubernetes-master:kube-control" and "kubernetes-worker:kube-control"
Related "kubernetes-master:certificates" and "easyrsa:client"
Related "etcd:certificates" and "easyrsa:client"
Related "kubernetes-master:etcd" and "etcd:db"
Related "kubernetes-worker:certificates" and "easyrsa:client"
Related "kubernetes-worker:kube-api-endpoint" and "kubeapi-load-balancer:website"
Related "kubeapi-load-balancer:certificates" and "easyrsa:client"
Related "flannel:etcd" and "etcd:db"
Related "flannel:cni" and "kubernetes-master:cni"
Related "flannel:cni" and "kubernetes-worker:cni"
Deploy of bundle completed.
Waiting for juju model 'my-kube-ceph-gestalt-deployment' to deploy and converge.  This may take 15 minutes or more.  You may run 'juju status' in another console to monitor the status of the juju deployment.
INFO:root:All units idle since 2017-05-17 22:49:08.979713Z (ceph-mon/0, ceph-mon/1, ceph-mon/2, ceph-osd/0, ceph-osd/1, ceph-osd/2, easyrsa/0, etcd/0, etcd/1, etcd/2, kubeapi-load-balancer/0, kubernetes-master/0, kubernetes-worker/0, kubernetes-worker/1, kubernetes-worker/2)
['deploy_kubernetes' finished in 411 seconds]

[Running 'connect_ceph_and_kube']
Waiting for juju model 'my-kube-ceph-gestalt-deployment' to deploy and converge.    You may run 'juju status' in another console to monitor the status of the juju deployment.
INFO:root:All units idle since 2017-05-17 22:50:10.577530Z (ceph-mon/0, ceph-mon/1, ceph-mon/2, ceph-osd/0, ceph-osd/1, ceph-osd/2, easyrsa/0, etcd/0, etcd/1, etcd/2, kubeapi-load-balancer/0, kubernetes-master/0, kubernetes-worker/0, kubernetes-worker/1, kubernetes-worker/2)
['connect_ceph_and_kube' finished in 59 seconds]

[Running 'add_ceph_volumes']
Adding 10 volumes of size 1280 MB...
Action queued with id: aa0122d3-2e6c-4a13-8223-0a97bf9913e2
Action queued with id: bfe24d80-7464-495a-8816-9ae3ae503535
Action queued with id: 94284dd0-abbb-49ac-8462-761caf25b960
Action queued with id: 536f5fbc-0b8d-42c0-8fbc-298ee367278b
Action queued with id: f9b6f104-0751-4e44-8391-d69242efa334
Action queued with id: 3d8ddb2f-cdba-4c8d-8071-c31e2219e97c
Action queued with id: f97e9cea-7e78-4e41-8082-d0bd496342a7
Action queued with id: 558370a3-d3b0-4bb0-8d01-af717ff842b6
Action queued with id: 7702a8f4-a3cd-4972-88af-e81f9ceb05c4
Action queued with id: bcf260d7-9dd7-4ae8-8ae8-6eb32863e992
['add_ceph_volumes' finished in 8 seconds]

[Running 'get_kubeconfig']
Fetching kubeconfig from Kubernetes cluster...
Configuration saved to ./kubeconfig-juju.
['get_kubeconfig' finished in 3 seconds]

[Running 'check_kube_cluster']
Kubernetes master is running at https://52.15.196.97:443
Heapster is running at https://52.15.196.97:443/api/v1/proxy/namespaces/kube-system/services/heapster
KubeDNS is running at https://52.15.196.97:443/api/v1/proxy/namespaces/kube-system/services/kube-dns
kubernetes-dashboard is running at https://52.15.196.97:443/api/v1/proxy/namespaces/kube-system/services/kubernetes-dashboard
Grafana is running at https://52.15.196.97:443/api/v1/proxy/namespaces/kube-system/services/monitoring-grafana
InfluxDB is running at https://52.15.196.97:443/api/v1/proxy/namespaces/kube-system/services/monitoring-influxdb

To further debug and diagnose cluster problems, use 'kubectl cluster-info dump'.
['check_kube_cluster' finished in 4 seconds]

[Running 'aws_predeploy']
Target cloud is AWS. Deploying ELBs for external access.
[Running 'create_elb gestalt-cdk-ui']
ELB gestalt-cdk-ui (gestalt-cdk-ui-342290058.us-east-2.elb.amazonaws.com) created.
['create_elb gestalt-cdk-ui' finished in 2 seconds]

[Running 'register_kube_workers_with_elb gestalt-cdk-ui']
Kubernetes workers found: i-0a3a866a58f2671ca i-09b28c26405ccd9e6 i-0daea4eaa9af17d42
Registered instances with 'gestalt-cdk-ui': i-0a3a866a58f2671ca i-09b28c26405ccd9e6 i-0daea4eaa9af17d42
['register_kube_workers_with_elb gestalt-cdk-ui' finished in 2 seconds]

[Running 'create_route53_dns_record gestalt-ui gestalt-cdk-ui-342290058.us-east-2.elb.amazonaws.com']
Creating Route53 DNS record: gestalt-ui.cdk-test.galacticfog.com --> gestalt-cdk-ui-342290058.us-east-2.elb.amazonaws.com
['create_route53_dns_record gestalt-ui gestalt-cdk-ui-342290058.us-east-2.elb.amazonaws.com' finished in 1 seconds]

[Running 'create_elb gestalt-cdk-apis']
ELB gestalt-cdk-apis (gestalt-cdk-apis-1665502132.us-east-2.elb.amazonaws.com) created.
['create_elb gestalt-cdk-apis' finished in 2 seconds]

[Running 'register_kube_workers_with_elb gestalt-cdk-apis']
Kubernetes workers found: i-0a3a866a58f2671ca i-09b28c26405ccd9e6 i-0daea4eaa9af17d42
Registered instances with 'gestalt-cdk-apis': i-0a3a866a58f2671ca i-09b28c26405ccd9e6 i-0daea4eaa9af17d42
['register_kube_workers_with_elb gestalt-cdk-apis' finished in 2 seconds]

[Running 'create_route53_dns_record gestalt-apis gestalt-cdk-apis-1665502132.us-east-2.elb.amazonaws.com']
Creating Route53 DNS record: gestalt-apis.cdk-test.galacticfog.com --> gestalt-cdk-apis-1665502132.us-east-2.elb.amazonaws.com
['create_route53_dns_record gestalt-apis gestalt-cdk-apis-1665502132.us-east-2.elb.amazonaws.com' finished in 1 seconds]

AWS Resources created in us-east-2
 DNS Records:
  - gestalt-ui.cdk-test.galacticfog.com
  - gestalt-apis.cdk-test.galacticfog.com
 ELBs:
  - gestalt-cdk-ui (gestalt-cdk-ui-342290058.us-east-2.elb.amazonaws.com)
  - gestalt-cdk-apis (gestalt-cdk-apis-1665502132.us-east-2.elb.amazonaws.com)

['aws_predeploy' finished in 1 seconds]

[Running 'deploy_gestalt']
All required environment variables found.
Iniating deployment of Gestalt Platform...
Running command: kubectl --kubeconfig=./kubeconfig-juju create -f gestalt-cdk-install.yaml
pod "gestalt-cdk-install" created
Deployed pod 'gestalt-cdk-install' using image 'galacticfog/gestalt-cdk-install:kube-1.1.0'.
['deploy_gestalt' finished in 1 seconds]

[Running 'aws_postdeploy']
[Running 'wait_for_service gestalt-ui']
Waiting for services to start...
Service 'gestalt-ui' not found yet, waiting 30 seconds... (attempt 1 of 100)
Service 'gestalt-ui' not found yet, waiting 30 seconds... (attempt 2 of 100)
Found service 'gestalt-ui'.
['wait_for_service gestalt-ui' finished in 62 seconds]

[Running 'get_service_nodeport gestalt-ui http']
Querying for Service 'gestalt-ui' NodePort named 'http'...
Service 'gestalt-ui' NodePort found: 30677
Done.
['get_service_nodeport gestalt-ui http' finished in 1 seconds]

[Running 'modify_elb_listeners_port gestalt-cdk-ui 30677']
Deleting existing load balancer 'gestalt-cdk-ui' listener for port 443.
Creating load balancer 'gestalt-cdk-ui' listener for port 443.
Done modifying ELB 'gestalt-cdk-ui' for port 30677.
['modify_elb_listeners_port gestalt-cdk-ui 30677' finished in 2 seconds]

[Running 'modify_juju_security_group_for_elb gestalt-cdk-ui 30677']
Security group for ELB 'gestalt-cdk-ui' modified for port 30677.
['modify_juju_security_group_for_elb gestalt-cdk-ui 30677' finished in 5 seconds]

[Running 'wait_for_service default-kong']
Waiting for services to start...
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 1 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 2 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 3 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 4 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 5 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 6 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 7 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 8 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 9 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 10 of 100)
Service 'default-kong' not found yet, waiting 30 seconds... (attempt 11 of 100)
Found service 'default-kong'.
['wait_for_service default-kong' finished in 349 seconds]

[Running 'get_service_nodeport default-kong public-url']
Querying for Service 'default-kong' NodePort named 'public-url'...
Service 'default-kong' NodePort found: 32687
Done.
['get_service_nodeport default-kong public-url' finished in 4 seconds]

[Running 'modify_elb_listeners_port gestalt-cdk-apis 32687']
Deleting existing load balancer 'gestalt-cdk-apis' listener for port 443.
Creating load balancer 'gestalt-cdk-apis' listener for port 443.
Done modifying ELB 'gestalt-cdk-apis' for port 32687.
['modify_elb_listeners_port gestalt-cdk-apis 32687' finished in 182 seconds]

[Running 'modify_juju_security_group_for_elb gestalt-cdk-apis 32687']
Security group for ELB 'gestalt-cdk-apis' modified for port 32687.
['modify_juju_security_group_for_elb gestalt-cdk-apis 32687' finished in 10 seconds]

['aws_postdeploy' finished in 10 seconds]

Deployment completed.

Kubernetes master is accessible at:
  https://52.15.196.97:443/ui

Run the following command to view Gestalt Platform install status:
  kubectl --kubeconfig=./kubeconfig-juju logs gestalt-deployer --namespace gestalt-system

Gestalt platform is accessible at:
  https://gestalt-ui.cdk-test.galacticfog.com:443/
```
