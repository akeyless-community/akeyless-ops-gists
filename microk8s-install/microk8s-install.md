#Environment Variables
EMAIL=""
PUBLIC_IP="1.2.3.4"

#confirm you have these variables set:
echo $EMAIL
echo $PUBLIC_IP

sudo apt update && sudo apt upgrade -y
sudo snap install microk8s --classic
sudo snap install docker --classic
sudo groupadd docker
sudo usermod -aG docker $USER
sudo snap restart docker

newgrp docker

mkdir ~/.kube

microk8s config > ~/.kube/config
sudo usermod -a -G microk8s $USER
sudo chown -f -R $USER ~/.kube

newgrp microk8s

microk8s status --wait-ready
#alias microk8s commands to work with native kubectl and helm
sudo snap alias microk8s.kubectl kubectl
sudo snap alias microk8s.helm3 helm

#enable Microk8s addons
microk8s enable dns
microk8s enable ingress

kubectl delete ingressclass public
microk8s enable helm3

microk8s enable cert-manager --set crds.enabled=true --set global.leaderElection.namespace=cert-manager

#install kubectx and configure to work with Microk8s
sudo snap install kubectx --classic
echo 'export KUBECONFIG=/var/snap/microk8s/current/credentials/client.config' >> ~/.bashrc

# Add kubectl aliases
curl -sSL https://raw.githubusercontent.com/ahmetb/kubectl-aliases/master/.kubectl_aliases -o ~/.kubectl_aliases && grep -qxF '[ -f ~/.kubectl_aliases ] && source ~/.kubectl_aliases' ~/.bashrc || echo '[ -f ~/.kubectl_aliases ] && source ~/.kubectl_aliases' >> ~/.bashrc
export KUBECONFIG=/var/snap/microk8s/current/credentials/client.config
source ~/.bashrc

#create your namespaces
k create namespace akeyless

#Install and configure NGINX & Cert Manager

#configure Ingress with your public IP address from previous step
cat << EOF >| nginx-ingress-service.yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-ingress-microk8s-controller
  namespace: ingress
spec:
  type: LoadBalancer
  selector:
    name: nginx-ingress-microk8s
  externalIPs:
    - $PUBLIC_IP # Replace with your reserved static external IP
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
      name: http
    - protocol: TCP
      port: 443
      targetPort: 443
      name: https
EOF

kubectl apply -f nginx-ingress-service.yaml

cat << EOF >| lets-encrypt-prod-issuer.yml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-cluster-issuer
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $EMAIL
    privateKeySecretRef:
      name: letsencrypt-private-key
    solvers:
    - http01:
        ingress:
          ingressClassName: nginx
EOF
kubectl apply -f lets-encrypt-prod-issuer.yml

#add helm charts
helm repo add akeyless https://akeylesslabs.github.io/helm-charts
helm repo update

#Verify the Public IP Assignment to the Ingress Service
#To ensure that the static public IP is correctly associated with your Kubernetes Ingress, run the following command.  It will display the details of the NGINX Ingress Controller service, including its external IP, which should match the public IP you reserved. If the EXTERNAL-IP column shows the correct IP, the service is properly configured to route external traffic.

kubectl get services -n ingress
helm show values akeyless/akeyless-gateway > gateway-values.yaml

#Install the helm chart
#Before installing the Akeyless Unified Gateway using Helm, it’s important to customize the Helm chart values to suit your environment. This includes configuring the auth method, ca.pub cert, NGINX ingress settings, and other gateway-specific settings.

#To begin, you can retrieve the default Helm values and save them to a local file for customization:

helm show values akeyless/akeyless-gateway > gateway-values.yaml

#Once you’ve customized the values, you can install the Akeyless Unified Gateway using Helm


helm install akl-gcp-gw akeyless/akeyless-gateway -n akeyless -f gateway-values.yaml
#Sample unified gateway helm values file with NGINX


