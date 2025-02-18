#!/bin/bash

log() {
    local COLOR="$1"
    local MESSAGE="$2"
    local RESET="\e[0m\n"

    case "$COLOR" in
        red)    COLOR="\e[31m" ;;
        green)  COLOR="\e[32m" ;;
        yellow) COLOR="\e[33m" ;;
        blue)   COLOR="\e[34m" ;;
        purple) COLOR="\e[35m" ;;
        cyan)   COLOR="\e[36m" ;;
        *)      COLOR="\e[0m" ;; # Default (nessun colore)
    esac

    printf "${COLOR}${MESSAGE}${RESET}"
}

function createGitRepo() {
  HOST=$1
  USERNAME=$2
  PASSWORD=$3
  REPO_NAME=$4
  BASE_PATH=${5:-"repositories"}

  echo "Creating git repo from: ${BASE_PATH}/${REPO_NAME}"
  curl -v -s -XPOST -H "Content-Type: application/json" -k -u "${USERNAME}:${PASSWORD}" \
    --url "http://${HOST}/api/v1/user/repos" -d '{"name": "'${REPO_NAME}'", "private": false, "default_branch": "main"}'

  # Push the code to git repository
  pushd ${BASE_PATH}/${REPO_NAME} > /dev/null
  rm -rf .git
  git init
  git checkout -b main
  git add .
  git commit -m "first commit"
  git remote add origin http://gitea.nip.io/${USERNAME}/${REPO_NAME}.git
  git push -u origin main
  rm -rf .git
  popd > /dev/null

  echo "Created git repo: ${REPO_NAME}"
}

function deleteGitRepo() {
  HOST=$1
  USERNAME=$2
  PASSWORD=$3
  REPO_NAME=$4

  echo "Deleting git repo: ${REPO_NAME}"
  curl -v -s -XDELETE -H "Content-Type: application/json" -k -u "${USERNAME}:${PASSWORD}" \
    --url "http://${HOST}/api/v1/repos/${USERNAME}/${REPO_NAME}"
  
  echo "Deleted git repo: ${REPO_NAME}"
}

set -euo pipefail

## Create clusters
kind create cluster --config kind/kind-hub.yml
kind create cluster --config kind/kind-01.yml
kind create cluster --config kind/kind-02.yml

INGRESS_DOMAIN="nip.io"

## Add helm charts repos
echo
# helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add gitea-charts https://dl.gitea.io/charts/
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

## Install ingress-nginx
echo
# helm --kube-context kind-hub upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
#   --set controller.nodeSelector."kubernetes\.io/hostname"=kind-control-plane \
#   --set controller.tolerations[0].key="node-role.kubernetes.io/control-plane" \
#   --set controller.tolerations[0].effect=NoSchedule \
#   --set controller.watchIngressWithoutClass=true \
#   --namespace=ingress-nginx --create-namespace #--debug
# alternative mode
kubectl --context kind-hub apply -f ingress-nginx/deploy-ingress-nginx.yml
kubectl --context kind-01 apply -f ingress-nginx/deploy-ingress-nginx.yml
kubectl --context kind-02 apply -f ingress-nginx/deploy-ingress-nginx.yml
kubectl --context kind-hub wait --namespace ingress-nginx  --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s
kubectl --context kind-01 wait --namespace ingress-nginx  --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s
kubectl --context kind-02 wait --namespace ingress-nginx  --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s

## Install Gitea
echo
GITEA_HOST="gitea.${INGRESS_DOMAIN}"
GITEA_USERNAME=gitea_admin
GITEA_PASSWORD=gitea_admin
cat <<EOF | helm --kube-context kind-hub upgrade --install gitea gitea-charts/gitea --wait --create-namespace --namespace=gitea --values=-
ingress:
  enabled: true
  hosts:
  - host: "${GITEA_HOST}"
    paths:
      - path: /
        pathType: Prefix
gitea:
  admin:
    username: ${GITEA_USERNAME}
    password: ${GITEA_PASSWORD}
initPreScript: mkdir -p /data/git/gitea-repositories/gitea_admin/
EOF

