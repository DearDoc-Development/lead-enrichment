# ECS Deployment Guide - Full Playwright Support

This deployment uses **AWS ECS Fargate** for workers, giving us full Playwright functionality with auto-scaling.

## Architecture

```
┌─────────────────────┐     ┌─────────────────────┐
│   Lambda            │────▶│   SQS Queue         │
│   (Orchestrator)    │     │                     │
└─────────────────────┘     └──────────┬──────────┘
                                       │
                                       ▼
┌─────────────────────┐     ┌─────────────────────┐
│   DynamoDB          │◀────│  ECS Fargate Tasks  │
│   (Results/Cache)   │     │  (Auto-scaling)     │
└─────────────────────┘     └─────────────────────┘
```

## Benefits vs Lambda

✅ **No size limits** - Full Playwright support
✅ **Better performance** - More CPU/memory available  
✅ **Auto-scaling** - 0 to 100+ workers based on queue
✅ **Cost effective** - Fargate Spot pricing (80% savings)
✅ **Full functionality** - JavaScript rendering, navigation

## Prerequisites

1. **Get your VPC details**:
```bash
# List VPCs
aws ec2 describe-vpcs --query 'Vpcs[*].[VpcId,Tags[?Key==`Name`].Value|[0]]' --output table

# List subnets (use private subnets if you have NAT Gateway)
aws ec2 describe-subnets --query 'Subnets[*].[SubnetId,VpcId,AvailabilityZone,MapPublicIpOnLaunch]' --output table
```

2. **Set environment variables**:
```bash
export VPC_ID="vpc-xxxxxxxxx"
export SUBNET_IDS="subnet-xxxxxxxx,subnet-yyyyyyyy"
export SF_USERNAME="jose.anaya@getdeardoc.com"
export SF_PASSWORD="gx4MOVHO3A.il?"
export SF_SECURITY_TOKEN="zRuoIJiosKzObes1Z5QD8xXq0"
export OPENAI_API_KEY="your-openai-key"
export ANTHROPIC_API_KEY=""
```

## Deployment Steps

### 1. Deploy Everything
```bash
./deploy-ecs.sh
```

This script will:
- Create AWS Secrets Manager entries for credentials
- Deploy Lambda orchestrator  
- Deploy ECS cluster and auto-scaling
- Build and push Docker image
- Start ECS service

### 2. Monitor Deployment
```bash
# Check ECS tasks
aws ecs list-tasks --cluster lead-enrichment-cluster

# View worker logs
aws logs tail /ecs/lead-enrichment-worker --follow

# Check queue status
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/ACCOUNT_ID/lead-enrichment-serverless-job-queue \
  --attribute-names All
```

## How It Works

### Orchestrator (Lambda)
- Runs every 6 hours (scheduled)
- Fetches leads from Salesforce  
- Sends each lead to SQS queue
- Tracks job progress

### Workers (ECS Fargate)
- **Auto-scale**: 0 to 100+ tasks based on queue depth
- **Process leads**: Full Playwright web scraping
- **AI extraction**: OpenAI/Anthropic analysis
- **Update Salesforce**: High-confidence results

### Auto-Scaling Rules
- **Scale up**: When messages appear in SQS
- **Scale down**: When queue is empty for 5+ minutes
- **Spot instances**: 80% cost savings using Fargate Spot

## Cost Estimates

**Monthly costs for 200,000 leads:**
- Lambda orchestrator: ~$5
- ECS Fargate tasks: ~$200-400
- DynamoDB: ~$25
- SQS: ~$10
- **Total: ~$250-450/month**

Compare to EC2: ~$1,000+/month

## Testing

### Manual Trigger
```bash
# Get the API endpoint from Lambda deployment output
curl -X POST https://your-api-endpoint/Prod/trigger \
  -H "Content-Type: application/json" \
  -d '{
    "action": "start_job",
    "parameters": {
      "limit": 10,
      "update_salesforce": false
    }
  }'
```

### Monitor Progress
```bash
# Watch ECS tasks scale up
watch -n 10 'aws ecs list-tasks --cluster lead-enrichment-cluster'

# Monitor queue depth
watch -n 10 'aws sqs get-queue-attributes --queue-url https://sqs.us-east-1.amazonaws.com/ACCOUNT_ID/lead-enrichment-serverless-job-queue --attribute-names ApproximateNumberOfMessages'
```

## Production Tips

1. **Use private subnets** with NAT Gateway for better security
2. **Enable task auto-scaling** based on SQS metrics
3. **Set up CloudWatch alarms** for failures
4. **Use Fargate Spot** for 80% cost savings
5. **Monitor logs** in CloudWatch for debugging

## Troubleshooting

**Tasks not starting?**
- Check VPC/subnet configuration
- Verify IAM roles have proper permissions
- Check ECR repository exists and image is pushed

**High costs?**
- Ensure auto-scaling is working (tasks scale down when idle)
- Use Fargate Spot (already configured)
- Monitor task CPU/memory usage for right-sizing

This gives you the full Playwright functionality you want with enterprise-scale auto-scaling!