#!/usr/bin/env bash
set -euo pipefail

: "${CODE_CONNECTION_ARN:?set CODE_CONNECTION_ARN to your CodeConnection ARN}"
: "${REPO_URL:?set REPO_URL to the HTTPS URL of your fork, e.g. https://github.com/you/headless-claude-on-aws.git}"

STACK_NAME="${STACK_NAME:-cfn-investigator}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"

aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file investigator-stack.yml \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    "ProjectName=$STACK_NAME" \
    "CodeConnectionArn=$CODE_CONNECTION_ARN" \
    "RepoUrl=$REPO_URL"

echo
echo "Done. Now populate the two empty-shell secrets:"
echo "  aws secretsmanager put-secret-value --secret-id ${STACK_NAME}/anthropic-key --secret-string \"\$ANTHROPIC_API_KEY\""
echo "  aws secretsmanager put-secret-value --secret-id ${STACK_NAME}/github-token  --secret-string \"\$GITHUB_TOKEN\""
