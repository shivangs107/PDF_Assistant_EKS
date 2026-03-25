#Compatibility Issue with v5
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.10"
    }
  }
}

#AWS Provider
provider "aws" {
  region = "ap-south-1"
}

#Get infra state (From EKS module to know the cluster name)
data "terraform_remote_state" "eks" {
  backend = "local"

  config = {
    path = "../eks/terraform.tfstate"
  }
}

# Get cluster info (Normally kubectl config would be used, but here we fetch it directly from AWS)
#Cluster API Endpoint and Cluster certificate.
data "aws_eks_cluster" "cluster" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

#Cluster Authentication Token
data "aws_eks_cluster_auth" "cluster" {
  name = data.terraform_remote_state.eks.outputs.cluster_name
}

# Kubernetes Provider (Configured to interact with the EKS cluster so that we can manage K8s resources directly from Terraform without needing kubectl apply)
provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

# Helm Provider (Configured to interact with the EKS cluster so that we can manage Helm charts directly from Terraform without needing helm CLI. For prometheus and grafana deployment)
provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

# SSM Secret (We fetch the OpenAI API key from AWS SSM Parameter Store, which is a secure way to manage secrets. This avoids hardcoding sensitive information in our Terraform code or Kubernetes manifests.)
data "aws_ssm_parameter" "openai" {
  name            = "OPENAI_API_KEY"
  with_decryption = true
}

# Kubernetes Secret (Creates a Kubernetes secret to store the OpenAI API key securely within the cluster)
# AWS SSM → Terraform Data Source → Kubernetes Secret → Mounted as Environment Variable in the Application
resource "kubernetes_secret" "openai" {
  metadata {
    name = "openai-secret"
  }

  data = {
    OPENAI_API_KEY = data.aws_ssm_parameter.openai.value
  }
}

#Installing Monitoring (Prometheus + Grafana) using Helm.
#If not then I would have to do: 
#aws eks update-kubeconfig --name pdf-assistant-cluster
#helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
#helm repo update
#helm install monitoring prometheus-community/kube-prometheus-stack --namespace monitoring --create-namespace
#Create a values.yaml file to add the ServiceMonitor for our application and then do:
#helm install monitoring prometheus-community/kube-prometheus-stack -f values.yaml
#Then write servicemonitor.yaml manually and applying it
#Then to get grafana url: kubectl get svc -n monitoring
resource "helm_release" "monitoring" {
  name       = "monitoring"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"

  namespace        = "monitoring"
  create_namespace = true

  #Make Grafana public url instead of port forwarding
  set {
    name  = "grafana.service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "prometheus.service.type"
    value = "ClusterIP"
  }

  set {
    name  = "grafana.sidecar.dashboards.enabled"
    value = "true"
  }

  set {
    name  = "grafana.sidecar.dashboards.label"
    value = "grafana_dashboard"
  }
  set {
    name  = "prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues"
    value = "false"
  }
values = [<<EOF
prometheus:
  prometheusSpec:
    serviceMonitorSelector:
      matchLabels:
        release: monitoring

  additionalServiceMonitors:
    - name: pdf-assistant-monitor
      selector:
        matchLabels:
          app: pdf-assistant
      namespaceSelector:
        matchNames:
          - default
      endpoints:
        - port: metrics
          interval: 15s
          path: /metrics
      labels:
        release: monitoring
EOF
]

  wait    = true
  timeout = 900
}

