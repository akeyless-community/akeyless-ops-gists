#!/bin/bash

set -x

# ---------------------------------------------------------------
# ------- Input Variables -----------------------BEGIN-----------
# ---------------------------------------------------------------
CLOUD_PROVIDER="gke"
K8S_AUTH_METHOD_NAME="fk-$CLOUD_PROVIDER-auth-method"
K8S_AUTH_GATEWAY_CONFIG_NAME="fk-$CLOUD_PROVIDER-k8s-conf"
K8S_AUTH_ACCESS_METHOD_JSON_FILE="akl_$CLOUD_PROVIDER_k8s_auth.json"
K8S_AUTH_SERVICE_ACCOUNT_AND_BINDING_FILE_NAME="akl_gw_token_reviewer.yaml"
AKEYLESS_NAMESPACE="fk-$CLOUD_PROVIDER-akeyless"
AKEYLESS_GATEWAY_CONFIG_URL="https://gw-config.fk-$CLOUD_PROVIDER.akeyless-security.com" # Default is port 8000
JWT_READER_CONTAINER_NAME="jwt-parser"
# ---------------------------------------------------------------
# ------- Input Variables -----------------------END-------------
# ---------------------------------------------------------------

## Create a known entity that we can control and trust
# This service account will have the cluster role binding permissions
cat << EOF >| "$K8S_AUTH_SERVICE_ACCOUNT_AND_BINDING_FILE_NAME"
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gateway-token-reviewer
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: role-tokenreview-binding
  namespace: default
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:auth-delegator
subjects:
- kind: ServiceAccount
  name: gateway-token-reviewer
  namespace: default 
EOF

## set the default namespace where the gateway token reviewer will be installed
kubectl config set-context --current --namespace=default

## Create a service account named gateway-token-reviewer with permission to access token review API.
# This service account will be used to validate a Kubernetes JWT coming from a pod that sends requests to us
akeyless create-auth-method-k8s -n "$K8S_AUTH_METHOD_NAME" \
        --json >| "$K8S_AUTH_ACCESS_METHOD_JSON_FILE"

#associate the new auth method to a role
akeyless assoc-role-am -r /kubernetes/kubernetes -a fk-$CLOUD_PROVIDER-auth-method -s namespace=my-apps

#Set the permissions to read and list items e.g. secrets
akeyless set-role-rule -r /kubernetes/kubernetes -p "/k8s/*" -c read -c list --rule-type=item-rule

#install the gateway token reviewer
kubectl apply -f "$K8S_AUTH_SERVICE_ACCOUNT_AND_BINDING_FILE_NAME"

#Extract the Gateway Service Account Name
GW_SA_NAME=$(kubectl get sa gateway-token-reviewer \
        --output jsonpath="{.secrets[*]['name']}")

#Exract the service account JWT
SA_JWT_TOKEN=$(kubectl get secret "$GW_SA_NAME" \
        --output 'go-template={{ .data.token }}' | base64 --decode)

#extract the CA Cert
CA_CERT=$(kubectl config view --raw --minify --flatten  \
        --output 'jsonpath={.clusters[].cluster.certificate-authority-data}')


# Extract the Private key and Access ID from the K8s Auth access method JSON file.
PRV_KEY=$(jq -r '.prv_key' < "$K8S_AUTH_ACCESS_METHOD_JSON_FILE")
ACCESS_ID=$(jq -r '.access_id' < "$K8S_AUTH_ACCESS_METHOD_JSON_FILE")

## Cluster host is whichever IP the gateway uses to commuicate with the cluster
#doesn't have to be a public IP, it can be private
CLUSTER_HOST=$(kubectl config view --raw --minify --flatten -o json | jq -r '.clusters[0].cluster.server')

# Extract the issuer:  this is a little tricky, you'll need to spin up a pod to get the issuer name.
K8S_ISSUER=$(kubectl run "$JWT_READER_CONTAINER_NAME" --image=smallstep/step-ca --restart=Never --attach \
        --command -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | step crypto jwt inspect --insecure \
        | jq -r '.payload.iss' && kubectl delete pod "$JWT_READER_CONTAINER_NAME" 2>&1 >/dev/null)

# Create the K8S auth config in Akeyless
akeyless gateway-create-k8s-auth-config  --name "$K8S_AUTH_GATEWAY_CONFIG_NAME" \
        --gateway-url "$AKEYLESS_GATEWAY_CONFIG_URL" \
        --access-id "$ACCESS_ID" \
        --signing-key "$PRV_KEY" \
        --k8s-host "$CLUSTER_HOST" \
        --token-reviewer-jwt "$SA_JWT_TOKEN" \
        --k8s-ca-cert "$CA_CERT" \
        --k8s-issuer "$K8S_ISSUER"

#install the kubernetes injector weboohok service
#helm repo update
#helm install fk-$CLOUD_PROVIDER-k8sinjector akeyless/akeyless-secrets-injection --namespace k8sinjector -f values.yaml
