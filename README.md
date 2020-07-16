# Securing REST APIs in Kubernetes with Istio and OPA - Demo

## Prerequisites
This example can be run on a local installation of Istio on Kubernetes provided by Docker Desktop. 
The following prerequisites are needed:
* Have [Docker Desktop](https://docs.docker.com/) installed
* [Configure Docker Desktop for Istio](https://istio.io/docs/setup/platform-setup/docker/) 
* Configure Kubernetes on your Docker Desktop ([Mac](https://docs.docker.com/docker-for-mac/#kubernetes), [Windows](https://docs.docker.com/docker-for-windows/kubernetes/))
* [Install Istio](https://archive.istio.io/v1.4/docs/setup/getting-started/) - follow just the first two steps (Download and Install), no need to deploy the sample application (this demo was written for Istio 1.4 and may require some changes for newer versions):
    * On MacOS or Linux systems, this boils down to: 
        ```
        curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.4.9 sh -
        cd istio-1.4.9
        ./bin/istioctl manifest apply --set profile=demo
        ```
    
**The rest of this document describes the remaining setup of the demo in steps. The entire process can also by applied at once with [`./apply-all.sh`](apply-all.sh).**

## Services
Before we configure Istio and OPA, let us deploy a couple of services for the example:

```shell script
kubectl apply -f services/
``` 
This will deploy
* [`netshoot`](https://github.com/nicolaka/netshoot) - we will `exec` into this pod to test our setup
* [`httpbin`](https://httpbin.org/) - this will serve as our target service whose REST API we want to protect
* `access-management` - this is a [WireMock](http://wiremock.org/) instance that will simulate the Access Management Service for token validation and translation.

In order to test the setup, you can run commands from within the `netshoot` pod with `./exec-in-netshoot.sh`. You should see outputs similar to this:

```
> ./exec-in-netshoot.sh curl httpbin:8000/headers
{
  "headers": {
    "Accept": "*/*",
    "Host": "httpbin:8000",
    "User-Agent": "curl/7.65.1"
  }
}

> ./exec-in-netshoot.sh curl access-management:8080/auth/api-clients/me
Invalid token

> ./exec-in-netshoot.sh curl "-HAuthorization: valid-token-1" access-management:8080/auth/api-clients/me
{"apiClientId":"8bb18d14-696d-4858-856b-2d610a48b13c","identity":{"username":"user1"}}
```  

## OPA Configuration
The final part of the example is configuration of OPA and authorization policies.

Start with [`opa-istio-plugin`](https://github.com/open-policy-agent/opa-istio-plugin) installation in the default configuration. This will set up a couple of things, most importantly the admission controller that injects `opa-istio` sidecars:
```shell script
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/opa-istio-plugin/f1d4c7f6deba9212c1a125b6a43af25e991ad936/quick_start.yaml
``` 

Then apply our customizations:
```shell script
kubectl delete configmap opa-policy
kubectl apply -f opa-config/
```

The following will be deployed:
* [`namespace-labels.yaml`](opa-config/namespace-labels.yaml) - adds labels to the default namespace enabling injection of Istio and OPA sidecars. Note that the pods need to be redeployed for this to take effect.  
* [`ext-authz-envoyfilter.yaml`](opa-config/ext-authz-envoyfilter.yaml) - modifies the default configuration of `envoy.ext_authz` filter to deny access in case of OPA failure, and to pass validated identity information from the `envoy.lua` filter (([line 33-35](opa-config/inject-policy.yaml#L33)).
* [`authn-lua-envoyfilter.yaml`](opa-config/authn-lua-envoyfilter.yaml) - adds an `envoy.lua` filter before the `envoy.ext_authz` filter. The `envoy.lua` filter is responsible for delegating token validation and translation to `access-management`. 
* [`inject-policy.yaml`](opa-config/inject-policy.yaml) - configures how OPA sidecars are injected. This is where we configure that:
    * the policy referenced by the `opa-policy-config-map-name` label should be used if present ([line 86-89](opa-config/inject-policy.yaml#L86))
    * [`opa-policy-default`](opa-config/opa-policy-default.yaml) policy should be used if the label is not present 
    * [`opa-policy-common`](opa-config/opa-policy-common.yaml) policy should be mounted to all containers 
* [`policy-httpbin-opa.yaml`](opa-config/opa-policy-httpbin.yaml) - defines the service-specific OPA policy for httpbin. This ConfigMap [is referenced](services/httpbin.yaml#L28) by the `opa-policy-config-map-name` label on the `httpbin` pod.
* [`opa-istio-config.yaml`](opa-config/opa-istio-config.yaml) - turns on OPA logging with the `decision_logs` setting.

Finally, we need to redeploy the services and admission controller so that changes in configuration are applied:

```shell script
kubectl delete pod $(kubectl get pod -l app=admission-controller -n opa-istio -o 'jsonpath={.items[0].metadata.name}') -n opa-istio
kubectl delete pod $(kubectl get pod -l app=httpbin -o 'jsonpath={.items[0].metadata.name}')
```

## Testing the result
Every request to `httpbin` now
1. goes to `istio-proxy` sidecar,
2. `authn-lua` filter is executed which translates the `Authorization` header to client identity information,
3. the client identity information is passed along with other request metadata to `opa-istio` sidecar where the authorization decision happens,
4. and if successful, the request is forwarded to `httpbin` container.

You should see results similar to the following:

```
> ./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" httpbin:8000/anything/unprotected
200
> ./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" httpbin:8000/anything/protected
403
> ./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" "-HAuthorization: valid-token-1" httpbin:8000/anything/protected
200
> ./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" "-HAuthorization: valid-token-1" httpbin:8000/anything/user/user1
200
> ./exec-in-netshoot.sh curl -s -o /dev/null -w "%{http_code}\n" "-HAuthorization: valid-token-1" httpbin:8000/anything/user/user2
403
```

OPA logs can be observed with
```shell script
kubectl logs -f $(kubectl get pod -l app=httpbin -o 'jsonpath={.items[0].metadata.name}') -c opa-istio
```

## Contact
If you have any questions or comments, you can reach out to the author at [LinkedIn](https://www.linkedin.com/in/jmichelfeit/).
