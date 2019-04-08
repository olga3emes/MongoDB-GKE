#!/bin/sh
##
# Script to remove/undepoy all project resources from GKE & GCE.
##

NUM_SHARDS=4

NUM_TOTAL=5 #num_shards + routers

# Delete mongos stateful set + mongod stateful set + mongodb service + secrets + host vm configurer daemonset
kubectl delete statefulsets mongos-router
kubectl delete services mongos-router-service
for (( i=1; i<=${NUM_SHARDS}; i++ ))
do
kubectl delete statefulsets mongod-shard${i}
kubectl delete services mongodb-shard${i}-service
done
kubectl delete statefulsets mongod-configdb
kubectl delete services mongodb-configdb-service
kubectl delete secret shared-bootstrap-data
kubectl delete daemonset hostvm-configurer
sleep 3

# Delete persistent volume claims
kubectl delete persistentvolumeclaims -l tier=maindb
kubectl delete persistentvolumeclaims -l tier=configdb
sleep 3

# Delete persistent volumes
for i in 1
do
    kubectl delete persistentvolumes data-volume-4g-$i
done
for (( i=1; i<=${NUM_TOTAL}; i++ ))
do
    kubectl delete persistentvolumes data-volume-8g-$i
done
sleep 20

# Delete GCE disks
for i in 1
do
    gcloud -q compute disks delete pd-ssd-disk-4g-$i
done
for (( i=1; i<=${NUM_TOTAL}; i++ ))
do
    gcloud -q compute disks delete pd-ssd-disk-8g-$i
done

# Delete whole Kubernetes cluster (including its VM instances)
gcloud -q container clusters delete "gke-mongodb-demo-cluster"

