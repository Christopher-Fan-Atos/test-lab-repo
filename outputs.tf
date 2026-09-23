output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.example.id
}

output "load_balancer_dns_name" {
  description = "Public DNS name of the load balancer - open this in a browser"
  value       = aws_lb.main.dns_name
}

output "ecr_repository_url" {
  description = "URL of the ECR repository for pushing custom images"
  value       = aws_ecr_repository.app.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  description = "Name of the ECS service running the container"
  value       = aws_ecs_service.app.name
}

output "log_group_name" {
  description = "CloudWatch Logs group where container logs are written"
  value       = aws_cloudwatch_log_group.app.name
}
