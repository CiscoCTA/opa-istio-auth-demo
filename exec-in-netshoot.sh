#!/bin/bash
kubectl exec "$(kubectl get pod -l app=netshoot -o 'jsonpath={.items[0].metadata.name}')" -c netshoot -it -- "$@"
