# Day 3 — CI/CD Pipelines with GitHub Actions (NGINX Edition)

Git push → GitHub Actions → ECR → ECS Fargate → ALB, replacing Day 2's manual
`docker pull` / `tag` / `push` / `terraform apply` sequence with two workflows.

## Part 1 — Review the Existing Deployment

| Resource | Value |
|---|---|
| ECR Repository | `685306736016.dkr.ecr.us-west-2.amazonaws.com/terraform-example-christopher-fan-app` |
| ECS Cluster | `terraform-example-Christopher-Fan-cluster` |
| ECS Service | `terraform-example-Christopher-Fan-service` |
| Task Definition | family `terraform-example-Christopher-Fan-app` (revision `:4` at the start of today) |
| ALB Endpoint | http://tf-example-cfan-alb-1945165384.us-west-2.elb.amazonaws.com |

Confirmed live: `describe-services` showed `status: ACTIVE`, `running: 1/1`; the
ALB returned `200`.

**Checkpoint:** Day 2 deployment healthy before touching anything. ✅

### Q&A

**What ECR repository is being used?**
`685306736016.dkr.ecr.us-west-2.amazonaws.com/terraform-example-christopher-fan-app`.

**What ECS service is running the container?**
`terraform-example-Christopher-Fan-service`.

**What public endpoint is currently deployed?**
http://tf-example-cfan-alb-1945165384.us-west-2.elb.amazonaws.com/.

## Part 2 — Configure GitHub Secrets and Variables

An IAM user's access key/secret key were used for AWS auth (OIDC federation
was considered first — no long-lived keys — but the lab's checklist called
for `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` specifically, so access keys
were used instead; see "Decisions" below).

Set via `gh secret set` (values entered directly by the user in their own
terminal, never pasted into this session):
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

Set via `gh variable set` (non-sensitive, safe to script):
- `AWS_REGION` = `us-west-2`
- `AWS_ACCOUNT_ID` = `685306736016`
- `ECR_REPOSITORY` = `terraform-example-christopher-fan-app`
- `ECS_CLUSTER` = `terraform-example-Christopher-Fan-cluster`
- `ECS_SERVICE` = `terraform-example-Christopher-Fan-service`

**Checkpoint:** secrets and variables both exist (`gh secret list` /
`gh variable list`); nothing credential-shaped was ever committed. ✅

### Q&A

