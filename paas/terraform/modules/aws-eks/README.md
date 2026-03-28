# Terraform – AWS EKS module (skeleton)

This module provisions:

- **EKS cluster** (Kubernetes on AWS)
- **Node group** (worker nodes; **containerd** is the default runtime for EKS 1.24+)
- Optional: **VPC** and subnets (or use existing via data source)
- Optional: **Load balancer** for Nginx Ingress (NLB/ALB)

## Usage (example)

```hcl
module "eks" {
  source       = "./modules/aws-eks"
  cluster_name = "paas-${var.env}"
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids
  node_count   = 2
  node_instance_types = ["t3.medium"]
}

output "kubeconfig" {
  value     = module.eks.kubeconfig
  sensitive = true
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
```

## Containerd

EKS 1.24+ uses **containerd** as the container runtime (Docker is deprecated). Images built with **Docker** in Jenkins are OCI-compatible and run on containerd without change.

## Related

- **Nginx Ingress Controller**: Install via Helm in the cluster; its LoadBalancer service gets an AWS ELB.
- **HAProxy**: Optional; deploy on EC2 or use ALB/NLB in front of Ingress.
