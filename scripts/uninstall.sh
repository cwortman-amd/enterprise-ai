#!/usr/bin/env bash
set -euo pipefail

FORCE="${FORCE:-false}"
WORKDIR="${WORKDIR:-$PWD/amd-enterprise-ai-install}"
FORGE_VERSION="${FORGE_VERSION:-v1.5.2}"
K8S_DELETE_TIMEOUT="${K8S_DELETE_TIMEOUT:-300s}"
REMOVE_PV_FINALIZERS="${REMOVE_PV_FINALIZERS:-true}"

log() { echo "[$(date '+%F %T')] $*"; }

confirm() {
  if [[ "${FORCE}" == "true" ]]; then
    return 0
  fi
  read -r -p "$1 [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]]
}

kubectl_ready() {
  command -v kubectl >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1
}

delete_if_present() {
  local resource="$1"
  shift
  kubectl delete "$resource" "$@" --ignore-not-found --wait=false 2>/dev/null || true
}

wait_for_no_resources() {
  local description="$1"
  local command="$2"

  log "Waiting up to ${K8S_DELETE_TIMEOUT} for ${description} to disappear..."
  timeout "${K8S_DELETE_TIMEOUT}" bash -c \
    "while [[ -n \"\$(${command} 2>/dev/null)\" ]]; do sleep 5; done" \
    || true
}

