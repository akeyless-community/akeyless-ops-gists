provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

# variable "api_access_key" {
#   type = string  
# }

resource "helm_release" "k8s-secret-injection" {
  name = "fk-aks-k8sinjector"

  repository = "https://akeylesslabs.github.io/helm-charts"
  chart      = "akeyless-secrets-injection"
  namespace  = "k8sinjector"
  depends_on = [
    akeyless_k8s_auth_config.k8s_auth_config
  ]
  version = "1.2.9"
  values = [<<EOT
replicaCount: 1
minikube: false
openshiftEnabled: false
debug: false

tlsCertsSecretName: vault-secrets-webhook-tls-certs

image:
  repository: akeyless/k8s-webhook-server
  pullPolicy: Always
  tag: 0.20.7

serviceAccount:
  # Specifies whether a service account should be created
  create: true
  # The name of the service account to use.
  # If not set and create is true, a name is generated using the fullname template
  # name: ""
  # Optional additional annotations to add to the controller's ServiceAccount
  # annotations: {}
  # Automount API credentials for a Service Account.
  automountServiceAccountToken: true

service:
  name: secrets-webhook
  type: ClusterIP
  externalPort: 443
  internalPort: 8443

env:
  AKEYLESS_URL: ${var.api_gateway_address}
  AKEYLESS_AGENT_IMAGE:  "akeyless/k8s-secrets-sidecar:latest"
  AKEYLESS_ACCESS_ID: ${akeyless_auth_method_k8s.k8s_auth_method.access_id}
  AKEYLESS_ACCESS_TYPE: "k8s"  # azure_ad/aws_iam/api_key/k8s
  AKEYLESS_API_GW_URL: ${var.api_gateway_address}
  AKEYLESS_K8S_AUTH_CONF_NAME: ${var.k8s_auth_config_name}


resources:
  limits:
    cpu: 0.5
    memory: 192Mi
  requests:
    cpu: 0.25
    memory: 128Mi

nodeSelector: {}

tolerations: []

affinity: |
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
    - weight: 100
      podAffinityTerm:
        topologyKey: kubernetes.io/hostname
        labelSelector:
          matchLabels:
            app: {{ template "vault-secrets-webhook.name" . }}
            release: {{ .Release.Name }}

  EOT
  ]
}
