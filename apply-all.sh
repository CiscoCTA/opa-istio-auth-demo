#!/bin/bash

echo -e "\n== Deploying services ==\n"
kubectl apply -f services/

echo -e "\n== Installing opa-istio-plugin ==\n"
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/opa-istio-plugin/f1d4c7f6deba9212c1a125b6a43af25e991ad936/quick_start.yaml

echo -e "\n== Configuring OPA ==\n"
kubectl delete configmap opa-policy
kubectl apply -f opa-config/

echo -e "\n== Restarting services ==\n"
kubectl delete pod "$(kubectl get pod -l app=admission-controller -n opa-istio -o 'jsonpath={.items[0].metadata.name}')" -n opa-istio
kubectl delete pod "$(kubectl get pod -l app=httpbin -o 'jsonpath={.items[0].metadata.name}')"

echo -e "\n== Testing the result ==\n"
echo "Waiting until the httpbin service is available"
while ! ./exec-in-netshoot.sh curl -s -o /dev/null 2>/dev/null httpbin:8000/anything/unprotected; do
  echo -n "."
done
echo

set -x
./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" httpbin:8000/anything/unprotected
./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" httpbin:8000/anything/protected
./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" "-HAuthorization: valid-token-1" httpbin:8000/anything/protected
./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" "-HAuthorization: valid-token-1" httpbin:8000/anything/user/user1
./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" "-HAuthorization: valid-token-1" httpbin:8000/anything/user/user2