remove_finalizers_for_terminating_storage() {
  [[ "${REMOVE_PV_FINALIZERS}" == "true" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    log "jq is not installed; skipping PVC/PV finalizer cleanup."
    return 0
  fi

  log "Removing finalizers from terminating PVCs/PVs to unblock teardown..."
  kubectl get pvc -A -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | [.metadata.namespace, .metadata.name] | @tsv' \
    | while IFS=$'\t' read -r ns name; do
        [[ -n "${ns}" && -n "${name}" ]] || continue
        kubectl patch pvc "${name}" -n "${ns}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done

  kubectl get pv -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | .metadata.name' \
    | while read -r name; do
        [[ -n "${name}" ]] || continue
        kubectl patch pv "${name}" --type=merge -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 || true
      done
}

stop_kubernetes_workloads() {
  if ! kubectl_ready; then
    log "kubectl is not ready; skipping Kubernetes workload shutdown."
    return 0
  fi

  log "Stopping Kubernetes-managed EAI services and workloads..."
  delete_if_present aimservice --all -A
  delete_if_present inferenceservice --all -A
  delete_if_present job --all -A
  delete_if_present pod copy-gpt-oss-cache -n default
  delete_if_present pod -l app.kubernetes.io/managed-by=modelcache-controller -A
  delete_if_present pod -l aim.silogen.ai/modelcache -A
  delete_if_present pod -l serving.kserve.io/inferenceservice -A
}

cleanup_kubernetes_resources() {
  if ! kubectl_ready; then
    log "kubectl is not ready; skipping API-level Kubernetes cleanup."
    return 0
  fi

  stop_kubernetes_workloads

  log "Deleting AIM cache resources before PVCs..."
  delete_if_present aimtemplatecache --all -A
  delete_if_present aimmodelcache --all -A

  wait_for_no_resources "AIMModelCache resources" "kubectl get aimmodelcache -A --no-headers"
  wait_for_no_resources "cache jobs" "kubectl get jobs -A --no-headers | grep cache-download || true"

  log "Deleting all PVCs and PVs..."
  delete_if_present pvc --all -A
  wait_for_no_resources "PVCs" "kubectl get pvc -A --no-headers"
  remove_finalizers_for_terminating_storage
  wait_for_no_resources "PVCs after finalizer cleanup" "kubectl get pvc -A --no-headers"

  delete_if_present pv --all
  wait_for_no_resources "PVs" "kubectl get pv --no-headers"
  remove_finalizers_for_terminating_storage
  wait_for_no_resources "PVs after finalizer cleanup" "kubectl get pv --no-headers"

  log "Deleting AIM/KServe/Ray custom resources and CRDs..."
  delete_if_present aimclustermodel --all
  delete_if_present aimclusterservicetemplate --all
  delete_if_present aimclusterruntimeconfig --all
  delete_if_present aimmodel --all -A
  delete_if_present aimservicetemplate --all -A
  delete_if_present aimruntimeconfig --all -A
  delete_if_present servingruntime --all -A
  delete_if_present clusterservingruntime --all
  delete_if_present raycluster --all -A
  delete_if_present rayjob --all -A
  delete_if_present rayservice --all -A

  if command -v helm >/dev/null 2>&1; then
    log "Uninstalling Helm releases..."
    helm list -A -q 2>/dev/null \
      | while read -r release; do
          [[ -n "${release}" ]] || continue
          ns="$(helm list -A 2>/dev/null | awk -v rel="${release}" '$1 == rel {print $2; exit}')"
          [[ -n "${ns}" ]] || continue
          helm uninstall "${release}" -n "${ns}" >/dev/null 2>&1 || true
        done
  fi

  kubectl get crd -o name 2>/dev/null \
    | grep -E 'aim|silogen|kaiwo|kserve|serving.kserve|ray.io|longhorn.io' \
    | xargs -r kubectl delete --wait=false 2>/dev/null || true
}

stop_host_services() {
  log "Stopping host Kubernetes/container services..."
  sudo systemctl stop rke2-server 2>/dev/null || true
  sudo systemctl stop rke2-agent 2>/dev/null || true
  sudo systemctl stop kubelet 2>/dev/null || true
  sudo systemctl stop k3s 2>/dev/null || true
  sudo systemctl stop k3s-agent 2>/dev/null || true
  sudo systemctl stop containerd 2>/dev/null || true
  sudo systemctl stop docker 2>/dev/null || true
}

remove_residual_kubernetes_files() {
  log "Removing residual Kubernetes, RKE2, CNI, kubelet, and storage files..."
  sudo rm -rf \
    /etc/kubernetes \
    /etc/rancher \
    /etc/cni \
    /etc/crictl.yaml \
    /etc/systemd/system/kubelet.service \
    /etc/systemd/system/kubelet.service.d \
    /etc/systemd/system/rke2-server.service \
    /etc/systemd/system/rke2-agent.service \
    /etc/systemd/system/k3s.service \
    /etc/systemd/system/k3s-agent.service \
    /run/k3s \
    /run/flannel \
    /run/calico \
    /run/containerd/io.containerd.runtime.v2.task/k8s.io \
    /var/lib/cni \
    /var/lib/etcd \
    /var/lib/kubelet \
    /var/lib/rancher \
    /var/lib/calico \
    /var/lib/longhorn \
    /var/log/containers \
    /var/log/pods \
    /var/run/calico \
    /var/run/kubernetes \
    /opt/cni \
    /opt/cluster-bloom \
    /opt/cluster-forge \
    2>/dev/null || true

  sudo rm -f \
    /usr/local/bin/rke2 \
    /usr/local/bin/rke2-killall.sh \
    /usr/local/bin/rke2-uninstall.sh \
    /usr/local/bin/k3s \
    /usr/local/bin/k3s-killall.sh \
    /usr/local/bin/k3s-uninstall.sh \
    /etc/apparmor.d/docker \
    /etc/systemd/system/etcd* \
    2>/dev/null || true

  sudo rm -rf ~/.kube 2>/dev/null || true
  rm -rf "${WORKDIR}"
  rm -rf "${HOME}/amd-enterprise-ai-install"
}

echo "This will remove AMD Enterprise AI / Cluster Bloom artifacts, Kubernetes state, and generated configs."
echo "It will also attempt to purge related packages if they were installed by apt."
confirm "Continue?" || exit 0

echo "[1/9] Stopping Kubernetes-managed services and workloads..."
stop_kubernetes_workloads

echo "[2/9] Removing Kubernetes API resources while the API is available..."
cleanup_kubernetes_resources

echo "[3/9] Stopping host services if present..."
stop_host_services

echo "[4/9] Resetting Kubernetes state..."
if command -v kubeadm >/dev/null 2>&1; then
  sudo kubeadm reset -f || true
fi
if [[ -x /usr/local/bin/rke2-uninstall.sh ]]; then
  sudo /usr/local/bin/rke2-uninstall.sh || true
fi
if [[ -x /usr/local/bin/rke2-killall.sh ]]; then
  sudo /usr/local/bin/rke2-killall.sh || true
fi

echo "[5/9] Removing Kubernetes and related packages..."
if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get purge -y kubeadm kubectl kubelet kubernetes-cni kubernetes-cni-bin kube* rke2-* containerd.io containerd runc docker.io docker-ce docker-ce-cli || true
  sudo apt-get autoremove -y || true
fi

echo "[6/9] Removing residual Kubernetes files and directories..."
remove_residual_kubernetes_files

echo "[7/9] Reloading systemd after service file cleanup..."
sudo systemctl daemon-reload || true

echo "[8/9] Flushing iptables rules used by Kubernetes networking..."
sudo iptables -F || true
sudo iptables -X || true
sudo iptables -t nat -F || true
sudo iptables -t nat -X || true
sudo iptables -t raw -F || true
sudo iptables -t raw -X || true
sudo iptables -t mangle -F || true
sudo iptables -t mangle -X || true

echo "[9/9] Removing Docker artifacts and verifying cleanup..."
if command -v docker >/dev/null 2>&1; then
  sudo docker ps -aq | xargs -r sudo docker rm -f || true
  sudo docker system prune -a -f || true
fi

if command -v kubectl >/dev/null 2>&1; then
  kubectl get nodes 2>/dev/null || true
  kubectl get pods -A 2>/dev/null || true
fi

if command -v dpkg >/dev/null 2>&1; then
  echo "Installed Kubernetes-related packages after cleanup:"
  dpkg -l | awk '/kube|containerd|docker-ce|kubernetes-cni/ {print $0}' || true
fi

cat <<MSG

Cleanup complete.

Removed:
  - EAI Kubernetes workloads, cache CRs, jobs, pods, PVCs, and PVs
  - AIM/KServe/Ray/Longhorn CRDs and Helm releases when the API is reachable
  - RKE2 services and data directories
  - kubeadm reset state
  - Kubernetes configs and data directories
  - Generated install workspace
  - Related apt packages, if present
  - iptables rules for the cluster

What may still remain:
  - Some network interface changes
  - User-level kubeconfig history outside ~/.kube
  - Any custom storage volumes you created manually

If you want an even deeper rollback, I can give you a "full system revert" script that also removes:
  - container runtime packages only
  - CNI bridges/interfaces
  - leftover Kubernetes users/groups
  - any AMD Enterprise AI release directories
MSG
