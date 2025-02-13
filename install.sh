#!/bin/bash

set -euo pipefail

kind create cluster --config kind.yml

INGRESS_DOMAIN="nip.io"

## install ingress-nginx
echo
# helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
# helm repo update
# helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
#   --set controller.nodeSelector."kubernetes\.io/hostname"=kind-control-plane \
#   --set controller.tolerations[0].key="node-role.kubernetes.io/control-plane" \
#   --set controller.tolerations[0].effect=NoSchedule \
#   --set controller.watchIngressWithoutClass=true \
#   --namespace=ingress-nginx --create-namespace #--debug
# alternative mode
kubectl apply -f ingress-nginx/deploy-ingress-nginx.yml
sleep 15
kubectl wait --namespace ingress-nginx  --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s

## add helm charts repos
echo
helm repo add gitea-charts https://dl.gitea.io/charts/
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

## install Gitea
echo
GITEA_HOST="gitea.${INGRESS_DOMAIN}"
GITEA_USERNAME=gitea_admin
GITEA_PASSWORD=gitea_admin
echo
cat <<EOF | helm upgrade --install gitea gitea-charts/gitea --wait --create-namespace --namespace=gitea --values=-
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

## configure Gitea
# Create repo
curl -v -s -XPOST -H "Content-Type: application/json" -k -u "${GITEA_USERNAME}:${GITEA_PASSWORD}" \
  --url "http://${GITEA_HOST}/api/v1/user/repos" -d '{"name": "test-repo", "private": false, "default_branch": "main"}'
# Push code to git repository
cd test-repo
rm -rf .git
git init
git checkout -b main
git add .
git commit -m "first commit"
git remote add origin http://gitea.nip.io/gitea_admin/test-repo.git
git push -u origin main
cd ..

## setup ArgoCD
echo
ARGOCD_HOST="argocd.${INGRESS_DOMAIN}"
cat <<EOF | helm upgrade --install argocd argo/argo-cd --wait --create-namespace --namespace=argocd --values=-
configs:
  cm:
    admin.enabled: false
    timeout.reconciliation: 10s
  params:
    server.insecure: true
    server.disable.auth: true
  repositories:
    local:
      name: local
      url: http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/test-repo.git
server:
  ingress:
    enabled: true
    hostname: ${ARGOCD_HOST}
EOF

# Create an ArgoCD Application to monitor my local repository under mnt
echo
cat <<EOF | kubectl apply -f -
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
    repoURL: http://gitea-http.gitea.svc.cluster.local:3000/gitea_admin/test-repo.git
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

echo
echo "Gitea address: http://${GITEA_HOST}"
echo "Gitea login: U: ${GITEA_USERNAME} - P: ${GITEA_PASSWORD}"
echo
echo "ArgoCD address: http://${ARGOCD_HOST}"
