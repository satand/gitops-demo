# gitops-demo

# install and start cloud-provider-kind loadbalancer
# in a terminal execute
go install sigs.k8s.io/cloud-provider-kind@latest
sudo cloud-provider-kind

# install the other things
# in another terminal execute
install.sh

# test the applications deployed in gitops in both clusters
# cluster kind-hub
curl "http://localhost/bar" ; echo
curl -k "https://localhost/foo" ; echo
# cluster kind-01
curl "http://localhost:8080/bar" ; echo
curl -k "https://localhost:8443/foo" ; echo