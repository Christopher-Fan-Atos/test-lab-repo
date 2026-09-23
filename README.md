# Terraform Container Deployment Lab

A containerized app deployed on AWS with Terraform: VPC → ECR → ECS Fargate → ALB.

## Quick reference

| What | Value |
|---|---|
| Repository URI | `685306736016.dkr.ecr.us-west-2.amazonaws.com/terraform-example-christopher-fan-app` |
| Service name | `terraform-example-Christopher-Fan-service` |
| Cluster/runtime name | `terraform-example-Christopher-Fan-cluster` (ECS Fargate) |
| Image tag | `v1` (full URI: `...terraform-example-christopher-fan-app:v1`) |
| Public endpoint | http://tf-example-cfan-alb-1945165384.us-west-2.elb.amazonaws.com/ |
| Log group | `/ecs/terraform-example-Christopher-Fan-app` |
| VPC ID | `vpc-0d3bb3bf33b078eaa` |
| Terraform code | this directory |

Run `terraform output` to re-fetch these values at any time.

## Part 8 pre-flight checklist

Before leaving, know each of these:

1. **Your repository URI** — `685306736016.dkr.ecr.us-west-2.amazonaws.com/terraform-example-christopher-fan-app`
   The ECR repo storing the image (`aws_ecr_repository.app` in [registry.tf](registry.tf)). A registry address for `docker push`/`pull` — no `http://` scheme, not opened in a browser.

2. **Your service name** — `terraform-example-Christopher-Fan-service`
   The ECS service keeping the task running (`aws_ecs_service.app` in [compute.tf](compute.tf)). Wednesday's pipeline targets this by name to force a new deployment.

3. **Your cluster/runtime name** — `terraform-example-Christopher-Fan-cluster`
   The ECS cluster the service runs on (`aws_ecs_cluster.main`). No EC2 host to name since Part 6 migrated to Fargate — the cluster is the closest equivalent to a "runtime."

4. **Your image tag** — `v1`
   Full reference: `685306736016.dkr.ecr.us-west-2.amazonaws.com/terraform-example-christopher-fan-app:v1`. Matches `container_image_tag` in [variables.tf](variables.tf) and what the running task definition references.

5. **Your public endpoint** — http://tf-example-cfan-alb-1945165384.us-west-2.elb.amazonaws.com/
   The ALB's DNS name — a true URI with a scheme, meant to be opened in a browser or hit with `curl` (unlike #1, which is a registry address, not a browsable URI).

6. **Where the Terraform code lives** — `C:\Users\a958693\Documents\Workshops\Terraform\`
   Specifically [providers.tf](providers.tf), [variables.tf](variables.tf), [networking.tf](networking.tf), [registry.tf](registry.tf), [compute.tf](compute.tf), [load_balancer.tf](load_balancer.tf), [outputs.tf](outputs.tf). This directory is not a git repository, so there's no remote URL to hand off — just this local path.

## Architecture

```
Browser
  |
  v
ALB (aws_lb.main) : port 80
  security group: aws_security_group.alb  (0.0.0.0/0 -> 80)
  |
  v
Target group (aws_lb_target_group.app, target_type = ip)
  |
  v
ECS Fargate task (aws_ecs_service.app on aws_ecs_cluster.main)
  security group: aws_security_group.container (only from ALB's SG -> container_port)
  image pulled from: aws_ecr_repository.app
  logs -> CloudWatch Logs: aws_cloudwatch_log_group.app
```

- **Network** ([networking.tf](networking.tf)): VPC, 2 public subnets across different AZs, IGW, public route table.
- **Registry** ([registry.tf](registry.tf)): private ECR repo for the app image.
- **Compute** ([compute.tf](compute.tf)): ECS cluster, task definition (CPU/memory/image/port/logging), ECS service (desired count, subnets, security group), IAM execution role, container security group.
- **Load balancer** ([load_balancer.tf](load_balancer.tf)): ALB, ALB security group, target group, listener.
- **Variables** ([variables.tf](variables.tf)): everything that should change per student/team — `project_name`, `aws_region`, `environment_name`, `container_image_tag`, `container_port`, `task_cpu`, `task_memory`, `desired_count`, `vpc_cidr`, `public_subnet_cidrs`.
- **Outputs** ([outputs.tf](outputs.tf)): VPC ID, ALB DNS name, ECR URL, ECS cluster/service names, log group name.

## Manual flow performed today (Parts 4-7)

1. `docker pull nginxdemos/hello:latest` — pull the public source image.
2. `aws ecr get-login-password | docker login ...` — authenticate Docker to the private AWS registry.
3. `docker tag nginxdemos/hello:latest <repository-uri>:v1` — retag it to point at the private ECR repo.
4. `docker push <repository-uri>:v1` — push the retagged image.
5. Update `container_image_tag` in [variables.tf](variables.tf) to the ECR URI and `terraform apply` — update the deployed image (this replaces the ECS task definition/service).
6. `curl` the ALB DNS name — verify the endpoint.

## Wednesday's goal: automate this flow

```
Code or config change
      |
      v
Pipeline runs
      |
      v
Image is pushed to AWS (ECR)
      |
      v
Service is updated (ECS)
      |
      v
Endpoint shows the new version
```

| Today (manual) | Wednesday (pipeline) |
|---|---|
| `docker pull` | Build (or pull) the new image from the code change |
| `docker tag ... <ECR-URI>:v1` | Tag per run — commit SHA or build number, not a fixed `v1` |
| `docker login` + `docker push` | Same commands, run under the pipeline's own IAM role, not a personal CLI session |
| Edit `variables.tf`, `terraform apply` | Register a new task definition revision and `aws ecs update-service --force-new-deployment` (or `terraform apply -var="container_image_tag=..."`) |
| `curl` the ALB DNS name | Pipeline polls the ECS service/ALB until healthy, then runs the same check as a smoke test |

**Gap to close before Wednesday:** `container_image_tag`'s default in [variables.tf](variables.tf) is currently a hardcoded `:v1`. A pipeline needs to pass a new tag on every run rather than editing the file by hand each time.

## Troubleshooting

- **Endpoint returns a 5xx**: check the target group's health status (Console → Target Groups), the ECS service's Events tab, and the CloudWatch Logs group above for application errors.
- **Container never starts**: check ECS → cluster → service → Tasks → stopped tasks → "Stopped reason" (commonly `CannotPullContainerError` — an execution role or networking issue), and the service's Events tab for scheduling failures.

## Known gotchas hit during this lab

- ECR repository names must be lowercase — the `name` field on `aws_ecr_repository` uses `lower(...)`.
- `aws_lb` / `aws_lb_target_group` names are capped at 32 characters by AWS — see `local.short_name_prefix` in [load_balancer.tf](load_balancer.tf).
- EC2 `user_data` only runs on first boot — irrelevant now (migrated to ECS Fargate in Part 6), but the same idea applies to task definitions: changing the image requires a new task definition revision + service deployment, not just an in-place edit.
- Replacing an `aws_lb_target_group` that's still referenced by a listener fails outright unless `create_before_destroy` is set (see the `lifecycle` block on `aws_lb_target_group.app`).
# test-lab-repo
