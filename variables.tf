variable "project_name" {
  description = "Name used to prefix and tag all resources for this student/team"
  type        = string
  default     = "terraform-example"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "environment_name" {
  description = "Environment name (e.g. dev, staging)"
  type        = string
  default     = "Christopher-Fan"
}

variable "container_image_tag" {
  description = "Container image (repo:tag) to run in the ECS task"
  type        = string
  default     = "685306736016.dkr.ecr.us-west-2.amazonaws.com/terraform-example-christopher-fan-app:v1"
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 80
}

variable "task_cpu" {
  description = "Fargate task CPU units (256 = 0.25 vCPU)"
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Fargate task memory in MB"
  type        = string
  default     = "512"
}

variable "desired_count" {
  description = "Number of running copies of the task"
  type        = number
  default     = 1
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.10.16.0/20"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (must fit within vpc_cidr)"
  type        = list(string)
  default     = ["10.10.16.0/24", "10.10.17.0/24"]
}
