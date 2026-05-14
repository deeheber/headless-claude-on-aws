# cfn-investigator

A CodeBuild project that runs Claude Code headlessly to investigate a failing CloudFormation stack in the same AWS account. The agent reads stack state and (optionally) the commit suspected of causing the failure, then writes a short markdown analysis to CloudWatch Logs. A commented-out placeholder in the buildspec shows how to ship the analysis on to Slack, Discord, Teams, SES, SNS, or whatever surface you prefer.

Blog post: _(coming soon)_

## Why this exists

This is a purposefully simplified version of something I built at work. I had fun building this monstrosity of YAML and shell to do stuff with AI, but it is **not best practice** and not what a textbook reference architecture would look like.

As the sole DevOps engineer on the project, I optimized for shipping a working prototype with the tools I already knew well. The newer managed options listed [further down](#what-you-might-want-instead) would let you skip most of this YAML. They didn't exist (or weren't mature) when I built the original.

## Why these choices, at the time

### Why the Anthropic API directly, not Amazon Bedrock

I wanted to use an Anthropic API token and avoid the Bedrock-hosted-Claude limitations laid out in [_Amazon Bedrock Leaves Builders Stuck in 1st Gear_](https://www.proactiveops.io/archive/amazon-bedrock-leaves-builders-stuck-in-1st-gear/). That's why this repo uses an `anthropic-key` secret instead of an IAM-authed Bedrock call.

### Why CodeBuild, not Lambda

Honestly: Lambda's 15-minute timeout gets cited a lot, but it isn't the binding constraint here. The longest investigation I've watched run was around 7 minutes. The bigger friction is everywhere else:

- **No real shell out of the box.** The buildspec leans on `bash` with `pipefail`, `jq`, `gh`, `python3`, `npm install -g @anthropic-ai/claude-code`, and `uvx` for the MCP proxy. In Lambda I'd have to bake all of that into a container image and rebuild it every time a tool version bumped. CodeBuild's `aws/codebuild/standard:8.0` image ships with everything, and `runtime-versions: nodejs: 24, python: 3.13` is a one-line version pin.
- **MCP servers are stdio subprocesses.** Lambda allows subprocesses but caps you at 1,024 processes and 1,024 file descriptors ([Lambda quotas](https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-limits.html)). In Lambda you'd also need to bake the MCP proxy into a container image or pay a cold-start fetch on every invocation. In CodeBuild it's a one-line `uv tool install`.
- **Live log streaming is built in.** Stream-JSON output from Claude lands as live log lines you can `aws logs tail --follow` or watch in the CodeBuild console. Lambda batches its log output, so you don't get the same per-event view as the agent works.
- **The mental model fits.** CodeBuild's idiom is "clone source, run a script, post somewhere." That *is* the investigator. Lambda inverts the lifecycle: the function is the long-lived artifact and the source is baked in at deploy time, so iterating on the prompt or buildspec equivalent means a redeploy instead of a git push.
- **Familiarity is a real engineering trade-off.** I knew CodeBuild well, and time-to-working-prototype was the priority. Picking the stack you already understand is a legitimate call, especially for an internal tool with a small audience.

### Why not Fargate

Fargate tasks must live in a VPC. To reach `api.anthropic.com`, `api.github.com`, and the AWS APIs the MCP server hits, you'd need a public subnet with a public IP assignment or a private subnet with a NAT gateway. VPC endpoints can cover the AWS-side calls but not the third-party endpoints. For a single on-demand "investigate this stack" job, the networking surface is more than the workload deserves. CodeBuild runs outside a VPC by default and can reach everything it needs with no networking setup.

## What you might want instead

A few things I haven't tried yet but want to look at before writing more YAML next time. They either didn't exist or weren't mature when I built the original:

- [Claude on AWS](https://aws.amazon.com/about-aws/whats-new/2026/05/claude-platform-aws/), Anthropic's platform offering on AWS.
- [Claude Managed Agents](https://platform.claude.com/docs/en/managed-agents/overview).
- [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview).

## What the stack creates

| Resource | Purpose |
|---|---|
| `AWS::CodeBuild::Project` | Where the agent runs. `BUILD_GENERAL1_SMALL`, `aws/codebuild/standard:8.0`, 20-minute timeout. |
| `AWS::IAM::Role` (build) | CodeBuild service role. Has only what the *build itself* needs: write its own logs, read the two secrets, use the CodeConnection, `sts:AssumeRole` on the read-only role. |
| `AWS::IAM::Role` (read-only) | Role the *agent* assumes via the AWS MCP server. AWS-managed `ReadOnlyAccess` attached. Trust policy allows only the build role to assume it. |
| `AWS::SecretsManager::Secret` × 2 | Empty shells for `anthropic-key` and `github-token`. Populate manually after deploy. |
| `AWS::Logs::LogGroup` | `/aws/codebuild/cfn-investigator`, 30-day retention. |

## Prerequisites

- One AWS account, with a CLI or SSO session.
- **A CodeConnection** to your fork of this repo. CodeBuild uses it to clone the investigator's buildspec, system prompt, and MCP config at the start of each build. Scope the connection to this repo only.
- **An Anthropic API key.** Goes into the `anthropic-key` secret.
- **A GitHub personal access token (fine-grained, read-only)** on the _app_ repo whose CloudFormation stack is failing, NOT on the investigator repo. The agent uses this to `gh api repos/<owner>/<repo>/commits/<sha>` and pull the diff of the change that broke the deploy. If you'll be investigating stacks deployed from multiple app repos, the PAT needs read access to all of them. If you don't plan to pass `REPO`/`COMMIT_SHA` at start-build time (you're fine with the agent only looking at CFN events plus AWS state, no Git correlation), this secret can be left empty.

## Deploy

```bash
CODE_CONNECTION_ARN=arn:aws:codeconnections:us-east-1:123456789012:connection/abcd... \
REPO_URL=https://github.com/you/headless-claude-on-aws.git \
./deploy.sh
```

This provisions the CodeBuild project, both IAM roles, the log group, and the two empty-shell secrets.

## Populate the two secrets

The CloudFormation template creates the secrets but does **not** know their values. That keeps secret material out of CFN parameter history, change sets, and CloudTrail. Populate them manually after deploy, either via the Secrets Manager console or via CLI:

```bash
aws secretsmanager put-secret-value --secret-id cfn-investigator/anthropic-key --secret-string "$ANTHROPIC_API_KEY"
aws secretsmanager put-secret-value --secret-id cfn-investigator/github-token  --secret-string "$GITHUB_TOKEN"
```

The GitHub PAT is for the **app repo** whose CFN stack is being investigated (the one you'll pass as `REPO` at `start-build` time), not the investigator repo. Fine-grained, read-only on contents + metadata is plenty.

## Kicking off the investigator

```bash
aws codebuild start-build \
  --project-name cfn-investigator \
  --environment-variables-override \
    name=STACK_NAME,value=<your-broken-stack-name>,type=PLAINTEXT \
    name=REPO,value=<owner>/<repo>,type=PLAINTEXT \
    name=COMMIT_SHA,value=<sha-that-caused-the-failure>,type=PLAINTEXT
```

`STACK_NAME` is the only required env var. `REPO` and `COMMIT_SHA` are optional but recommended. Without them the agent works off CloudFormation events and AWS state only and can't correlate the failure with the diff that caused it.

To test changes from a feature branch before merging, add `--source-version <branch>` as a top-level flag. That overrides the branch CodeBuild clones for the investigator repo itself (not the app repo being investigated).

**In a real setup, you wouldn't run this by hand.** The point of the investigator is to fire automatically when a deploy breaks. A few common ways to wire that up (out of scope for this repo, but worth pointing at):

- An EventBridge rule matching `CloudFormation Stack Status Change` events filtered on `detail.status-details.status` in `(CREATE_FAILED, ROLLBACK_IN_PROGRESS, UPDATE_ROLLBACK_IN_PROGRESS, UPDATE_FAILED)`, with a Lambda target that pulls the stack name + (if available) the commit SHA from your pipeline and calls `codebuild:StartBuild` with the right env vars.
- A CodePipeline failure notification (via SNS or EventBridge) into a Lambda that does the same.
- A CodeBuild pipeline-stage failure rule, same shape.
- An SSM parameter "kill-switch" the trigger Lambda reads on each invocation, so you can pause automated runs during incidents without redeploying. Not in this repo because there's no auto-trigger here; the pattern lives in the trigger Lambda, not in the investigator stack.

## Watching results, and shipping somewhere

Stream the build live:

```bash
aws logs tail /aws/codebuild/cfn-investigator --follow
```

…or watch in the CodeBuild console. The final analysis lands between `===== Investigator analysis =====` markers in the post-build log.

To push it elsewhere, uncomment the Slack placeholder in `buildspec.yml` (post_build phase) and swap in your own surface: Discord/Teams webhook, an SNS topic that fans out to email/SMS, SES, a custom webhook, etc. Wiring it up means:

1. Add the relevant secret (e.g., `slack-bot-token`) to `investigator-stack.yml` + `env.secrets-manager` in `buildspec.yml`.
2. Pass per-build env vars (channel ID, webhook URL) at `start-build` time.
3. Uncomment the placeholder.

## Notes on what this demo skips

Four things to know:

- **`ReadOnlyAccess` is broad.** The agent role uses AWS-managed `ReadOnlyAccess` for simplicity. In a real setup, scope it down to just the services the agent actually needs to read for CFN troubleshooting (`cloudformation`, `lambda`, `ecs`, `ecr`, `logs`, IAM read-only, etc.). Easy to tighten; left broad here for readability.
- **The two-role split scopes the AWS MCP server's identity, but it does not sandbox the agent in this topology.** What the split enforces is that the AWS MCP server only ever sees a `ReadOnlyAccess` identity, so AWS calls *routed through MCP* are bounded by that role. What it does *not* enforce is process-level isolation: Claude runs in the same container and shell as the build, so the agent can read env-var secrets directly, or hit the container-metadata endpoint at `169.254.170.2` to pick up the build role's credentials and call any API the build role is allowed to (including `secretsmanager:GetSecretValue` on the two secrets, and `codeconnections:UseConnection`). Same-shell topology means you're trusting the agent at the build-role level, period. The role-split shape becomes a real boundary cross-account, where the build role's only useful permission is `sts:AssumeRole` into the agent role in a different account, and there's no in-account secret or connection for the agent to recover.
- **`credential_source = EcsContainer` is mainly ergonomic.** It lets the SDK pull the CodeBuild service role's creds from the container-metadata endpoint (`169.254.170.2`) and use them as the source for the `AssumeRole` call. Compared to the older pattern of `aws sts assume-role` plus a `~/.aws/credentials` heredoc, this is one config-file write instead of four jq-extracts, both identities stay available (no profile = build role, `AWS_PROFILE=investigator` = read-only role), and the SDK handles credential refresh automatically. Cross-account works identically. Only `role_arn` and the target trust policy change.
- **Tool versions are installed at runtime, not baked into an image.** Every build runs `npm install -g @anthropic-ai/claude-code`, `pip install uv`, and `uv tool install mcp-proxy-for-aws` fresh. For a low-frequency on-demand tool that's fine. The install time is small enough not to matter, and you always get current versions. In a production setup where the investigator fires often, you'd bake the tools into a custom CodeBuild image (pushed to ECR), pin versions, and drop the runtime installs. Trade-off: image maintenance (rebuilds when tools update, lifecycle policies, etc.) for faster and more deterministic builds.
- **The MCP server endpoint is hardcoded.** `.mcp.json` points at `aws-mcp.us-east-1.api.aws` and passes `AWS_REGION=us-east-1` as metadata. The AWS MCP server is currently GA in two regions (`us-east-1` and `eu-central-1`), so the endpoint URL is constrained to one of those. The `AWS_REGION` metadata is independent: it tells the server which region to operate in, and can be set to any region regardless of the endpoint. To investigate stacks outside `us-east-1`, change the `AWS_REGION=...` metadata in `.mcp.json` to the target region.
