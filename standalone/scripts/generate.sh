#!/bin/sh
##
# Script to deploy a Kubernetes project with a StatefulSet running a MongoDB Sharded Cluster, to GKE.
##

NEW_PASSWORD="abc123"


# Create new GKE Kubernetes cluster (using host node VM images based on Ubuntu
# rather than default ChromiumOS & also use slightly larger VMs than default)
echo "Creating GKE Cluster"
gcloud container clusters create "gke-mongodb-demo-cluster" --image-type=UBUNTU --machine-type=n1-standard-2

# Deploy each MongoDB Shard Service using a Kubernetes StatefulSet
echo "Deploying GKE MongoDB Pod - Standalone"
kubectl create -f ../resources/mongodb-standalone.yaml
sleep 45

# Configure host VM using daemonset to disable hugepages
echo "Deploying GKE Daemon Set"
kubectl apply -f ../resources/hostvm-node-configurer-daemonset.yaml


# Create the Admin User (this will automatically disable the localhost exception)
echo "Creating user: 'main_admin'"
kubectl exec mongo -- mongo --eval 'db.getSiblingDB("admin").createUser({user:"main_admin",pwd:"'"${NEW_PASSWORD}"'",roles:[{role:"root",db:"admin"}]});'
echo


# Print Summary State
kubectl get all 
echo

