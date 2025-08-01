#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

VIRT_KUBECONFIG=/var/run/vault/vsphere-ibmcloud-config/vsphere-virt-kubeconfig
CLUSTER_KUBECONFIG=${SHARED_DIR}/kubeconfig
VM_NETWORK_PATCH=/var/run/vault/vsphere-ibmcloud-config/vm-network-patch.json
INFRA_PATCH=$(cat /var/run/vault/vsphere-ibmcloud-config/vsphere-virt-infra-patch)

VM_NAME="$(oc get infrastructure cluster -o json --kubeconfig=${CLUSTER_KUBECONFIG} | jq -r '.status.infrastructureName')-bm"
VM_NAMESPACE="${NAMESPACE}"

function approve_csrs() {
  CSR_COUNT=0
  echo "$(date -u --rfc-3339=seconds) - Approving the CSR requests for nodes..."
  # The cluster won't be ready to approve CSR(s) yet anyway
  sleep 90

  while true; do
    CSRS=$(oc get --kubeconfig=${CLUSTER_KUBECONFIG} csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name')
    if [[ $CSRS != "" ]]; then
      oc adm certificate approve $CSRS --kubeconfig=${CLUSTER_KUBECONFIG} || true
      CSR_COUNT=$(( CSR_COUNT + 1 ))
    fi
    if [[ $CSR_COUNT == 2 ]]; then
        return 0
    fi
    sleep 15
  done
}

# Add 'node.openshift.io/platform-type=vsphere' label to any node that is missing it.
function label_vsphere_nodes() {
  echo "$(date -u --rfc-3339=seconds) - Adding labels to vsphere nodes for builds that do not have upstream ccm changes..."
  NODES=$(oc get nodes -o name --kubeconfig="${CLUSTER_KUBECONFIG}")
  for node in ${NODES}; do
    echo "Checking ${node}"
    LABEL_FOUND=$(oc get ${node} -o json | jq -r '.metadata.labels | has("node.openshift.io/platform-type")')
    if [ "${LABEL_FOUND}" == "false" ]; then
      echo "Adding 'node.openshift.io/platform-type=vsphere' label"
      oc label "${node}" "node.openshift.io/platform-type"=vsphere
    fi
  done
}

# We are going to apply the 'node.openshift.io/platform-type=vsphere' label to all existing nodes as a workaround while waiting for upstream CCM changes
# When upstream changes are merged downstream, the function will output that no nodes were updated.
label_vsphere_nodes

# Patch test cluster to have CIDR for non-vSphere node
oc patch infrastructure cluster --type json -p "${INFRA_PATCH}" --kubeconfig=${CLUSTER_KUBECONFIG}

# Generate YAML for creation VM
echo "$(date -u --rfc-3339=seconds) - Generating ignition data"
installer_bin=$(which openshift-install)
VIRT_IMAGE=$("${installer_bin}" coreos print-stream-json | jq -r '.architectures.x86_64.images.kubevirt.image')
echo ${VIRT_IMAGE}

IGNITION_DATA=$(oc get secret worker-user-data -n openshift-machine-api -o json --kubeconfig=${CLUSTER_KUBECONFIG} | jq -r '.data.userData')

echo "$(date -u --rfc-3339=seconds) - Generating virtual machine yaml"
virtctl create vm --name ${VM_NAME} --instancetype ci-baremetal --volume-import type:registry,url:docker://${VIRT_IMAGE},size:60Gi,pullmethod:node --cloud-init configdrive --cloud-init-user-data ${IGNITION_DATA} --run-strategy=Manual -n ${VM_NAMESPACE} > "${SHARED_DIR}/vm.yaml"

# Create namespace if it does not exist (it will exist if multiple jobs run in same namespace)
if [[ "$(oc get ns ${VM_NAMESPACE} --ignore-not-found --kubeconfig="${VIRT_KUBECONFIG}")" == "" ]]; then
  echo "$(date -u --rfc-3339=seconds) - Creating job namespace"
  oc create ns ${VM_NAMESPACE} --kubeconfig=${VIRT_KUBECONFIG}
fi

# Create VM (VM will not be running)
echo "$(date -u --rfc-3339=seconds) - Creating virtual machine"
oc create -f "${SHARED_DIR}/vm.yaml" --kubeconfig=${VIRT_KUBECONFIG}

# Update VM to have CI network
echo "$(date -u --rfc-3339=seconds) - Patching networking config into virtual machine"
oc patch vm ${VM_NAME} -n ${VM_NAMESPACE} --type=merge --patch-file ${VM_NETWORK_PATCH} --kubeconfig=${VIRT_KUBECONFIG}

# Start VM
echo "$(date -u --rfc-3339=seconds) - Starting virtual machine"
virtctl start "${VM_NAME}" -n ${VM_NAMESPACE} --kubeconfig=${VIRT_KUBECONFIG}

# Monitor cluster for CSRs
approve_csrs

# Remove provider taint
oc adm taint nodes ${VM_NAME} node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule- --kubeconfig="${CLUSTER_KUBECONFIG}"
