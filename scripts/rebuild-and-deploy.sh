#!/bin/bash

# Rebuild and Deploy with Auto-Shutdown
# This script provides the Docker commands for manual execution

set -e

echo "🐳 Docker Rebuild Commands for Auto-Shutdown Feature"
echo "=================================================="
echo ""
echo "Run these commands to rebuild and deploy:"
echo ""
echo "# 1. Build the Docker image"
echo "docker build --platform linux/amd64 -t lead-enrichment:auto-shutdown ."
echo ""
echo "# 2. Tag for ECR"
echo "docker tag lead-enrichment:auto-shutdown \\"
echo "  238621222840.dkr.ecr.us-east-1.amazonaws.com/lead-enrichment:auto-shutdown-$(date +%Y%m%d-%H%M%S)"
echo ""
echo "# 3. Login to ECR"
echo "aws ecr get-login-password --region us-east-1 | \\"
echo "  docker login --username AWS --password-stdin 238621222840.dkr.ecr.us-east-1.amazonaws.com"
echo ""
echo "# 4. Push to ECR"
echo "docker push 238621222840.dkr.ecr.us-east-1.amazonaws.com/lead-enrichment:auto-shutdown-$(date +%Y%m%d-%H%M%S)"
echo ""
echo "# 5. Update task definition (use deploy-auto-shutdown.sh after pushing)"
echo "./deploy-auto-shutdown.sh"
echo ""
echo "Note: The auto-shutdown code is already in src/workers/enrichment_worker.py"
echo "It will activate once the Docker image is rebuilt with this code."