#Grafana Dashboard (We create a ConfigMap to store a custom Grafana dashboard JSON. This dashboard will be automatically picked up by the Grafana sidecar we enabled in the Helm chart, allowing us to visualize our application's metrics without manual intervention.)
resource "kubernetes_config_map" "grafana_dashboard" {
  metadata {
    name      = "pdf-dashboard"
    namespace = "monitoring"

    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "pdf-dashboard.json" = <<EOF
{
  "id": null,
  "uid": "pdf-dashboard",
  "title": "PDF Assistant Monitoring",
  "timezone": "browser",
  "panels": [
    {
      "type": "stat",
      "title": "Total Queries",
      "targets": [
        {
          "expr": "sum(pdf_queries_total)"
        }
      ],
      "gridPos": { "x": 0, "y": 0, "w": 8, "h": 4 }
    },
    {
      "type": "stat",
      "title": "PDF Uploads",
      "targets": [
        {
          "expr": "sum(pdf_uploaded_total)"
        }
      ],
      "gridPos": { "x": 8, "y": 0, "w": 8, "h": 4 }
    },
    {
      "type": "timeseries",
      "title": "Query Rate",
      "targets": [
        {
          "expr": "rate(pdf_queries_total[1m])"
        }
      ],
      "gridPos": { "x": 0, "y": 4, "w": 12, "h": 6 }
    },
    {
      "type": "timeseries",
      "title": "Average Latency",
      "targets": [
        {
          "expr": "rate(query_latency_seconds_sum[1m]) / rate(query_latency_seconds_count[1m])"
        }
      ],
      "gridPos": { "x": 12, "y": 4, "w": 12, "h": 6 }
    },
    {
      "type": "timeseries",
      "title": "P95 Latency",
      "targets": [
        {
          "expr": "histogram_quantile(0.95, rate(query_latency_seconds_bucket[1m]))"
        }
      ],
      "gridPos": { "x": 0, "y": 10, "w": 24, "h": 6 }
    }
  ],
  "schemaVersion": 36,
  "version": 1
}
EOF
  }

  depends_on = [helm_release.monitoring]
}

# App Deployment (Manages pods and ensures desired number of replicas are always running)
resource "kubernetes_deployment" "pdf_app" {
  metadata {
    name = "pdf-assistant"
    labels = {
      app = "pdf-assistant"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        app = "pdf-assistant"
      }
    }

    template {
      metadata {
        labels = {
          app = "pdf-assistant"
        }
      }

      spec {
        container {
          name  = "pdf-assistant"
          image = "shivangs107/pdf-assistant-eks:latest"

          port {
            container_port = 8501
          }

          port {
            container_port = 8000
          }

          env {
            name = "OPENAI_API_KEY"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.openai.metadata[0].name
                key  = "OPENAI_API_KEY"
              }
            }
          }
        }
      }
    }
  }
}

# Service (Exposing to outside world using LoadBalancer, so that we can access the application using the LoadBalancer URL. The service also exposes the metrics port for Prometheus to scrape.)
#Act as a bridge between users and my pods.
#Exposes pods and provides stable networing.
resource "kubernetes_service" "pdf_service" {
  metadata {
    name = "pdf-assistant-service"
    labels = {
      app = "pdf-assistant"
    }
  }

  spec {
    selector = {
      app = "pdf-assistant"
    }
    type = "LoadBalancer"

    port {
      name        = "web"
      port        = 80
      target_port = 8501
    }

    port {
      name        = "metrics"
      port        = 8000
      target_port = 8000
    }
  }
  depends_on = [kubernetes_deployment.pdf_app]
}

# Grafana Service (To skip: kubectl get svc -n monitoring to fetch the LoadBalancer URL for Grafana, we directly fetch it using a data source in Terraform)
#Fetching the Grafana service details from Kubernetes
data "kubernetes_service" "grafana" {
  metadata {
    name      = "monitoring-grafana"
    namespace = "monitoring"
  }
}

#For Grafana Password
data "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "monitoring-grafana"
    namespace = "monitoring"
  }

  depends_on = [helm_release.monitoring]
}

# Outputs
output "app_url" {
  value = try(
    "http://${kubernetes_service.pdf_service.status[0].load_balancer[0].ingress[0].hostname}",
    "pending..."
  )
  description = "Application LoadBalancer URL"
}

output "grafana_url" {
  value = try(
    "http://${data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].hostname}",
    "pending..."
  )
  description = "Grafana LoadBalancer URL"
}

output "grafana_dashboard_url" {
  value = try(
    "http://${data.kubernetes_service.grafana.status[0].load_balancer[0].ingress[0].hostname}/d/pdf-dashboard/pdf-assistant-monitoring",
    "pending..."
  )
}

output "grafana_admin_password" {
  value = data.kubernetes_secret.grafana_admin.data["admin-password"]
  sensitive = true
}