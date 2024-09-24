#!/bin/bash

# If running this on WIndows with AKS Edge Essentials, this should be run in WSL2. WSL should be configured in network `mirroring` mode

export RESOURCE_GROUP=arc-demo
export LOCATION=northeurope
export ARC_CLUSTER_NAME=mars-aksee-01

export STORAGE_ACCOUNT_NAME=arcjumpstartfddemone001

export SUB_ID=$(az account show --query id -o tsv)

# Install local storage provisioner
kubectl apply -f https://raw.githubusercontent.com/Azure/AKS-Edge/main/samples/storage/local-path-provisioner/local-path-storage.yaml

# Get az cli here: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

az config set extension.dynamic_install_allow_preview=true

az extension add --name connectedk8s
az extension add --name k8s-extension

az provider register --namespace Microsoft.Kubernetes
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ExtendedLocation


az group create --name ${RESOURCE_GROUP} --location ${LOCATION} --output table


# Arc connect the local K8s/K3s cluster
az connectedk8s connect --name ${ARC_CLUSTER_NAME} --resource-group ${RESOURCE_GROUP}

# Deploy OSM

az k8s-extension create --resource-group ${RESOURCE_GROUP} --cluster-name ${ARC_CLUSTER_NAME} --cluster-type connectedClusters --extension-type Microsoft.openservicemesh --scope cluster --name osm

# Prepare Kubernetes namespace

export extension_namespace=azure-arc-containerstorage
kubectl create namespace "${extension_namespace}"
kubectl label namespace "${extension_namespace}" openservicemesh.io/monitored-by=osm
kubectl annotate namespace "${extension_namespace}" openservicemesh.io/sidecar-injection=enabled
# Disable OSM permissive mode.
kubectl patch meshconfig osm-mesh-config \
  -n "arc-osm-system" \
  -p '{"spec":{"traffic":{"enablePermissiveTrafficPolicyMode":'"false"'}}}'  \
  --type=merge

# Install the Azure Container Storage enabled by Azure Arc extension
az k8s-extension create --resource-group ${RESOURCE_GROUP} --cluster-name ${ARC_CLUSTER_NAME} --cluster-type connectedClusters --name azure-arc-containerstorage --extension-type microsoft.arc.containerstorage

# Configuration operator

kubectl apply -f - <<EOF
apiVersion: arccontainerstorage.azure.net/v1
kind: EdgeStorageConfiguration
metadata:
  name: edge-storage-configuration
spec:
  defaultDiskStorageClasses:
    - "default"
    - "local-path"
  serviceMesh: "osm"
EOF


# Setup cloud identity for edge volume

export EXTENSION_TYPE=${1:-"microsoft.arc.containerstorage"}
EV_ID=$(az k8s-extension list --cluster-name ${ARC_CLUSTER_NAME} --resource-group ${RESOURCE_GROUP} --cluster-type connectedClusters | jq --arg extType ${EXTENSION_TYPE} 'map(select(.extensionType == $extType)) | .[] | .identity.principalId' -r)

# Setup Storage account and containers for demo

if [ $(az storage account check-name --name $STORAGE_ACCOUNT_NAME --query nameAvailable -o tsv) == 'true' ]
then
   az storage account create -n ${STORAGE_ACCOUNT_NAME} -g ${RESOURCE_GROUP} -l ${LOCATION} --sku Standard_LRS
else
  echo "${STORAGE_ACCOUNT_NAME} exists; skipping"
fi

az storage container create --account-name ${STORAGE_ACCOUNT_NAME} -n fault-detection


# Configure blob storage account for Extension Identity

az role assignment create \
  --assignee $EV_ID \
  --role "Storage Blob Data Owner" \
  --scope /subscriptions/${SUB_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT_NAME}

# Create Edge Volume

kubectl apply -f - <<EOF
kind: PersistentVolumeClaim
apiVersion: v1
metadata:
  ### Create a name for your PVC ###
  name: esa-pvc
  ### Use a namespace that matched your intended consuming pod, or "default" ###
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: cloud-backed-sc
---
apiVersion: "arccontainerstorage.azure.net/v1"
kind: EdgeSubvolume
metadata:
  name: demo-data
spec:
  edgevolume: esa-pvc
  path: / # If you change this path, line 33 in deploymentExample.yaml must be updated. Don't use a preceding slash.
  auth:
    authType: MANAGED_IDENTITY
  storageaccountendpoint: "https://${STORAGE_ACCOUNT_NAME}.blob.core.windows.net/"
  container: fault-detection
  ingestPolicy: edgeingestpolicy-demo # Optional: See the following instructions if you want to update the ingestPolicy with your own configuration
EOF

kubectl apply -f - <<EOF
apiVersion: arccontainerstorage.azure.net/v1
kind: EdgeIngestPolicy
metadata:
  name: edgeingestpolicy-demo # This must be updated and referenced in the spec::ingestPolicy section of the edgeSubvolume.yaml
spec:
  ingest:
    order: oldest-first
    minDelaySec: 60
  eviction:
    order: unordered
    minDelaySec: 300
---
EOF

kubectl apply -f yaml/esa-deploy.yaml