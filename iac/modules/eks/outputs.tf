output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_ca_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "Security group gerenciado pelo EKS, associado aos nodes."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_group" {
  description = "Node group, para uso em depends_on de addons."
  value       = aws_eks_node_group.this.id
}

output "node_group_asg_names" {
  description = "ASGs criados pelo node group, para registrar os nodes no target group do NLB."
  value       = [for asg in aws_eks_node_group.this.resources[0].autoscaling_groups : asg.name]
}
