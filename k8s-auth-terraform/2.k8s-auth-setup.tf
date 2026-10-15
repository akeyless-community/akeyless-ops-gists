terraform {
  required_providers {
    akeyless = {
      version = ">= 1.0.0"
      source  = "akeyless-community/akeyless"
    }
  }
}

variable "access_id" {
  type        = string
  description = "value of the Akeyless API access id (This Access ID MUST be configured in the allowedAccessIDs of the Gateway or BE the adminAccessId for the Gateway)"
}

variable "access_key" {
  type        = string
  description = "value of the Akeyless API access key"
  sensitive   = true
}

variable "k8s_issuer" {
  type        = string
  description = <<-EOF
  You can get the cluster issuer a number of ways
  - exec into the pod running the Akeyless Gateway on the cluster and run this command:
    cat /var/run/secrets/kubernetes.io/serviceaccount/token | cut -d'.' -f2 | base64 --decode | jq -r '.iss'
  - run this kubectl command to create a pod and read the issuer
    kubectl run jwtr --image=smallstep/step-ca --restart=Never --attach --command \
        -- cat /var/run/secrets/kubernetes.io/serviceaccount/token | step crypto jwt inspect \
        --insecure | jq -r '.payload.iss' && kubectl delete pod jwtr 2>&1 >/dev/null
  EOF
}

variable "k8s_host" {
  type        = string
  description = <<-EOF
    The hostname of the Kubernetes API server.
    This can be an IP address or a hostname including schema.
    If you are running Kubernetes in a cluster,
    this should be the hostname of the API server.
    If you are running Kubernetes in a standalone mode,
    this should be the hostname of the Kubernetes master node.
    Examples:
    - https://your-kubernetes-hostname.com
  EOF
}

variable "k8s_auth_name" {
  type        = string
  description = "The name of the Akeyless k8s Auth Method"
}

variable "k8s_auth_config_name" {
  type        = string
  description = "The name of the Akeyless k8s Auth Config"
}

variable "api_gateway_address" {
  type        = string
  description = <<-EOF
    value of the Akeyless Gateway 8081 port address 
    Examples:
    - http://localhost:8081 if using port forwarding
    - http://your-gateway-ip-address:8081 if using a port
    - https://your-gateway-api-address.com that maps to the 8081 port
    EOF
}

variable "kubeconfig_path" {
  type        = string
  default     = "~/.kube/config"
  description = "The path to the kubeconfig file"
}

variable "reviewer_name" {
  type        = string
  default     = "gateway-token-reviewer"
  description = "The name of the kubernetes service account token reviewer"
}

variable "reviewer_namespace" {
  type        = string
  default     = "default"
  description = "The namespace of the kubernetes service account token reviewer"
}

provider "akeyless" {
  api_gateway_address = var.api_gateway_address

  api_key_login {
    access_id  = var.access_id
    access_key = var.access_key
  }

  # aws_iam_login {
  #   access_id = var.access_id
  # }

  # azure_ad_login {
  #   access_id = var.access_id
  # }

  # email_login {
  #   admin_email    = ""
  #   admin_password = ""
  # }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

resource "akeyless_auth_method_k8s" "k8s_auth_method" {
  name = var.k8s_auth_name
}

resource "kubernetes_service_account_v1" "reviewer" {
  metadata {
    namespace = var.reviewer_namespace
    name      = var.reviewer_name
  }
}

resource "kubernetes_cluster_role_binding_v1" "reviewer_binding" {
  metadata {
    name = "${kubernetes_service_account_v1.reviewer.metadata[0].name}-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.reviewer.metadata[0].name
    namespace = kubernetes_service_account_v1.reviewer.metadata[0].namespace
  }
}

data "kubernetes_secret" "reviewer" {
  metadata {
    name      = kubernetes_service_account_v1.reviewer.default_secret_name
    namespace = kubernetes_service_account_v1.reviewer.metadata[0].namespace
  }
}

resource "akeyless_k8s_auth_config" "k8s_auth_config" {
  name               = var.k8s_auth_config_name
  access_id          = akeyless_auth_method_k8s.k8s_auth_method.access_id
  signing_key        = akeyless_auth_method_k8s.k8s_auth_method.private_key
  token_reviewer_jwt = data.kubernetes_secret.reviewer.data.token
  k8s_issuer         = var.k8s_issuer
  k8s_host           = var.k8s_host
  k8s_ca_cert        = base64encode(data.kubernetes_secret.reviewer.data["ca.crt"])
}