############
## Global ##
############
globalConfig:
  gatewayAuth:
    ## https://docs.akeyless.io/docs/gateway-chart#authentication
    gatewayAccessId: p-abc123
    gatewayAccessType: gcp
    gatewayCredentialsExistingSecret:
  ## See docs for examples https://docs.akeyless.io/docs/gateway-chart#gateway-admins
  allowedAccessPermissions:
    - name: Administrators
      access_id: p-samlid
      sub_claims:
        email:
          - first.x@akeyless.io
      permissions:
        - admin
  ## https://docs.akeyless.io/docs/gateway-chart#access-permissions
  ##
  allowedAccessPermissionsExistingSecret:
  ## will appear. For more information: https://docs.akeyless.io/docs/remote-access-setup-k8s#configuration
  ##
  authorizedAccessIDs:
  ## By default, this secret is named <deployment>-cache-encryption-key, unless a custom name has been specified.
  ##
  serviceAccount:
    create: false
    serviceAccountName:
    annotations:
  ## This is the actual name of the cluster as in account/access-id/clusterName
  ##
  clusterName: my-microk8s-gcp-gw
  ## This is the vanity display name of the cluster
  ##
  initialClusterDisplayName: my-microk8s-gcp-gw
  ## The key which is used to encrypt the Gateway configuration.
  ## If left empty - the account’s default key will be used.
  ## This key can be determined on cluster bringup only and cannot be modified afterwards
  ##
  configProtectionKeyName:
  ## Use k8s secret to set the CF, the k8s secret must include the key: customer-fragments
  ## See docs for examples https://docs.akeyless.io/docs/advanced-chart-configuration#customer-fragment
  ##
  customerFragmentsExistingSecret:
  ## See docs for examples https://docs.akeyless.io/docs/advanced-chart-configuration#tls-configuration
  ##
  TLSConf:
    enabled: false
    ## Specifies an existing secret for tls-certificate:
    tlsExistingSecret:
  ## Telemetry Metrics see docs for examples https://docs.akeyless.io/docs/telemetry-metrics-k8s
  ##
  metrics:
    enabled: false
    ## Existing secret for metrics must include:
    ## - otel-config.yaml (base64) secret
    ##
    metricsExistingSecret:
  ## Linux system HTTP Proxy
  httpProxySettings:
    http_proxy: ""
    https_proxy: ""
    no_proxy: ""
  # env: []
  ## https://docs.akeyless.io/docs/advanced-chart-configuration#cache-configuration
  ##
  clusterCache:
    ## In case Cache is enabled in the Gateway, and the encryptionKeyExistingSecret parameter has a value
    ## Akeyless will use this specified encryption key and store it securely within Akeyless Gateway.
    ## If the encryptionKeyExistingSecret parameter is empty or not specified,
    ## Akeyless will automatically generate a new encryption key and a new ServiceAccount for K8s.
    ## for more information: https://docs.akeyless.io/docs/advanced-chart-configuration#cache-configuration
    ##
    encryptionKeyExistingSecret:
    # Enable/Disable TLS  between the Gateway and the cluster cache service
    # using generated certificates and keys
    enableTls: false
    ## The resources limits for the redis cluster cache
    ##
    resources:
      limits:
        # cpu: 500m
        memory: 2Gi
      requests:
        cpu: 250m
        memory: 256Mi
