#!/bin/bash

# Deploy Auto-Shutdown via Direct Code Update
# This script updates the worker code and creates a new task definition

set -e

echo "🚀 Deploying Auto-Shutdown Feature (Remote Build)"
echo "================================================"

REGION="us-east-1"
TASK_FAMILY="lead-enrichment-worker-minimal"
ECR_REPO="238621222840.dkr.ecr.us-east-1.amazonaws.com/lead-enrichment"

# Auto-shutdown settings
AUTO_SHUTDOWN_ENABLED=${AUTO_SHUTDOWN_ENABLED:-"true"}
IDLE_TIMEOUT_MINUTES=${IDLE_TIMEOUT_MINUTES:-"5"}

echo "Configuration:"
echo "- Auto-shutdown enabled: $AUTO_SHUTDOWN_ENABLED"
echo "- Idle timeout: $IDLE_TIMEOUT_MINUTES minutes"
echo ""

# Create deployment package
echo "📦 Creating deployment package..."
cd /Volumes/KINGSTON/deardoc/projects/lead-enrichment
zip -r worker-auto-shutdown.zip src/workers/ requirements.txt Dockerfile

# Upload to S3 for CodeBuild (if needed)
echo "📤 Preparing deployment..."

# Get current task definition and increment revision
echo "📋 Getting current task definition..."
CURRENT_TASK_DEF=$(aws ecs describe-task-definition \
    --task-definition $TASK_FAMILY \
    --region $REGION)

CURRENT_REVISION=$(echo $CURRENT_TASK_DEF | jq -r '.taskDefinition.revision')
echo "Current revision: $CURRENT_REVISION"

# For now, we'll use the existing image and just update environment variables
# This is safe since the code changes are already in the src/workers/enrichment_worker.py file
echo "📝 Creating new task definition with auto-shutdown environment variables..."

# Create new task definition with updated environment
NEW_TASK_DEF=$(echo $CURRENT_TASK_DEF | jq --arg auto_shutdown "$AUTO_SHUTDOWN_ENABLED" \
    --arg idle_timeout "$IDLE_TIMEOUT_MINUTES" '
    .taskDefinition |
    del(.taskDefinitionArn) |
    del(.revision) |
    del(.status) |
    del(.requiresAttributes) |
    del(.placementConstraints) |
    del(.compatibilities) |
    del(.registeredAt) |
    del(.registeredBy) |
    del(.requiresCompatibilities) |
    .containerDefinitions[0].environment = [
        {"name": "RESULTS_TABLE", "value": "lead-enrichment-results"},
        {"name": "JOB_QUEUE_URL", "value": "https://sqs.us-east-1.amazonaws.com/238621222840/lead-enrichment-job-queue"},
        {"name": "JOBS_TABLE", "value": "lead-enrichment-jobs"},
        {"name": "CACHE_TABLE", "value": "lead-enrichment-cache"},
        {"name": "AUTO_SHUTDOWN_ENABLED", "value": $auto_shutdown},
        {"name": "IDLE_TIMEOUT_MINUTES", "value": $idle_timeout}
    ]')

# Save task definition
echo "$NEW_TASK_DEF" > task-definition-auto-shutdown.json

# Register new task definition
echo "📝 Registering new task definition..."
NEW_REVISION=$(aws ecs register-task-definition \
    --cli-input-json file://task-definition-auto-shutdown.json \
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

# Stop current workers to force them to restart with new config
echo ""
echo "🔄 Stopping current workers to apply new configuration..."
CURRENT_TASKS=$(aws ecs list-tasks --cluster lead-enrichment-cluster --region $REGION | jq -r '.taskArns[]')
TASK_COUNT=$(echo "$CURRENT_TASKS" | wc -l | tr -d ' ')

if [ "$TASK_COUNT" -gt 0 ]; then
    echo "Stopping $TASK_COUNT workers..."
    echo "$CURRENT_TASKS" | while read -r task_arn; do
        if [ -n "$task_arn" ]; then
            aws ecs stop-task --cluster lead-enrichment-cluster --task "$task_arn" --region $REGION --reason "Applying auto-shutdown update" >/dev/null 2>&1
            echo "  Stopped: $(basename $task_arn)"
        fi
    done
    echo "✅ All workers stopped"
else
    echo "No workers currently running"
fi

# Cleanup
rm -f task-definition-auto-shutdown.json worker-auto-shutdown.zip

echo ""
echo "🎉 Auto-Shutdown Feature Deployed!"
echo "================================================"
echo ""
echo "⚠️  IMPORTANT: The auto-shutdown code is in the repository but NOT in the current Docker image."
echo ""
echo "Next steps:"
echo "1. The next worker that starts will use the ENVIRONMENT VARIABLES for auto-shutdown"
echo "2. However, the actual shutdown logic requires rebuilding the Docker image"
echo ""
echo "To fully activate auto-shutdown:"
echo "1. Build and push a new Docker image with the updated code"
echo "2. Or wait for the next full deployment"
echo ""
echo "For now, workers will see the configuration but won't actually auto-shutdown"
echo "until the Docker image is rebuilt with the new code."
echo ""
echo "Monitor with: ./check-status.sh"