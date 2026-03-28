module "network" {
  source             = "./modules/network"
  project_name       = var.project_name
  vpc_cidr           = var.vpc_cidr
  public_subnet_cidr = var.public_subnet_cidr
}

module "compute" {
  source            = "./modules/compute"
  project_name      = var.project_name
  ami_id            = var.ami_id
  instance_type     = var.instance_type
  key_name          = var.key_name
  subnet_id         = module.network.public_subnet_id
  security_group_id = module.network.security_group_id
}