####################################################
##          Default values for Gateway            ##
####################################################
gateway:
  ## Default values for akeyless-gateway.
  deployment:
    annotations: {}
    labels: {}
    replicaCount: 2
    image:
      #  repository: akeyless/base
      #   Alternative mirror registry
      #  repository: docker.registry-2.akeyless.io/base
      pullPolicy: IfNotPresent
    # Place here any pod annotations you may need
    pod:
      annotations: {}
    affinity:
      enabled: false
      data:
    #    nodeAffinity:
    #      requiredDuringSchedulingIgnoredDuringExecution:
    #        nodeSelectorTerms:
    #          - matchExpressions:
    #              - key: kubernetes.io/arch
    #                operator: In
    #                values:
    #                  - amd64
    # ref: https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/#node-affinity
    nodeSelector:
    #     iam.gke.io/gke-metadata-server-enabled: "true"
    securityContext:
      enabled: false
      fsGroup: 0
      runAsUser: 0
    containerSecurityContext: {}
    ## Remove the {} and add any needed values to your SecurityContext
    ##
    #  runAsUser: 0
    #  seccompProfile:
    #    type: RuntimeDefault
    livenessProbe:
      initialDelaySeconds: 60
      periodSeconds: 30
      failureThreshold: 10
    readinessProbe:
      initialDelaySeconds: 60
      periodSeconds: 10
      timeoutSeconds: 5
  service:
    ## Remove the {} and add any needed annotations regarding your LoadBalancer implementation
    ##
    annotations: {}
    labels: {}
    type: ClusterIP
    ## Gateway service port
    ##
    port: 8000
  ## Configure the ingress resource that allows you to access the
  ## akeyless-api-gateway installation. Set up the URL
  ## ref: https://kubernetes.io/docs/concepts/services-networking/ingress/
  ##
  ingress:
    ## Set to true to enable ingress record generation
    enabled: true
    ## A reference to an IngressClass resource
    ## ref: https://kubernetes.io/docs/concepts/services-networking/ingress/#deprecated-annotation
    ingressClassName: nginx
    labels: {}
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-cluster-issuer
      nginx.ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/proxy-connect-timeout: "3600"
      nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
      nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
      nginx.ingress.kubernetes.io/proxy-buffer-size: "8k"
      nginx.ingress.kubernetes.io/proxy-buffers-number: "4"
      # Large Header Support ----=v
      #nginx.ingress.kubernetes.io/client-body-buffer-size: 64k
      #nginx.ingress.kubernetes.io/client-header-buffer-size: 100k
      #nginx.ingress.kubernetes.io/http2-max-header-size: 96k
      #nginx.ingress.kubernetes.io/large-client-header-buffers: 4 100k
      #nginx.ingress.kubernetes.io/server-snippet: | # this is where the magic happens pt2
      #  client_header_buffer_size 100k;
      #  large_client_header_buffers 4 100k;
    rules:
      - servicePort: gateway
        hostname: "gcp-microk8s.fk.cs.akeyless.fans"
    ## Path for the default host
    path: /
    ## Ingress Path type the value can be ImplementationSpecific, Exact or Prefix
    pathType: ImplementationSpecific
    ## Enable TLS configuration for the hostname defined at ingress.hostname parameter
    ## TLS certificates will be retrieved from a TLS secret with name: {{- printf "%s-tls" .Values.gateway.ingress.hostname }}
    ## or a custom one if you use the tls.existingSecret parameter
    ##
    tls: true
    #tls:
    #  - hosts:
    #    - gcp-microk8s.fk.cs.akeyless.fans
    #    secretName: gcp-microk8s.fk.cs.akeyless.fans-tls
    #  existingSecret: name-of-existing-secret
    ## Set this to true in order to add the corresponding annotations for cert-manager and secret name
    certManager: true
  resources: {}
  hpa:
    ## Set the below to false in case you do not want to add Horizontal Pod AutoScaling
    ## Note that metrics server must be installed for this to work:
    ## https://github.com/kubernetes-sigs/metrics-server
    ##
    enabled: false
    minReplicas: 1
    maxReplicas: 10
    cpuAvgUtil: 70
    memAvgUtil: 70
    annotations: {}
