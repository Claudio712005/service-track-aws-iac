variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project" {
  type    = string
  default = "servicetrack"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/20", "10.0.16.0/20"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.48.0/20", "10.0.64.0/20"]
}

variable "cluster_name" {
  type    = string
  default = "servicetrack-dev"
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "db_name" {
  type    = string
  default = "servicetrack"
}

variable "db_username" {
  type    = string
  default = "servicetrack"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_engine_version" {
  type    = string
  default = "16.9"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "argocd_chart_version" {
  type    = string
  default = "7.7.0"
}

variable "metrics_server_chart_version" {
  type    = string
  default = "3.12.2"
}

variable "argocd_expose_lb" {
  description = "Expor o argocd-server via LoadBalancer publico. false = acesso apenas por kubectl port-forward."
  type        = bool
  default     = true
}
