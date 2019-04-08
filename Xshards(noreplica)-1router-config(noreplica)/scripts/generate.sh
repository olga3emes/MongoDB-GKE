#!/bin/sh
##
# Script to deploy a Kubernetes project with a StatefulSet running a MongoDB Sharded Cluster, to GKE.
##

NEW_PASSWORD="abc123"

NUM_SHARDS=4

NUM_TOTAL=5 #num_shards + router

# Create new GKE Kubernetes cluster (using host node VM images based on Ubuntu
# rather than default ChromiumOS & also use slightly larger VMs than default)
echo "Creating GKE Cluster"
gcloud container clusters create "gke-mongodb-demo-cluster" --image-type=UBUNTU --machine-type=n1-standard-2


# Configure host VM using daemonset to disable hugepages
echo "Deploying GKE Daemon Set"
kubectl apply -f ../resources/hostvm-node-configurer-daemonset.yaml

# Register GCE Fast SSD persistent disks and then create the persistent disks 
echo "Creating GCE disks"
for i in 1
do
    # 4GB disks    
    gcloud compute disks create --size 4GB --type pd-ssd pd-ssd-disk-4g-$i
done
for (( i=1; i<=$NUM_TOTAL; i++ ))
do
    # 8 GB disks
gcloud compute disks create --size 8GB --type pd-ssd pd-ssd-disk-8g-$i
done
sleep 3


# Create persistent volumes using disks that were created above
echo "Creating GKE Persistent Volumes"
for i in 1
do
    # Replace text stating volume number + size of disk (set to 4)
    sed -e "s/INST/"${i}"/g; s/SIZE/4/g" ../resources/xfs-gce-ssd-persistentvolume.yaml > /tmp/xfs-gce-ssd-persistentvolume.yaml
    kubectl apply -f /tmp/xfs-gce-ssd-persistentvolume.yaml
done
for (( i=1; i<=$NUM_TOTAL; i++ ))
do
    # Replace text stating volume number + size of disk (set to 8)
    sed -e "s/INST/"${i}"/g; s/SIZE/8/g" ../resources/xfs-gce-ssd-persistentvolume.yaml > /tmp/xfs-gce-ssd-persistentvolume.yaml
    kubectl apply -f /tmp/xfs-gce-ssd-persistentvolume.yaml
done
rm /tmp/xfs-gce-ssd-persistentvolume.yaml
sleep 3


# Create keyfile for the MongoDB cluster as a Kubernetes shared secret
TMPFILE=$(mktemp)
/usr/bin/openssl rand -base64 741 > $TMPFILE
kubectl create secret generic shared-bootstrap-data --from-file=internal-auth-mongodb-keyfile=$TMPFILE
rm $TMPFILE


# Deploy a MongoDB ConfigDB Service ("Config Server Replica Set") using a Kubernetes StatefulSet
echo "Deploying GKE StatefulSet & Service for MongoDB Config Server Replica Set"
kubectl apply -f ../resources/mongodb-configdb-service.yaml


# Deploy each MongoDB Shard Service using a Kubernetes StatefulSet
echo "Deploying GKE StatefulSet & Service for each MongoDB Shard Replica Set"

for (( i=1; i<=${NUM_SHARDS}; i++ ))
do
sed -e 's/shardX/shard'${i}'/g; s/ShardX/Shard'${i}'/g' ../resources/mongodb-maindb-service.yaml > /tmp/mongodb-maindb-service.yaml
kubectl apply -f /tmp/mongodb-maindb-service.yaml
done
rm /tmp/mongodb-maindb-service.yaml


# Deploy some Mongos Routers using a Kubernetes StatefulSet
echo "Deploying GKE Deployment & Service for some Mongos Routers"
kubectl apply -f ../resources/mongodb-mongos-service.yaml


# Wait until the final mongod of each Shard + the ConfigDB has started properly
echo
echo "Waiting for all the shards and configdb containers to come up (`date`)..."
echo " (IGNORE any reported not found & connection errors)"
sleep 30
echo -n "  "
until kubectl --v=0 exec mongod-configdb-0 -c mongod-configdb-container -- mongo --quiet --eval 'db.getMongo()'; do
    sleep 5
    echo -n "  "
done

until kubectl --v=0 exec mongod-shard$NUM_SHARDS-0 -c mongod-shard$NUM_SHARDS-container -- mongo --quiet --eval 'db.getMongo()'; do
sleep 5
echo -n "  "
done
echo -n "  "
echo "...shards & configdb containers are now running (`date`)"
echo


# Initialise the Config Server Replica Set and each Shard Replica Set
echo "Configuring Config Server's & each Shard's Replica Sets"
kubectl exec mongod-configdb-0 -c mongod-configdb-container -- mongo --eval 'rs.initiate({_id: "ConfigDBRepSet", version: 1, members: [ {_id: 0, host: "mongod-configdb-0.mongodb-configdb-service.default.svc.cluster.local:27017"}]});'

for (( i=1; i<=${NUM_SHARDS}; i++ ))
do
kubectl exec mongod-shard$i-0 -c mongod-shard$i-container -- mongo --eval 'rs.initiate({_id: "Shard'$i'RepSet", version: 1, members: [{_id: 0, host: "mongod-shard'$i'-0.mongodb-shard'$i'-service.default.svc.cluster.local:27017"}]});'
done
echo


# Wait for each MongoDB Shard's Replica Set + the ConfigDB Replica Set to each have a primary ready
echo "Waiting for all the MongoDB ConfigDB & Shards Replica Sets to initialise..."
kubectl exec mongod-configdb-0 -c mongod-configdb-container -- mongo --quiet --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'
for (( i=1; i<=${NUM_SHARDS}; i++ ))
do
kubectl exec mongod-shard${i}-0 -c mongod-shard${i}-container -- mongo --quiet --eval 'while (rs.status().hasOwnProperty("myState") && rs.status().myState != 1) { print("."); sleep(1000); };'
done

sleep 2 # Just a little more sleep to ensure everything is ready!
echo "...initialisation of the MongoDB Replica Sets completed"
echo


# Wait for the mongos to have started properly
echo "Waiting for the first mongos to come up (`date`)..."
echo " (IGNORE any reported not found & connection errors)"
echo -n "  "
until kubectl --v=0 exec mongos-router-0 -c mongos-container -- mongo --quiet --eval 'db.getMongo()'; do
    sleep 2
    echo -n "  "
done
echo "...first mongos is now running (`date`)"
echo -n "  "
echo


# Add Shards to the Configdb
echo "Configuring ConfigDB to be aware of the 3 Shards"
for (( i=1; i<=${NUM_SHARDS}; i++ ))
do
kubectl exec mongos-router-0 -c mongos-container -- mongo --eval 'sh.addShard("Shard'${i}'RepSet/mongod-shard'${i}'-0.mongodb-shard'${i}'-service.default.svc.cluster.local:27017");'
done
sleep 3


# Create the Admin User (this will automatically disable the localhost exception)
echo "Creating user: 'main_admin'"
kubectl exec mongos-router-0 -c mongos-container -- mongo --eval 'db.getSiblingDB("admin").createUser({user:"main_admin",pwd:"'"${NEW_PASSWORD}"'",roles:[{role:"root",db:"admin"}]});'
echo


# Print Summary State
kubectl get persistentvolumes
echo
kubectl get all 
echo

