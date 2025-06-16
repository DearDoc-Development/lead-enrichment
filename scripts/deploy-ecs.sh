#!/bin/bash

# ECS Deployment Script for Lead Enrichment Workers

set -e

# Variables
AWS_REGION="us-east-1"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/lead-enrichment-worker"

echo "🚀 Deploying Lead Enrichment ECS Workers"

# Step 1: Create Secrets in AWS Secrets Manager
echo "📝 Creating secrets..."
aws secretsmanager create-secret \
    --name lead-enrichment/salesforce \
    --secret-string '{
        "username": "'"$SF_USERNAME"'",
        "password": "'"$SF_PASSWORD"'",
        "token": "'"$SF_SECURITY_TOKEN"'"
    }' \
    --region $AWS_REGION 2>/dev/null || echo "Salesforce secret already exists"

aws secretsmanager create-secret \
    --name lead-enrichment/openai \
    --secret-string '{"key": "'"$OPENAI_API_KEY"'"}' \
    --region $AWS_REGION 2>/dev/null || echo "OpenAI secret already exists"

aws secretsmanager create-secret \
    --name lead-enrichment/anthropic \
    --secret-string '{"key": "'"$ANTHROPIC_API_KEY"'"}' \
    --region $AWS_REGION 2>/dev/null || echo "Anthropic secret already exists"

# Step 2: Deploy Lambda components (orchestrator only)
echo "📦 Deploying Lambda orchestrator..."
sam build
sam deploy --no-fail-on-empty-changeset --no-confirm-changeset

# Step 3: Deploy ECS infrastructure
echo "🏗️  Deploying ECS infrastructure..."
echo "VPC ID: $VPC_ID"
echo "Subnet IDs: $SUBNET_IDS"

aws cloudformation deploy \
    --template-file ecs-service.yaml \
    --stack-name lead-enrichment-ecs \
    --parameter-overrides \
        VpcId="$VPC_ID" \
        SubnetIds="$SUBNET_IDS" \
    --capabilities CAPABILITY_NAMED_IAM

# Step 4: Build and push Docker image
echo "🐳 Building Docker image..."
docker build -t lead-enrichment-worker .

# Login to ECR
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin $ECR_REPO

# Tag and push
docker tag lead-enrichment-worker:latest $ECR_REPO:latest
docker push $ECR_REPO:latest

# Step 5: Update ECS service with new image
echo "🔄 Updating ECS service..."
aws ecs update-service \
    --cluster lead-enrichment-cluster \
    --service lead-enrichment-worker-service \
    --force-new-deployment

echo "✅ Deployment complete!"
echo ""
echo "📊 Next steps:"
echo "1. Monitor ECS tasks: aws ecs list-tasks --cluster lead-enrichment-cluster"
echo "2. View logs: aws logs tail /ecs/lead-enrichment-worker --follow"
echo "3. Check SQS queue: aws sqs get-queue-attributes --queue-url https://sqs.$AWS_REGION.amazonaws.com/$AWS_ACCOUNT_ID/lead-enrichment-serverless-job-queue --attribute-names All"