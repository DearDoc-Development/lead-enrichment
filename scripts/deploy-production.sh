#!/bin/bash

# Single Production Deployment for Lead Enrichment
# Full ECS solution with Playwright support

set -e

# Variables
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/lead-enrichment-worker"

echo "🚀 Deploying Production Lead Enrichment System"
echo "Region: $AWS_REGION"
echo "Account: $AWS_ACCOUNT_ID"

# Validate environment variables
if [ -z "$VPC_ID" ] || [ -z "$SUBNET_IDS" ]; then
    echo "❌ Error: VPC_ID and SUBNET_IDS environment variables must be set"
    echo "Example:"
    echo "export VPC_ID=\"vpc-059dd3a7e0d03658b\""
    echo "export SUBNET_IDS=\"subnet-01ca634f275aa19bd,subnet-0cd23eec1a966930a\""
    exit 1
fi

echo "VPC ID: $VPC_ID"
echo "Subnet IDs: $SUBNET_IDS"

# Step 1: Clean up any existing resources
echo "🧹 Cleaning up existing resources..."
aws cloudformation delete-stack --stack-name lead-enrichment-serverless 2>/dev/null || true
aws cloudformation delete-stack --stack-name lead-enrichment-ecs 2>/dev/null || true

echo "Waiting for cleanup to complete..."
sleep 30

# Step 2: Create/Update Secrets
echo "📝 Creating secrets..."
aws secretsmanager create-secret \
    --name lead-enrichment/salesforce \
    --secret-string '{
        "username": "'"$SF_USERNAME"'",
        "password": "'"$SF_PASSWORD"'",
        "token": "'"$SF_SECURITY_TOKEN"'"
    }' \
    --region $AWS_REGION 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id lead-enrichment/salesforce \
    --secret-string '{
        "username": "'"$SF_USERNAME"'",
        "password": "'"$SF_PASSWORD"'",
        "token": "'"$SF_SECURITY_TOKEN"'"
    }' \
    --region $AWS_REGION

aws secretsmanager create-secret \
    --name lead-enrichment/openai \
    --secret-string '{"key": "'"$OPENAI_API_KEY"'"}' \
    --region $AWS_REGION 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id lead-enrichment/openai \
    --secret-string '{"key": "'"$OPENAI_API_KEY"'"}' \
    --region $AWS_REGION

aws secretsmanager create-secret \
    --name lead-enrichment/anthropic \
    --secret-string '{"key": "'"$ANTHROPIC_API_KEY"'"}' \
    --region $AWS_REGION 2>/dev/null || \
aws secretsmanager update-secret \
    --secret-id lead-enrichment/anthropic \
    --secret-string '{"key": "'"$ANTHROPIC_API_KEY"'"}' \
    --region $AWS_REGION

# Step 3: Deploy complete infrastructure
echo "🏗️  Deploying complete infrastructure..."
aws cloudformation deploy \
    --template-file ecs-complete.yaml \
    --stack-name lead-enrichment-production \
    --parameter-overrides \
        VpcId="$VPC_ID" \
        SubnetIds="$SUBNET_IDS" \
    --capabilities CAPABILITY_NAMED_IAM

# Step 4: Build and push Docker image
echo "🐳 Building Docker image..."

# Login to ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO

# Build image
docker build -t lead-enrichment-worker .

# Tag and push
docker tag lead-enrichment-worker:latest $ECR_REPO:latest
docker push $ECR_REPO:latest

echo "✅ Production deployment complete!"
echo ""
echo "📊 Resources created:"
echo "• ECS Cluster: lead-enrichment-cluster"
echo "• DynamoDB Tables: lead-enrichment-jobs, lead-enrichment-results, lead-enrichment-cache"
echo "• SQS Queue: lead-enrichment-job-queue"
echo "• Lambda Orchestrator: lead-enrichment-orchestrator (runs every 6 hours)"
echo ""

# Get API endpoint
API_ENDPOINT=$(aws cloudformation describe-stacks \
    --stack-name lead-enrichment-production \
    --query 'Stacks[0].Outputs[?OutputKey==`ApiEndpoint`].OutputValue' \
    --output text)

echo "🌐 API Endpoint: $API_ENDPOINT"
echo ""
echo "📋 Next steps:"
echo "1. Test manual trigger:"
echo "   curl -X POST $API_ENDPOINT \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     -d '{\"action\": \"start_job\", \"parameters\": {\"limit\": 5, \"update_salesforce\": false}}'"
echo ""
echo "2. Monitor logs:"
echo "   aws logs tail /aws/lambda/lead-enrichment-orchestrator --follow"
echo "   aws logs tail /ecs/lead-enrichment-worker --follow"
echo ""
echo "3. Check job status in DynamoDB: lead-enrichment-jobs"
echo "4. View results in DynamoDB: lead-enrichment-results"