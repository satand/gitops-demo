# gitops-demo

## install and start cloud-provider-kind loadbalancer
in a terminal execute
```bash
go install sigs.k8s.io/cloud-provider-kind@latest
sudo cloud-provider-kind
```
## install the other things
```bash
in another terminal execute
install.sh
```

## test the applications deployed in gitops
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