**Which values are secrets?**
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` — anything that grants access on
its own.

**Which values are variables?**
`AWS_REGION`, `AWS_ACCOUNT_ID`, `ECR_REPOSITORY`, `ECS_CLUSTER`,
`ECS_SERVICE` — identifiers/config useful to know but that grant no access by
themselves.

**Why should AWS credentials never be stored in source code?**
Source history is durable and widely readable — this repo is public. A key
committed once stays retrievable from git history even after later deletion,
is copied into every clone/fork, and gets scraped by automated
credential-scanners within minutes of a public push. GitHub Secrets are
encrypted at rest, injected only into the running job's environment, masked
in logs, and never appear in a diff or clone.

## Part 3 — Create a Deployment Workflow

Created [.github/workflows/deploy.yml](.github/workflows/deploy.yml),
triggered on `push` to `develop`. Started minimal (checkout only) to confirm
it registers, then built out in later parts.

**Checkpoint:** workflow file exists; `gh workflow list` shows `Deploy` as
`active`. ✅

### Q&A

**What event triggers the workflow?** `push`.

**Which branch triggers deployment?** `develop`.

## Part 4 — Pull and Publish the Public Image

Extended the workflow: `configure-aws-credentials` (access keys from Secrets,
region from Variables) → `amazon-ecr-login` → pull `nginxdemos/hello:plain-text`
→ tag as `<registry>/<ECR_REPOSITORY>:<github.sha>` → push.

**Checkpoint:** new image appeared in ECR tagged with the commit SHA
(`acda65f7...`); workflow completed successfully. ✅

### Q&A

**What public image was pulled?** `nginxdemos/hello:plain-text`.

**What ECR repository received the image?**
`terraform-example-christopher-fan-app`.

**Why must the image be retagged before push?**
Docker resolves push/pull targets by full reference
(`registry/repository:tag`). The public image's reference points at Docker
Hub, not this private ECR repo — pushing without retagging would either fail
outright or have no private destination to go to. Retagging attaches a
second reference, pointing at
`<account>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>`, to the same image
bytes; that's the reference `docker push` actually uses.

## Part 5 — Deploy ECS Automatically

Added to the workflow: look up the service's current task definition ARN,
download it, swap in the new image
(`aws-actions/amazon-ecs-render-task-definition`), then register the new
revision and update the service
(`aws-actions/amazon-ecs-deploy-task-definition`, `wait-for-service-stability:
true`) — the automated equivalent of Day 2's manual `terraform apply` /
`aws ecs update-service --force-new-deployment`.

The wait step took ~7-8 minutes end-to-end on the first real run (old task
draining + ALB deregistration + new task startup) — not stuck, just the
`aws ecs wait services-stable` waiter polling on its own ~15s interval while
the real rollout ran its course, confirmed by cross-checking
`describe-services` (`rolloutState: COMPLETED`) against the still-"in
progress" GitHub Actions step.

**Checkpoint:** ECS deployment ran automatically off the `develop` push; new
task (revision `:5`) reached healthy/steady state; service stayed available
throughout (new task registered and confirmed healthy in the target group
before the old one drained). ✅

### Q&A

**What triggered the deployment?** The `git push` to `develop`.

**Which ECS service was updated?** `terraform-example-Christopher-Fan-service`.

**How can you confirm deployment completion?**
The workflow's own `wait-for-service-stability` step, or independently,
`aws ecs describe-services` → `rolloutState: COMPLETED` and the service
events ending in "has reached a steady state".

## Part 6 — Verify Deployment

`curl` against the ALB DNS name returned the `nginxdemos/hello` plain-text
body (server address/name, date, URI, unique request ID) at `200`.

**Checkpoint:** endpoint responds; deployment confirmed end-to-end. ✅

### Q&A

**What URL was tested?**
http://tf-example-cfan-alb-1945165384.us-west-2.elb.amazonaws.com/.

**Which AWS resource receives the request first?**
The ALB (`aws_lb.main`) — the only resource with a public listener open to
`0.0.0.0/0`.

**Where is the container running?**
An ECS Fargate task in a public subnet, reachable only via the ALB's target
group — the container's security group accepts traffic only from the ALB's
security group, not the internet directly.

## Part 7 — Create a Pull Request Validation Workflow

Created [.github/workflows/pr-check.yml](.github/workflows/pr-check.yml),
triggered on `pull_request` (any branch). Lints workflow YAML with
`raven-actions/actionlint`; no AWS credentials, no deploy steps.

Verified with a real PR (#1, `test-pr-validation` → `develop`, later merged):
`PR Validation` ran and passed on the `pull_request` event; no `Deploy` run
was ever triggered by it — every `Deploy` run in that window traced back to a
`push` event on `develop` instead.

**Checkpoint:** PRs trigger checks; deployments do not occur as a side
effect. ✅

### Q&A

**Why should PRs be validated?**
To catch breakage — a malformed workflow file, bad YAML, a typo'd action
reference — before it reaches a branch that can deploy, rather than only
discovering it mid-deployment.

**Why should PRs not automatically deploy?**
A PR's contents aren't yet reviewed or trusted, and can be opened by anyone
(including from a fork). Auto-deploying on PR would let unreviewed code push
images and update a live ECS service. Deployment should require an explicit,
reviewed merge, not just the act of proposing a change.

## Part 8 — Trigger a Deployment

Made a small README update, committed, and pushed to `develop`.

That push landed close behind another push (Part 7's `pr-check.yml` comment
commit) — both triggered `Deploy` runs, and they raced: the second run's
`update-service` call superseded the first mid-rollout, and ECS's deployment
circuit breaker reported the first run's deployment gone
(`Deployment ecs-svc/... not found after stabilization`). Live ECS state was
unaffected (the later run completed and left the service healthy), but this
would keep happening on any two quick pushes to `develop`.

**Fix:** added a `concurrency` group to `deploy.yml`
(`group: deploy-${{ github.ref }}`, `cancel-in-progress: false`) so overlapping
pushes to the same branch queue instead of racing. Verified with a follow-up
push that ran alone, start to finish, without incident.

**Checkpoint:** pipeline completes successfully; ECS deployment completes
successfully; endpoint remains available throughout. ✅ (after the
concurrency fix — the first attempt is the counterexample recorded above.)

## Part 9 — Pipeline Troubleshooting

| Scenario | Where to look |
|---|---|
| Workflow failed | GitHub Actions run → job → the specific failed step's log (`gh run view --log-failed`). This is exactly how the Part 8 race condition was diagnosed — the failure was isolated to the "wait for stability" step, everything above it had passed. |
| Image doesn't appear in ECR | `Log in to Amazon ECR` step (auth), `docker tag` output (bad reference), `docker push` output (`denied`/`not authorized` → IAM policy gap); ground truth via `aws ecr describe-images`. |
| Deployment completed but endpoint fails | `aws ecs describe-services` (`status`, `rolloutState`) → `aws ecs describe-tasks` (`stoppedReason`, per Day 2's gotchas) → target group health check status in the EC2 console (a task can be `RUNNING` in ECS yet still `unhealthy` in the target group). |
| ALB returns 502 | Match container port (`var.container_port` = `80`) against the task definition's `portMappings.containerPort` and the container security group's ingress rule; then CloudWatch Logs (`/ecs/terraform-example-Christopher-Fan-app`) to see whether the container started, crashed, or is listening on the wrong port. |

## Part 10 — Day 4 Readiness Record

| Field | Value |
|---|---|
| AWS Account ID | `685306736016` |
| AWS Region | `us-west-2` |
| GitHub Repository | [Christopher-Fan-Atos/test-lab-repo](https://github.com/Christopher-Fan-Atos/test-lab-repo) |
| ECR Repository | `685306736016.dkr.ecr.us-west-2.amazonaws.com/terraform-example-christopher-fan-app` |
| ECS Cluster | `terraform-example-Christopher-Fan-cluster` |
| ECS Service | `terraform-example-Christopher-Fan-service` |
| Current Image Tag | commit SHA of the latest push to `develop` (see `git log develop` for the current HEAD) |
| Task Definition | family `terraform-example-Christopher-Fan-app`, revision advances by 1 on every push to `develop` |
| CloudWatch Log Group | `/ecs/terraform-example-Christopher-Fan-app` |
| ALB URL | http://tf-example-cfan-alb-1945165384.us-west-2.elb.amazonaws.com/ |

### Reflection

**Which steps are now automated?**
Everything after the `git push`: pulling the image, tagging it uniquely,
authenticating to ECR, pushing, rendering the task definition, registering a
new revision, updating the service, and waiting for the rollout to
stabilize. The only manual step left is the push itself.

**What benefits does automation provide?**
Consistency, unique traceable artifacts per change (SHA tags instead of a
reused `:v1`), no personal AWS credentials on a laptop, and an audit trail —
every deploy is a logged run tied to a commit. It also surfaces failure
modes a manual process wouldn't (the Part 8 race condition) in a way that's
fixable once, rather than an occasional confusing manual mistake.

**Where would you troubleshoot a failed deployment?**
GitHub Actions run log → `aws ecs describe-services`/`describe-tasks` →
CloudWatch Logs → target group health checks — same order as Part 9.

**What AWS services were involved?**
IAM, ECR, ECS/Fargate, Elastic Load Balancing (ALB + target group),
CloudWatch Logs, and the underlying VPC networking — the same Day 1-2 stack,
now driven by GitHub Actions instead of a personal CLI session.

## End-of-Day Checkpoint

- ✅ `deploy.yml` created — pull, tag, push, deploy, wait-for-stability, on
  every push to `develop`
- ✅ `pr-check.yml` created — lints workflow files on every PR, never deploys
- ✅ GitHub Secrets configured — `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`
- ✅ GitHub Variables configured — `AWS_REGION`, `AWS_ACCOUNT_ID`,
  `ECR_REPOSITORY`, `ECS_CLUSTER`, `ECS_SERVICE`
- ✅ Automated ECR push
- ✅ Automated ECS deployment
- ✅ Successful deployment from a `git push` (twice — once cleanly after the
  concurrency fix)
- ✅ Public ALB endpoint responding
- ✅ Pipeline troubleshooting map recorded (Part 9)
- ✅ Day 4 readiness record filled in (Part 10)
- ✅ `main` fast-forwarded to `develop` so both branches carry the full
  pipeline; the demo PR (#1) merged rather than discarded, since its only
  content was a real (if small) documentation improvement

## Decisions and deviations worth flagging

- **Access keys over OIDC:** OIDC federation was set up first (an IAM role
  trusting `token.actions.githubusercontent.com`, scoped to this repo) since
  this is a public repository and OIDC avoids any long-lived credential
  existing at all. Part 2's explicit checklist called for
  `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` secrets instead, so the OIDC
  Terraform was removed unused and an existing IAM user's access key was used
  per the lab's instructions. Worth reconsidering for a non-lab environment.
- **Concurrency bug found during Part 8**, not before: two pushes landing
  within the same rollout window raced their `ecs update-service` calls. Fixed
  with a `concurrency` group on `deploy.yml`; flagged in case Day 4's
  integration work depends on assuming deploys are always sequential.

## Files added/changed today

- [.github/workflows/deploy.yml](.github/workflows/deploy.yml) — new:
  pull/tag/push to ECR, render + deploy new ECS task definition, wait for
  stability, concurrency-guarded per branch
- [.github/workflows/pr-check.yml](.github/workflows/pr-check.yml) — new:
  lints workflow files on pull requests, no AWS access
- [README.md](README.md) — noted the Day 3 pipeline is live
- GitHub repo config — 2 secrets, 5 variables (not tracked in git)