######################################################
## Default values for akeyless-secure-remote-access ##
######################################################
## If you are only using Akeyless Gateway, ignore this section
##
sra:
  ## Enable secure-remote-access. Valid values: true/false.
  ## For more information on a Quick Start guide for Remote Access <https://docs.akeyless.io/docs/remote-access-quick-start-guide>
  ## Or setup SRA on K8s <https://docs.akeyless.io/docs/remote-access-setup-k8s>
  enabled: false
  image:
    ##  Default image repository is: akeyless/zero-trust-bastion
    ##
    pullPolicy: IfNotPresent
    #  tag: latest
  env: []
  ## The below section is for the Remote Access Web app
  ##
  webConfig:
    deployment:
      annotations: {}
      labels: {}
    replicaCount: 1
    ## Persistence Volume is used to store RDP recordings when it is configured to save recordings locally
    ## Akeyless requires data persistence to be shared within all pods in the cluster
    ## accessMode: ReadWriteMany
    ## Make sure to change the below values according to your environment except for the hostPath values
    ## see docs for more information <https://docs.akeyless.io/docs/remote-access-setup-k8s#configuration>
    ##
    persistence:
      volumes: {}
      #  volumes:
      #  - name: akeyless-data
      #    storageClassName: efs-zero-trust-bastion-sc
      #   #  storageClassDriver: efs.csi.aws.com
      #    size: 100Mi
      #    annotations:
      #     volume.beta.kubernetes.io/storage-class: ""
    livenessProbe:
      initialDelaySeconds: 15
      periodSeconds: 30
      failureThreshold: 10
    readinessProbe:
      initialDelaySeconds: 15
      periodSeconds: 30
      timeoutSeconds: 5
    resources:
      requests:
        cpu: 1
        memory: 2G
    hpa:
      ## Set the below to false in case you do not want to add Horizontal Pod AutoScaling to the Deployment
      ## If HPA is enabled resources requests must be set
      ##
      enabled: false
      minReplicas: 1
      maxReplicas: 10
      cpuAvgUtil: 70
      memAvgUtil: 70
  ## The below section is for the Remote Access SSH app
  ## For more information: <https://docs.akeyless.io/docs/remote-access-advanced-configuration-k8s#ssh-configuration>
  ##
  sshConfig:
    replicaCount: 1
    ## This is a required RSA Public Key for your Akeyless SSH Cert Issuer
    ## See docs for examples <https://docs.akeyless.io/docs/remote-access-setup-k8s#ssh--config>
    ##
    CAPublicKey:
    # CAPublicKey: |
    sshHostKeysPath:
    annotations: {}
    labels: {}
    nodeSelector:
    #  iam.gke.io/gke-metadata-server-enabled: "true"
    securityContext:
      enabled: false
      fsGroup: 0
      runAsUser: 0
    service:
      ## Remove the {} and add any needed annotations regarding your LoadBalancer implementation
      ##
      annotations: {}
      labels: {}
      type: LoadBalancer
      port: 22
    livenessProbe:
      failureThreshold: 5
      periodSeconds: 30
      timeoutSeconds: 5
    readinessProbe:
      initialDelaySeconds: 20
      periodSeconds: 10
      timeoutSeconds: 5
    resources:
      requests:
        cpu: 1
        memory: 2G
    hpa:
      ## Set the below to true only when using a shared persistent storage (defined at .persistence.volumes)
      ## If HPA is enabled resources requests must be set
      ##
      enabled: false
      minReplicas: 1
      maxReplicas: 10
      cpuAvgUtil: 70
      memAvgUtil: 70
Large Header Support
sometimes, the large header files do not get updated correctly and you may run into an error that looks like this:



failed to create k8s auth config: Failed to create k8s auth config. Status 400 Bad Request. Unexpected error reply object, Status: 400 Bad Request. Body: <html>
<head><title>400 Request Header Or Cookie Too Large</title></head>
<body>
<center><h1>400 Bad Request</h1></center>
<center>Request Header Or Cookie Too Large</center>
<hr><center>nginx</center>
</body>
</html>
 In this case you will need to modify the nginx config map to enable large header support. 



kubectl get ingress -A
kubectl get configmap <ingress name> -n ingress -o yaml > nginx-configmap.yaml
#add this to the very bottom of the config
data:
  large-client-header-buffers: "4 64k"
  client-header-buffer-size: "64k"
  http2-max-header-size: "64k"
Configure shared Storage class and Persistent volume for applications that need it. e.g. databases


switch to the my-apps namespace
kubens my-apps
cat << EOF >|| storageclass.yml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: shared-local-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
EOF
kubectl apply -f storageclass.yaml
cat << EOF >|| pv.yml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-shared
spec:
  capacity:
    storage: 50Gi  # Adjust as needed
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: shared-local-storage
  hostPath:
    path: /mnt/data/shared  # Base directory for shared use
EOF
kubectl apply -f pv.yaml
sudo mkdir -p /mnt/data/shared
sudo chmod -R 777 /mnt/data/shared
#when installing your helm chart, make sure to set the persistence storage 
#and storage size for each helm chart separately.  example for postgres db below
helm install postgres-db oci://registry-1.docker.io/bitnamicharts/postgresql \
  -n my-apps \
  --set primary.persistence.storageClass="shared-local-storage" \
  --set primary.persistence.size="10Gi"
