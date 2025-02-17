#!/bin/bash

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
sleep 15
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

## Create the git repo
echo
sleep 10
curl -v -s -XPOST -H "Content-Type: application/json" -k -u "${GITEA_USERNAME}:${GITEA_PASSWORD}" \
  --url "http://${GITEA_HOST}/api/v1/user/repos" -d '{"name": "test-repo", "private": false, "default_branch": "main"}'
# Push the code to git repository
cd test-repo
rm -rf .git
git init
git checkout -b main
git add .
git commit -m "first commit"
git remote add origin http://gitea.nip.io/gitea_admin/test-repo.git
git push -u origin main
cd ..

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
      url: http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/test-repo.git
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
              url: "http://gitea.gitea.svc.cluster.local:3000/gitea_admin/test-repo.git"
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
              url: "http://gitea.gitea.svc.cluster.local:3000/gitea_admin/test-repo.git"
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

# Create ArgoCD Applications
echo
cat <<EOF | kubectl --context kind-hub apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: test-app
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  destination:
    namespace: default
    server: 'https://kubernetes.default.svc'
  project: default
  source:
    path: apps
    repoURL: http://gitea.gitea.svc.cluster.local:3000/gitea_admin/test-repo.git
    targetRevision: HEAD
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

sleep 5
ARGOCD_PASSWORD=$(kubectl --context kind-hub -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
ARGOCD01_PASSWORD=$(kubectl --context kind-01 -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
ARGOCD02_PASSWORD=$(kubectl --context kind-02 -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo
echo "Gitea" 
echo "address: http://${GITEA_HOST} - login: U: ${GITEA_USERNAME} - P: ${GITEA_PASSWORD}"
echo
echo "ArgoCD HUB"
echo "address: http://${ARGOCD_HOST} - login: U: admin - P: ${ARGOCD_PASSWORD}"
echo "ArgoCD 01"
echo "address: http://${ARGOCD01_HOST}:8080 - login: U: admin - P: ${ARGOCD01_PASSWORD}"
echo "ArgoCD 02"
echo "address: http://${ARGOCD02_HOST}:9080 - login: U: admin - P: ${ARGOCD02_PASSWORD}"

