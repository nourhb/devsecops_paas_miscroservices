# HAProxy integration

HAProxy can be used in two ways in this platform:

## 1. In front of Nginx Ingress Controller (AWS)

- Terraform creates an **AWS NLB or ALB** (or EC2 running HAProxy).
- HAProxy terminates TLS (optional) and forwards to the **Nginx Ingress Controller** service (LoadBalancer or NodePort).
- DNS points to HAProxy (or to the AWS load balancer that fronts HAProxy).

## 2. As TCP load balancer

- For non-HTTP traffic (e.g. database, custom TCP), HAProxy can run as a pod or on EC2 and route to Kubernetes NodePort or ClusterIP.

## Example: HAProxy in front of Nginx (outside cluster)

- Install HAProxy on an EC2 instance (or use HAProxy in a container).
- Configure `backend` to the Nginx Ingress Controller LoadBalancer hostname (AWS) or NodePort.
- Point your domain to the HAProxy server (or its ELB).

## Terraform (AWS)

- Use `aws_lb` (NLB) with target group pointing to Nginx Ingress Controller nodes, or
- Use `aws_instance` + user_data to install and configure HAProxy, then register with a target group.

See `../terraform/` for AWS module examples.
