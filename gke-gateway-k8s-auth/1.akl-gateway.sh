#!/bin/bash

#set -x

# ---------------------------------------------------------------
# ------- Input Variables -----------------------BEGIN-----------
# ---------------------------------------------------------------
CLOUD_PROVIDER="gke"
EMAIL_ADDRESS="my@email.address"
K8S_NAMESPACE_CERT_ISSUER="lets-encrypt-prod-issuer.yml"
AKEYLESS_GATEWAY_VALUES_FILE="/my/directory/$CLOUD_PROVIDER/values.yaml"
AKEYLESS_GATEWAY_VALUES_FILE="values.yaml"
AKEYLESS_NAMESPACE="fk-$CLOUD_PROVIDER-akeyless-namespace"
AKEYLESS_GATEWAY_NAME="fk-$CLOUD_PROVIDER-gateway"
AKEYLESS_GATEWAY_CONFIG_URL="https://gateway-config.fk-$CLOUD_PROVIDER.akeyless-security.com" # Default is port 8000
# ---------------------------------------------------------------
# ------- Input Variables -----------------------END-------------
# ---------------------------------------------------------------

#Create the namespace
kubectl create namespace "$AKEYLESS_NAMESPACE"
kubectl create namespace cert-manager

# Set default kubectl context
kubectl config set-context --current --namespace="$AKEYLESS_NAMESPACE"

# Add Helm Repos and update
echo ADDING HELM REPOS & UPDATING
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo add jetstack https://charts.jetstack.io
helm repo add akeyless https://akeylesslabs.github.io/helm-charts
helm repo update

# Install Ingress controller
echo INSTALLING NGINX INGRESS CONTROLLER
helm install quickstart ingress-nginx/ingress-nginx -n "$AKEYLESS_NAMESPACE"
echo INGRESS CONTROLLER INSTALLED

# Install Cert Manager
echo INSTALLING CERT MANAGER
helm install -n cert-manager \
  --set installCRDs=true \
  --set global.leaderElection.namespace=cert-manager cert-manager jetstack/cert-manager
echo CERT MANAGER INSTALLED
echo WAIT 2 MINUTES BEFORE INSTALLING CERT ISSUER
sleep 120

# Be sure to change email to your email
cat << EOF >| "$K8S_NAMESPACE_CERT_ISSUER"
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  annotations: {}
  name: letsencrypt-prod
spec:
  acme:
    email: "$EMAIL_ADDRESS"
    preferredChain: ""
    privateKeySecretRef:
      name: letsencrypt-prod
    server: https://acme-v02.api.letsencrypt.org/directory
    solvers:
      - http01:
          ingress:
            class: nginx
EOF

kubectl apply -f "$K8S_NAMESPACE_CERT_ISSUER" -n "$AKEYLESS_NAMESPACE"
helm install "$AKEYLESS_GATEWAY_NAME" akeyless/akeyless-api-gateway -f "$AKEYLESS_GATEWAY_VALUES_FILE" -n "$AKEYLESS_NAMESPACE"
