variable "aws_region" {
  type        = string
  description = "AWS region"
  default     = "us-east-1"
}

variable "project_name" {
  type        = string
  description = "Project identifier"
  default     = "devsecops-paas"
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR"
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidr" {
  type        = string
  description = "Public subnet CIDR"
  default     = "10.10.1.0/24"
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type"
  default     = "t3.large"
}

variable "ami_id" {
  type        = string
  description = "AMI ID for worker/master nodes"
}

variable "key_name" {
  type        = string
  description = "EC2 SSH key pair"
}
