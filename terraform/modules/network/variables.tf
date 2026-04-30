variable "env" { type = string }
variable "aws_region" { type = string }
variable "eks_cluster_name" {
  type        = string
  description = "Value for kubernetes.io/cluster/<name> on public subnets"
}
