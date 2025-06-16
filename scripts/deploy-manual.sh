#!/bin/bash

# Manual deployment script for immediate testing
# This builds and deploys the lead enrichment system to ECS

set -e

echo "🚀 Starting manual deployment..."

# AWS Configuration
AWS_REGION="us-east-1"
ECR_REPOSITORY="lead-enrichment"
ECS_CLUSTER="lead-enrichment-cluster"
ECS_TASK_DEFINITION="lead-enrichment-worker-minimal"
ACCOUNT_ID="238621222840"

# Build and push Docker image
echo "📦 Building Docker image..."
IMAGE_TAG=$(date +%Y%m%d-%H%M%S)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# Build for AMD64 (ECS Fargate requirement)
docker build --platform linux/amd64 -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}" .
docker tag "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}" "${ECR_REGISTRY}/${ECR_REPOSITORY}:latest"

echo "🔐 Logging into ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${ECR_REGISTRY}

echo "⬆️ Pushing image to ECR..."
docker push "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"
docker push "${ECR_REGISTRY}/${ECR_REPOSITORY}:latest"

echo "📋 Registering new ECS task definition..."
NEW_REVISION=$(aws ecs register-task-definition \
  --family ${ECS_TASK_DEFINITION} \
  --network-mode awsvpc \
  --requires-compatibilities FARGATE \
  --cpu 2048 \
  --memory 4096 \
  --task-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/lead-enrichment-task-role" \
  --execution-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/lead-enrichment-execution-role" \
  --container-definitions '[
    {
      "name": "worker",
      "image": "'${ECR_REGISTRY}'/'${ECR_REPOSITORY}':'${IMAGE_TAG}'",
      "essential": true,
      "environment": [
        {"name": "JOB_QUEUE_URL", "value": "https://sqs.us-east-1.amazonaws.com/'${ACCOUNT_ID}'/lead-enrichment-job-queue"},
        {"name": "RESULTS_TABLE", "value": "lead-enrichment-results"},
        {"name": "CACHE_TABLE", "value": "lead-enrichment-cache"},
        {"name": "JOBS_TABLE", "value": "lead-enrichment-jobs"}
      ],
      "secrets": [
        {"name": "SF_USERNAME", "valueFrom": "arn:aws:secretsmanager:'${AWS_REGION}':'${ACCOUNT_ID}':secret:lead-enrichment/salesforce:username::"},
        {"name": "SF_PASSWORD", "valueFrom": "arn:aws:secretsmanager:'${AWS_REGION}':'${ACCOUNT_ID}':secret:lead-enrichment/salesforce:password::"},
        {"name": "SF_SECURITY_TOKEN", "valueFrom": "arn:aws:secretsmanager:'${AWS_REGION}':'${ACCOUNT_ID}':secret:lead-enrichment/salesforce:token::"},
        {"name": "OPENAI_API_KEY", "valueFrom": "arn:aws:secretsmanager:'${AWS_REGION}':'${ACCOUNT_ID}':secret:lead-enrichment/openai:key::"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/lead-enrichment-worker",
          "awslogs-region": "'${AWS_REGION}'",
          "awslogs-stream-prefix": "ecs"
        }
      }
    }
  ]' \
  --region ${AWS_REGION} \
  --query 'taskDefinition.revision' \
  --output text)

echo "✅ Created task definition revision: ${NEW_REVISION}"

# Test the deployment
echo "🧪 Testing deployment..."
TASK_ARN=$(aws ecs run-task \
  --cluster ${ECS_CLUSTER} \
  --task-definition "${ECS_TASK_DEFINITION}:${NEW_REVISION}" \
  --count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-0d2477f1e24852c0a],securityGroups=[sg-18361d5e],assignPublicIp=ENABLED}" \
  --region ${AWS_REGION} \
  --query 'tasks[0].taskArn' \
  --output text)

echo "🔄 Started test task: ${TASK_ARN}"

# Wait and check status
sleep 45
TASK_STATUS=$(aws ecs describe-tasks \
  --cluster ${ECS_CLUSTER} \
  --tasks ${TASK_ARN} \
  --region ${AWS_REGION} \
  --query 'tasks[0].lastStatus' \
  --output text)

echo "📊 Task status: ${TASK_STATUS}"

if [ "$TASK_STATUS" = "RUNNING" ]; then
  echo "✅ Deployment test successful!"
  
  # Queue a test job
  echo "🔥 Running single lead test..."
  echo '{"limit": 1, "update_salesforce": true}' | base64 > /tmp/test-deploy.b64
  aws lambda invoke \
    --function-name lead-enrichment-orchestrator \
    --payload file:///tmp/test-deploy.b64 \
    --region ${AWS_REGION} \
    response.json
  
  echo "📝 Test job queued. Check logs with:"
  echo "aws logs tail /ecs/lead-enrichment-worker --since 5m --region ${AWS_REGION}"
  
  # Stop test task after 2 minutes
  sleep 120
  aws ecs stop-task --cluster ${ECS_CLUSTER} --task ${TASK_ARN} --region ${AWS_REGION}
  echo "🛑 Stopped test task"
  
else
  echo "❌ Deployment test failed!"
  
  # Get error details
  STOPPED_REASON=$(aws ecs describe-tasks \
    --cluster ${ECS_CLUSTER} \
    --tasks ${TASK_ARN} \
    --region ${AWS_REGION} \
    --query 'tasks[0].stoppedReason' \
    --output text)
  
  echo "Error: ${STOPPED_REASON}"
  exit 1
fi

echo "🎉 Deployment completed!"
echo "📦 Image: ${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"
echo "📋 Task Definition: ${ECS_TASK_DEFINITION}:${NEW_REVISION}"