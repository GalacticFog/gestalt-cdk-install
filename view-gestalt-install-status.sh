#!/bin/bash
kubectl --kubeconfig=./kubeconfig-juju logs gestalt-deployer --namespace gestalt-system
