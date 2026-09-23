# Day 2 Extension — ECS Configuration and Operations

Configuration → Secrets → Logging → Monitoring, layered onto the ECS Fargate
deployment from Day 1, before Day 3 automates the deploy flow.

## Part 1 — Review the Deployment

| Resource | Value |
|---|---|
| ECR Repository | `685306736016.dkr.ecr.us-west-2.amazonaws.com/terraform-example-christopher-fan-app` |
| ECS Cluster | `terraform-example-Christopher-Fan-cluster` |
| ECS Service | `terraform-example-Christopher-Fan-service` |
| Task Definition | family `terraform-example-Christopher-Fan-app` ([compute.tf:65-96](compute.tf#L65-L96)) |
| ALB Endpoint | `http://tf-example-cfan-alb-1945165384.us-west-2.elb.amazonaws.com` |
| CloudWatch Log Group | `/ecs/terraform-example-Christopher-Fan-app` |

Defined in: ECR in [registry.tf](registry.tf); cluster/service/task def/log group
in [compute.tf](compute.tf); ALB in [load_balancer.tf](load_balancer.tf). Values
confirmed live with `terraform output`.

**Checkpoint:** know where the app runs and where its logs go. ✅

## Part 2 — Add Environment Variables

Added `APP_NAME`, `ENVIRONMENT`, `AWS_REGION` to the container definition in
[compute.tf](compute.tf), sourced from existing variables (`var.project_name`,
`var.environment_name`, `var.aws_region`) rather than hardcoding new ones:

```hcl
environment = [
  { name = "APP_NAME", value = var.project_name },
  { name = "ENVIRONMENT", value = var.environment_name },
  { name = "AWS_REGION", value = var.aws_region }
]
```

`terraform apply` registered a new task definition revision and rolled the ECS
service onto it. Verified via `aws ecs describe-services`: new revision reached
`runningCount: 1`, old revision drained to 0, ALB kept returning `200`.

**Checkpoint:** ECS accepted the update; tasks stayed healthy throughout the
rollout. ✅

### Q&A

**Why should configuration be separated from the image?**
The image is an immutable artifact — build it once and promote the same bytes
through dev → staging → prod. Baking config into the image means rebuilding
per environment, which breaks that guarantee and risks environment-specific
bugs leaking into a "tested" artifact. Environment variables let the same
image behave differently per environment purely through the task
definition/deployment, which is also what makes rollbacks safe (roll back the
task def, not the image).

**Which values commonly change between environments?**
`ENVIRONMENT` name, database/API endpoints, log level, feature flags, resource
sizing (`task_cpu`, `task_memory`, `desired_count`), region, and anything
secret-like (API keys, DB credentials) — which shouldn't be plain env vars at
all (see Part 3).

## Part 3 — Add a Secret

Created a new [secrets.tf](secrets.tf):

```hcl
resource "aws_secretsmanager_secret" "client_id" {
  name = "${local.name_prefix}-client-id"
}

resource "aws_secretsmanager_secret_version" "client_id" {
  secret_id     = aws_secretsmanager_secret.client_id.id
  secret_string = "demo-client-id-12345"
}

resource "aws_iam_role_policy" "ecs_secrets_access" {
  name = "${local.name_prefix}-secrets-access"
  role = aws_iam_role.ecs_task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.client_id.arn
    }]
  })
}
```

Injected into the container in [compute.tf](compute.tf):

```hcl
secrets = [
  { name = "CLIENT_ID", valueFrom = aws_secretsmanager_secret.client_id.arn }
]
```

`terraform apply` created the secret, the IAM policy, and a new task
definition revision. New task launched successfully (no `CannotPullSecretError`
in `stoppedReason`), service settled at 1/1 running, ALB stayed at `200`.

**Checkpoint:** secret exists (`terraform-example-Christopher-Fan-client-id`);
ECS references it successfully; the app kept running through the deploy. ✅

### Q&A

**Why should secrets not be stored as plaintext environment variables?**
Plain `environment` values in a task definition are visible to anyone who can
call `DescribeTaskDefinition` — no special secrets permission needed — and get
versioned in plaintext with every revision, in Terraform state, and in logs.
A leaked task definition or an over-permissioned read-only IAM role exposes
the credential directly. The `secrets` block instead stores only a reference
(the secret's ARN) in the task definition; the ECS agent fetches the real
value at container-start time, gated behind a distinct
`secretsmanager:GetSecretValue` permission — so access to the value can be
audited and scoped separately from access to the task definition.

**Where is the secret value actually stored?**
In AWS Secrets Manager, encrypted at rest (default `aws/secretsmanager` KMS
key here) — not in the task definition or ECS. One caveat: `secret_string` is
still written in plaintext into `terraform.tfstate`, so protecting the state
file matters just as much as protecting the task definition.

## Part 4 — Review CloudWatch Logs

Log group: `/ecs/terraform-example-Christopher-Fan-app`. Stream naming is
`app/app/<task-id>` (from `awslogs-stream-prefix = "app"` in
[compute.tf:88](compute.tf#L88)) — one stream per task, so every restart or
deployment gets a fresh stream.

**Container startup messages** (top of stream):
```
/docker-entrypoint.sh: Configuration complete; ready for start up
2026/09/22 18:01:30 [notice] 1#1: nginx/1.29.1
2026/09/22 18:01:30 [notice] 1#1: start worker process 20
```

**Application logs** (ongoing, nginx access log):
```
10.10.17.182 - - [22/Sep/2026:18:01:44 +0000] "GET / HTTP/1.1" 200 12159 "-" "ELB-HealthChecker/2.0" "-"
```
All traffic so far is ALB health checks, all `200`.

**Recent deployment activity**: three streams present, one per task launched
across the Part 2 and Part 3 deploys.

**Checkpoint:** can locate logs for a running task; know where to look during
troubleshooting. ✅

### Q&A

**Where would you investigate a startup failure?**
The log stream for that task, but check whether it has any content at all —
if there's no entrypoint output, the failure happened before the app ran.
Check `stoppedReason` via `DescribeTasks` (ECS console → Stopped tasks) for
things like `CannotPullContainerError` or `CannotPullSecretError` — those are
ECS/infrastructure-layer failures and may produce no application logs.

**Where would you investigate an application error?**
The same log stream, further down, in the ongoing request/response lines or
app-specific error output (nginx error entries, stack traces) — as opposed to
the ECS-level task lifecycle events used for startup failures.

## Part 5 — Review Monitoring

Confirmed `CPUUtilization` datapoints exist for the service (near 0%, since
only ALB health checks are hitting it). `MemoryUtilization` and
`RunningTaskCount` are populated the same way under namespace `AWS/ECS` with
`ClusterName`/`ServiceName` dimensions.

Added one alarm in a new [monitoring.tf](monitoring.tf):

```hcl
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "${local.name_prefix}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = aws_ecs_service.app.name
  }
}
```

Verified live: `terraform-example-Christopher-Fan-high-cpu` exists, state
settled to `OK`. No SNS action attached yet — the alarm changes state but
doesn't notify anyone; that's a natural next step (`alarm_actions` → an SNS
topic) if real alerting is wanted later.

**Checkpoint:** metrics visible; alarm exists. ✅

## Part 6 — Day 3 Readiness Record

| Field | Value |
|---|---|
| AWS Account | `685306736016` |
| AWS Region | `us-west-2` |
| GitHub Repository | [Christopher-Fan-Atos/test-lab-repo](https://github.com/Christopher-Fan-Atos/test-lab-repo) |
| ECR Repository | `685306736016.dkr.ecr.us-west-2.amazonaws.com/terraform-example-christopher-fan-app` |
| ECS Cluster | `terraform-example-Christopher-Fan-cluster` |
| ECS Service | `terraform-example-Christopher-Fan-service` |
| Task Definition | family `terraform-example-Christopher-Fan-app` (revision `:4` as of Day 2) |
| CloudWatch Log Group | `/ecs/terraform-example-Christopher-Fan-app` |
| ALB URL | `http://tf-example-cfan-alb-1945165384.us-west-2.elb.amazonaws.com` |

**Open item before Day 3:** repo is initialized and pushed. GitHub Actions
will still need AWS credentials to push to ECR and update ECS. Decide between
an IAM user with access keys stored as repo secrets, or OIDC federation (no
long-lived keys, generally the better practice) — that setup is still
pending.

## Part 7 — Day 4 Readiness Check

All items verified live against AWS, not just assumed from Terraform state.

**Deployment**
- ✅ ECS Service RUNNING — `status: ACTIVE`, `running: 1 / desired: 1`
- ✅ Tasks HEALTHY — ALB target health: `healthy`
- ✅ ALB responding — `200` on `GET /`
- ✅ Logs available — confirmed in Part 4

**Configuration**
- ✅ Environment variables configured — `APP_NAME`, `ENVIRONMENT`, `AWS_REGION`
- ✅ Secret stored in Secrets Manager — `terraform-example-Christopher-Fan-client-id`
- ✅ Secret injected into ECS — `CLIENT_ID`, task launched successfully

**Monitoring**
- ✅ Metrics visible — `CPUUtilization` confirmed
- ✅ CloudWatch alarm created — state `OK`

**Troubleshooting map**
- ECS startup failures → `DescribeTasks` `stoppedReason` + top of the task's log stream
- ALB 502 errors → target group health checks + container logs around the time of the 502 (often a crashed container or wrong listening port)
- Application 500 errors → the app's own log output in the task's CloudWatch stream
- Missing environment variables → `container_definitions.environment` in the task definition
- Missing secrets → `container_definitions.secrets` + IAM execution role permissions on the secret ARN

## End-of-Day Checkpoint

- ✅ Environment variables configured
- ✅ Secrets Manager integration
- ✅ Updated Task Definition deployed
- ✅ CloudWatch logs reviewed
- ✅ CloudWatch alarm created
- ✅ Deployment information recorded
- ✅ Environment ready for Day 3 CI/CD (repo initialized; pending: AWS auth method for Actions)
- ✅ Environment ready for Day 4 Integration & Debugging

## Files added/changed today

- [compute.tf](compute.tf) — added `environment` and `secrets` blocks to the task definition
- [secrets.tf](secrets.tf) — new: Secrets Manager secret, secret version, IAM policy for execution role
- [monitoring.tf](monitoring.tf) — new: CloudWatch CPU alarm
