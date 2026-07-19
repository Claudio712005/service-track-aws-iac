provider "aws" {
  region = var.aws_region
}

data "aws_eks_cluster_auth" "this" {
  name = module.stack.cluster_name
}

provider "kubernetes" {
  host                   = module.stack.cluster_endpoint
  cluster_ca_certificate = base64decode(module.stack.cluster_ca_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.stack.cluster_endpoint
    cluster_ca_certificate = base64decode(module.stack.cluster_ca_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}
