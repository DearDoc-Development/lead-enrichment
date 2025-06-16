#!/bin/bash

# Deploy Enhanced Worker with Auto-Shutdown
# This script builds and deploys the worker with auto-shutdown capability

set -e

echo "🚀 Deploying Enhanced Worker with Auto-Shutdown"
echo "=============================================="

# Configuration
REGION="us-east-1"
CLUSTER="lead-enrichment-cluster"
ECR_REPO="238621222840.dkr.ecr.us-east-1.amazonaws.com/lead-enrichment"
TASK_FAMILY="lead-enrichment-worker-minimal"

# Auto-shutdown settings (can be overridden)
AUTO_SHUTDOWN_ENABLED=${AUTO_SHUTDOWN_ENABLED:-"true"}
IDLE_TIMEOUT_MINUTES=${IDLE_TIMEOUT_MINUTES:-"5"}

echo "Configuration:"
echo "- Auto-shutdown enabled: $AUTO_SHUTDOWN_ENABLED"
echo "- Idle timeout: $IDLE_TIMEOUT_MINUTES minutes"
echo ""

# Build new Docker image
echo "📦 Building Docker image..."
docker build --platform linux/amd64 -t lead-enrichment:auto-shutdown .

# Get current timestamp for tagging
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
IMAGE_TAG="auto-shutdown-$TIMESTAMP"

# Tag and push to ECR
echo "🔄 Pushing to ECR..."
docker tag lead-enrichment:auto-shutdown $ECR_REPO:$IMAGE_TAG
docker tag lead-enrichment:auto-shutdown $ECR_REPO:latest-auto-shutdown

# Login to ECR
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ECR_REPO

# Push images
docker push $ECR_REPO:$IMAGE_TAG
docker push $ECR_REPO:latest-auto-shutdown

echo "✅ Image pushed: $ECR_REPO:$IMAGE_TAG"

# Get current task definition
echo "📋 Creating new task definition..."
CURRENT_TASK_DEF=$(aws ecs describe-task-definition \
    --task-definition $TASK_FAMILY \
    --region $REGION \
    --query 'taskDefinition')

# Create new task definition with updated image and environment
NEW_TASK_DEF=$(echo $CURRENT_TASK_DEF | jq --arg image "$ECR_REPO:$IMAGE_TAG" \
    --arg auto_shutdown "$AUTO_SHUTDOWN_ENABLED" \
    --arg idle_timeout "$IDLE_TIMEOUT_MINUTES" '
    del(.taskDefinitionArn) |
    del(.revision) |
    del(.status) |
    del(.requiresAttributes) |
    del(.placementConstraints) |
    del(.compatibilities) |
    del(.registeredAt) |
    del(.registeredBy) |
    .containerDefinitions[0].image = $image |
    .containerDefinitions[0].environment += [
        {"name": "AUTO_SHUTDOWN_ENABLED", "value": $auto_shutdown},
        {"name": "IDLE_TIMEOUT_MINUTES", "value": $idle_timeout}
    ]')

# Register new task definition
echo "$NEW_TASK_DEF" > new-task-definition.json
NEW_REVISION=$(aws ecs register-task-definition \
    --cli-input-json file://new-task-definition.json \
    --region $REGION \
    --query 'taskDefinition.revision')

echo "✅ New task definition registered: $TASK_FAMILY:$NEW_REVISION"

# Update orchestrator to use new task definition
echo "🔄 Updating orchestrator to use new task definition..."
aws lambda update-function-configuration \
    --function-name lead-enrichment-orchestrator \
    --environment Variables="{
        \"RESULTS_TABLE\":\"lead-enrichment-results\",
        \"ECS_CLUSTER\":\"lead-enrichment-cluster\",
        \"JOBS_TABLE\":\"lead-enrichment-jobs\",
        \"ECS_TASK_DEFINITION\":\"$TASK_FAMILY:$NEW_REVISION\",
        \"CACHE_TABLE\":\"lead-enrichment-cache\",
        \"ECS_SUBNETS\":\"subnet-0d2477f1e24852c0a\",
        \"JOB_QUEUE_URL\":\"https://sqs.us-east-1.amazonaws.com/238621222840/lead-enrichment-job-queue\",
        \"ECS_SECURITY_GROUP\":\"sg-18361d5e\"
    }" \
    --region $REGION > /dev/null

echo "✅ Orchestrator updated"

# Cleanup
rm -f new-task-definition.json

echo ""
echo "🎉 Deployment Complete!"
echo "=============================================="
echo "New Features:"
echo "✅ Workers will auto-shutdown after $IDLE_TIMEOUT_MINUTES minutes of no work"
echo "✅ Auto-shutdown can be disabled by setting AUTO_SHUTDOWN_ENABLED=false"
echo "✅ Idle timeout is configurable via IDLE_TIMEOUT_MINUTES environment variable"
echo ""
echo "Testing:"
echo "1. Start a small job to test the new workers"
echo "2. Monitor logs to see auto-shutdown behavior"
echo "3. Workers should shut down automatically when queue is empty"
echo ""
echo "Monitor with: ./check-status.sh"
echo ""
echo "🔧 To adjust settings:"
echo "export AUTO_SHUTDOWN_ENABLED=false  # Disable auto-shutdown"
echo "export IDLE_TIMEOUT_MINUTES=10      # 10-minute timeout"
echo "./$0                                # Re-deploy with new settings"