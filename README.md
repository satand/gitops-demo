# gitops-demo

## Prepare podman machine if you are using it
Open a ssh session with the podman machine
```bash
podman machine ssh podman-machine-default
```
execute
```bash
sudo sysctl net.ipv4.ip_unprivileged_port_start=80
```
to permit use of ports >= 80 as unprivileged ports.
Then close the ssh session
```bash
exit
```

## Install and start cloud-provider-kind loadbalancer
In a terminal execute
```bash
go install sigs.k8s.io/cloud-provider-kind@latest
sudo cloud-provider-kind
```
## Install the other things
```bash
in another terminal execute
install.sh
```

## Test the applications deployed in gitops
cluster kind-hub
```bash
curl "http://localhost/bar" ; echo
curl -k "https://localhost/foo" ; echo
```
cluster kind-01
```bash
curl "http://localhost:8080/bar" ; echo
curl -k "https://localhost:8443/foo" ; echo
```
cluster kind-02
```bash
curl "http://localhost:9080/bar" ; echo
curl -k "https://localhost:9443/foo" ; echo
```

## Set /etc/hosts of local host to view the UI portals of Gitea and ArgoCDs
Edit /etc/hosts file
```bash
sudo vi /etc/hosts
```
adding this lines
```bash
# Demo gitops
127.0.0.1        gitea.nip.io argocd.nip.io argocd01.nip.io argocd02.nip.io
```