# Create a Loadbalancer service for gitea to enable the communication from other clusters
echo
kubectl --context kind-hub -n gitea apply -f gitea/cluster-hub/gitea-loadbalancer-svc.yaml
kubectl --context kind-hub -n gitea wait svc/gitea --for=jsonpath='{.status.loadBalancer.ingress}'
GITEA_EXTERNAL_IP=$(kubectl --context kind-hub -n gitea get svc/gitea -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')
GITEA_EXTERNAL_PORT=$(kubectl --context kind-hub -n gitea get svc/gitea -o=jsonpath='{.status.loadBalancer.ingress[0].ports[0].port}')


# Create a service for gitea in the other clusters (connected to the external gitea ip/port of cluster hub)
echo
GITEA_SERVICE_YAML=$(sed "s/<GITEA_EXTERNAL_IP>/${GITEA_EXTERNAL_IP}/g; s/<GITEA_EXTERNAL_PORT>/${GITEA_EXTERNAL_PORT}/g" gitea/cluster-worker/gitea-svc.yaml)
echo "$GITEA_SERVICE_YAML" | kubectl --context kind-01 apply -f -
echo "$GITEA_SERVICE_YAML" | kubectl --context kind-02 apply -f -

## Create the git repos
echo
sleep 10
createGitRepo ${GITEA_HOST} ${GITEA_USERNAME} ${GITEA_PASSWORD} "app-of-apps"
createGitRepo ${GITEA_HOST} ${GITEA_USERNAME} ${GITEA_PASSWORD} "testapp" "repositories/config/applications"

## Setup ArgoCDs
echo
ARGOCD_HOST="argocd.${INGRESS_DOMAIN}"
ARGOCD01_HOST="argocd01.${INGRESS_DOMAIN}"
ARGOCD02_HOST="argocd02.${INGRESS_DOMAIN}"

# Install argocd in the cluster hub
cat <<EOF | helm --kube-context kind-hub upgrade --install argocd argo/argo-cd --wait --create-namespace --namespace=argocd --values=-
configs:
  cm:
    admin.enabled: true
    timeout.reconciliation: 10s
  params:
    server.insecure: true
    server.disable.auth: false
  repositories:
    local:
      name: local
      url: http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/testapp.git
server:
  ingress:
    enabled: true
    hostname: ${ARGOCD_HOST}
EOF

# Create the cluster hub argocd cluster reference to the peripheral clusters
# 1) Setup kubeconfig in hub-control-plane (container of cluster hub control-plane node)
# 2) Install argocd cli
# 3) Use argocd cli to create c01 and c02 argocd clusters in the hub argocd instance
echo
docker cp ~/.kube/config hub-control-plane:/root/.kube/config

export INTERNAL_IPADDRESS_HUB=$(kubectl --context kind-hub get nodes hub-control-plane -o jsonpath="{.status.addresses[?(@.type=='InternalIP')].address}" | awk '{print $1}')
export INTERNAL_IPADDRESS_01=$(kubectl --context kind-01 get nodes 01-control-plane -o jsonpath="{.status.addresses[?(@.type=='InternalIP')].address}" | awk '{print $1}')
export INTERNAL_IPADDRESS_02=$(kubectl --context kind-02 get nodes 02-control-plane -o jsonpath="{.status.addresses[?(@.type=='InternalIP')].address}" | awk '{print $1}')
export ARGOCD_CLI_VERSION=$(curl -L -s https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)

docker exec -i hub-control-plane /bin/bash <<EOF
unset KUBECONFIG

kubectl config set-cluster kind-hub --server https://$INTERNAL_IPADDRESS_HUB:6443
kubectl config set-cluster kind-01 --server https://$INTERNAL_IPADDRESS_01:6443
kubectl config set-cluster kind-02 --server https://$INTERNAL_IPADDRESS_02:6443

curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/download/v$ARGOCD_CLI_VERSION/argocd-linux-amd64
install -m 555 argocd-linux-amd64 /usr/local/bin/argocd
rm argocd-linux-amd64

kubectl config use-context kind-hub
kubectl config set-context --current --namespace=argocd
argocd login --core
argocd cluster add kind-01 --yes --name c01
argocd cluster add kind-02 --yes --name c02
EOF

# Install peripheral argocd instances using the clster hub argocd instance
echo
cat <<EOF | kubectl --context kind-hub apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-c01
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    name: c01
    namespace: argocd
  source:
    path: ''
    repoURL: https://argoproj.github.io/argo-helm
    targetRevision: 7.8.2
    chart: argo-cd
    helm:
      values: |
        configs:
          cm:
            admin.enabled: true
            timeout.reconciliation: 10s
          params:
            server.insecure: true
            server.disable.auth: false
          repositories:
            local:
              name: local
              url: "http://gitea.gitea.svc.cluster.local:3000/gitea_admin/testapp.git"
        server:
          ingress:
            enabled: true
            hostname: ${ARGOCD01_HOST}
  sources: []
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: -1 # number of failed sync attempt retries; unlimited number of attempts if less than 0
      backoff:
        duration: 5s # the amount to back off. Default unit is seconds, but could also be a duration (e.g. "2m", "1h")
        factor: 2 # a factor to multiply the base duration after each failed retry
        maxDuration: 10m # the maximum amount of time allowed for the backoff strategy
EOF
echo
cat <<EOF | kubectl --context kind-hub apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-c02
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    name: c02
    namespace: argocd
  source:
    path: ''
    repoURL: https://argoproj.github.io/argo-helm
    targetRevision: 7.8.2
    chart: argo-cd
    helm:
      values: |
        configs:
          cm:
            admin.enabled: true
            timeout.reconciliation: 10s
          params:
            server.insecure: true
            server.disable.auth: false
          repositories:
            local:
              name: local
              url: "http://gitea.gitea.svc.cluster.local:3000/gitea_admin/testapp.git"
        server:
          ingress:
            enabled: true
            hostname: ${ARGOCD02_HOST}
  sources: []
  project: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: -1 # number of failed sync attempt retries; unlimited number of attempts if less than 0
      backoff:
        duration: 5s # the amount to back off. Default unit is seconds, but could also be a duration (e.g. "2m", "1h")
        factor: 2 # a factor to multiply the base duration after each failed retry
        maxDuration: 10m # the maximum amount of time allowed for the backoff strategy
EOF

# Apply App-of-Apps root in  Applications
echo
kubectl --context kind-hub apply -f repositories/app-of-apps/base/cluster-hub/applications/cluster-hub-application-appset.yaml

## Get access info
echo
while ! kubectl --context kind-hub -n argocd get secret argocd-initial-admin-secret &> /dev/null; do
  echo "Waiting creation of secret/argocd-initial-admin-secret in argocd namespace of kind-hub cluster ..."
  sleep 5
done
ARGOCD_PASSWORD=$(kubectl --context kind-hub -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

while ! kubectl --context kind-01 -n argocd get secret argocd-initial-admin-secret &> /dev/null; do
  echo "Waiting creation of secret/argocd-initial-admin-secret in argocd namespace of kind-01 cluster ..."
  sleep 5
done
ARGOCD01_PASSWORD=$(kubectl --context kind-01 -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

while ! kubectl --context kind-02 -n argocd get secret argocd-initial-admin-secret &> /dev/null; do
  echo "Waiting creation of secret/argocd-initial-admin-secret in argocd namespace of kind-02 cluster ..."
  sleep 5
done
ARGOCD02_PASSWORD=$(kubectl --context kind-02 -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo
log "red" "Gitea" 
log "blue" "address: http://${GITEA_HOST} - login: U: ${GITEA_USERNAME} - P: ${GITEA_PASSWORD}"
echo
log "red" "ArgoCD HUB"
log "blue" "address: http://${ARGOCD_HOST} - login: U: admin - P: ${ARGOCD_PASSWORD}"
log "red" "ArgoCD 01"
log "blue" "address: http://${ARGOCD01_HOST}:8080 - login: U: admin - P: ${ARGOCD01_PASSWORD}"
log "red" "ArgoCD 02"
log "blue" "address: http://${ARGOCD02_HOST}:9080 - login: U: admin - P: ${ARGOCD02_PASSWORD}"

