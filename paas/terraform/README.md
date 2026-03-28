# Terraform – Infrastructure Architecture

## Purpose

- Provision cloud infrastructure (VPC, subnets, security groups).
- Create and manage Kubernetes cluster nodes (e.g. EKS worker nodes, GKE node pools, or VM-based kubeadm workers).
- Optionally provision Ingress LB, DNS, and baseline monitoring (Prometheus/Grafana).

## Recommended structure

```
terraform/
├── modules/
│   ├── network/          # VPC, subnets, NAT (AWS: vpc, subnets; GCP: network)
│   ├── kubernetes/       # EKS / AKS / GKE or self-managed node group
│   ├── ingress/         # LB for Ingress controller (optional)
│   └── monitoring/      # Prometheus/Grafana (optional; or use Helm in K8s)
├── environments/
│   ├── dev/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── terraform.tfvars
│   │   └── outputs.tf
│   └── prod/
├── versions.tf           # Provider and Terraform version constraints
└── README.md
```

## Example module usage (conceptual)

**environments/dev/main.tf:**

```hcl
module "network" {
  source = "../modules/network"
  env    = "dev"
  cidr   = "10.0.0.0/16"
}

module "kubernetes" {
  source     = "../modules/kubernetes"
  vpc_id     = module.network.vpc_id
  subnet_ids = module.network.private_subnet_ids
  node_count = 2
}
```

## Kubernetes node creation (Terraform)

- **AWS EKS:** `aws_eks_node_group` or `eks-managed-node-groups` (in EKS module).
- **GCP GKE:** `google_container_node_pool`.
- **Azure AKS:** `azurerm_kubernetes_cluster_node_pool`.
- **Self-managed (e.g. kubeadm):** Terraform creates VMs (e.g. `aws_instance`), then user data or external automation (Ansible/scripts) installs kubeadm and joins the cluster.

## Outputs

- `kubeconfig` or `cluster_endpoint`, `cluster_ca_certificate` for ArgoCD/Jenkins.
- `ingress_lb_dns` if an LB is created for the Ingress controller.
