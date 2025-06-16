# Operations Guide

This document provides operational procedures for managing the Lead Enrichment system in production.

## 🚀 System Status

### Current Production Configuration
- **Environment**: AWS us-east-1
- **Orchestrator**: `lead-enrichment-orchestrator` Lambda
- **Workers**: ECS Fargate on `lead-enrichment-cluster`
- **Current Task Definition**: `lead-enrichment-worker-minimal:15`
- **Schedule**: Every 6 hours via EventBridge
- **Last Updated**: June 2025

### Key Resources
```bash
# Lambda Functions
lead-enrichment-orchestrator

# ECS Resources  
Cluster: lead-enrichment-cluster
Task Definition: lead-enrichment-worker-minimal:15
Service: (auto-scaling based on queue)

# SQS Queues
lead-enrichment-job-queue
lead-enrichment-dlq

# DynamoDB Tables
lead-enrichment-results
lead-enrichment-cache  
lead-enrichment-jobs

# ECR Repository
238621222840.dkr.ecr.us-east-1.amazonaws.com/lead-enrichment:latest
```

## 🔧 Daily Operations

### Health Check Commands
```bash
# Quick system health check
aws ecs list-tasks --cluster lead-enrichment-cluster --region us-east-1
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/238621222840/lead-enrichment-job-queue \
  --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
  --region us-east-1

# Check recent logs (last 10 minutes)
aws logs tail /ecs/lead-enrichment-worker --since 10m --region us-east-1
aws logs tail /aws/lambda/lead-enrichment-orchestrator --since 10m --region us-east-1
```

### Expected Healthy Status
- **ECS Tasks**: 0-2 running (scales based on workload)
- **SQS Messages**: Usually 0, spikes during processing
- **Logs**: Regular "No messages available, continuing to poll..." messages
- **DynamoDB**: Recent entries in results table

## 📊 Monitoring & Alerts

### Key Metrics Dashboard
Create CloudWatch dashboard with these metrics:

1. **Lambda Metrics**:
   - `lead-enrichment-orchestrator` invocations
   - Duration and error rate
   - Concurrent executions

2. **ECS Metrics**:
   - Running task count
   - CPU and memory utilization
   - Task start/stop events

3. **SQS Metrics**:
   - Messages sent/received
   - Queue depth over time
   - Dead letter queue messages

4. **Application Metrics**:
   - Leads processed per hour
   - Salesforce update success rate
   - Website scraping error rate

### Recommended Alarms
```bash
# High queue depth (indicates workers not processing)
aws cloudwatch put-metric-alarm \
  --alarm-name "LeadEnrichment-HighQueueDepth" \
  --alarm-description "SQS queue has too many messages" \
  --metric-name ApproximateNumberOfMessages \
  --namespace AWS/SQS \
  --statistic Average \
  --period 300 \
  --threshold 100 \
  --comparison-operator GreaterThanThreshold

# No recent processing (indicates system down)
aws cloudwatch put-metric-alarm \
  --alarm-name "LeadEnrichment-NoRecentActivity" \
  --alarm-description "No recent log activity in workers" \
  --metric-name IncomingLogEvents \
  --namespace AWS/Logs \
  --statistic Sum \
  --period 3600 \
  --threshold 10 \
  --comparison-operator LessThanThreshold
```

## 🚨 Incident Response

### Common Issues & Quick Fixes

#### Issue: Workers Not Processing Messages
**Symptoms**: Queue depth increasing, no log activity
```bash
# Diagnosis
aws ecs list-tasks --cluster lead-enrichment-cluster --region us-east-1
aws ecs describe-tasks --cluster lead-enrichment-cluster --tasks <task-arn> --region us-east-1

# Quick Fix: Restart workers
aws ecs list-tasks --cluster lead-enrichment-cluster --region us-east-1 | \
  jq -r '.taskArns[]' | while read task; do 
    aws ecs stop-task --cluster lead-enrichment-cluster --task $task --region us-east-1
  done

# Start new workers
echo '{"limit": 1, "update_salesforce": false}' | base64 | \
aws lambda invoke --function-name lead-enrichment-orchestrator \
  --payload file:///dev/stdin response.json --region us-east-1
```

#### Issue: High Error Rate in Processing
**Symptoms**: Many failed leads in DynamoDB, error logs
```bash
# Investigate error patterns
aws logs filter-log-events \
  --log-group-name /ecs/lead-enrichment-worker \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --filter-pattern "ERROR OR Failed OR Exception" \
  --region us-east-1

# Check recent failures
aws dynamodb scan \
  --table-name lead-enrichment-results \
  --filter-expression "attribute_exists(#status) AND #status = :status" \
  --expression-attribute-names '{"#status": "status"}' \
  --expression-attribute-values '{":status": {"S": "failed"}}' \
  --region us-east-1 --limit 10
```

#### Issue: Salesforce Update Failures
**Symptoms**: Leads processed but not updated in Salesforce
```bash
# Check for Salesforce-specific errors
aws logs filter-log-events \
  --log-group-name /ecs/lead-enrichment-worker \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --filter-pattern "Salesforce OR Failed to update" \
  --region us-east-1

# Verify credentials (check Secrets Manager)
aws secretsmanager get-secret-value \
  --secret-id lead-enrichment/salesforce \
  --region us-east-1 | jq '.SecretString'
```

#### Issue: System Completely Down
**Symptoms**: No logs, no activity, no workers
```bash
# Emergency restart procedure
# 1. Check Lambda function
aws lambda invoke \
  --function-name lead-enrichment-orchestrator \
  --payload '{"limit": 1, "update_salesforce": false}' \
  response.json --region us-east-1

# 2. If Lambda fails, check IAM roles and permissions
aws iam get-role --role-name lead-enrichment-task-role
aws iam get-role --role-name lead-enrichment-execution-role

# 3. Check ECS cluster status
aws ecs describe-clusters --clusters lead-enrichment-cluster --region us-east-1

# 4. Manual worker start
aws ecs run-task \
  --cluster lead-enrichment-cluster \
  --task-definition lead-enrichment-worker-minimal:15 \
  --count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-0d2477f1e24852c0a],securityGroups=[sg-18361d5e],assignPublicIp=ENABLED}" \
  --region us-east-1
```

## 🔄 Maintenance Procedures

### Weekly Maintenance
```bash
# 1. Review system health and metrics
# 2. Check error patterns and failed leads
# 3. Verify Salesforce field updates are working
# 4. Clean up old DynamoDB entries if needed
# 5. Review AWS costs and resource usage

# Check recent job statistics
aws dynamodb scan \
  --table-name lead-enrichment-jobs \
  --filter-expression "attribute_exists(created_at)" \
  --region us-east-1 --limit 10

# Review cost optimization opportunities
aws ce get-dimension-values \
  --dimension SERVICE \
  --time-period Start=2025-06-01,End=2025-06-30 \
  --context COST_AND_USAGE
```

### Monthly Maintenance
```bash
# 1. Update dependencies and security patches
# 2. Review and optimize retry logic based on error patterns
# 3. Analyze processing success rates and bottlenecks
# 4. Clean up old CloudWatch logs
# 5. Backup configuration and update documentation

# Log retention management
aws logs put-retention-policy \
  --log-group-name /ecs/lead-enrichment-worker \
  --retention-in-days 30 \
  --region us-east-1

aws logs put-retention-policy \
  --log-group-name /aws/lambda/lead-enrichment-orchestrator \
  --retention-in-days 30 \
  --region us-east-1
```

### Quarterly Review
- Performance optimization review
- Cost analysis and optimization
- Security audit and credential rotation
- Disaster recovery testing
- Architecture review for scaling needs

## 📈 Performance Optimization

### Scaling Decisions
```bash
# Monitor queue depth trends
aws cloudwatch get-metric-statistics \
  --namespace AWS/SQS \
  --metric-name ApproximateNumberOfMessages \
  --dimensions Name=QueueName,Value=lead-enrichment-job-queue \
  --start-time $(date -d '24 hours ago' -u +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 3600 \
  --statistics Average,Maximum \
  --region us-east-1

# If consistently high queue depth, consider:
# 1. Increasing worker memory/CPU
# 2. Reducing scraping timeouts
# 3. Adding more concurrent workers
```

### Cost Optimization
```bash
# Analyze resource usage
aws ce get-cost-and-usage \
  --time-period Start=2025-06-01,End=2025-06-30 \
  --granularity MONTHLY \
  --metrics BlendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --region us-east-1

# Consider:
# - Reducing worker memory if utilization is low
# - Using Spot instances for non-critical workloads
# - Optimizing DynamoDB read/write capacity
# - Implementing more aggressive caching
```

## 🔒 Security Operations

### Credential Rotation
```bash
# Rotate Salesforce credentials
# 1. Update credentials in Salesforce
# 2. Update Secrets Manager
aws secretsmanager update-secret \
  --secret-id lead-enrichment/salesforce \
  --secret-string '{"username":"new-user","password":"new-pass","token":"new-token"}' \
  --region us-east-1

# 3. Restart workers to pick up new credentials
# 4. Test with a small batch

# Rotate OpenAI API key
aws secretsmanager update-secret \
  --secret-id lead-enrichment/openai \
  --secret-string '{"key":"new-api-key"}' \
  --region us-east-1
```

### Security Monitoring
```bash
# Monitor for suspicious activity
aws logs filter-log-events \
  --log-group-name /ecs/lead-enrichment-worker \
  --start-time $(date -d '24 hours ago' +%s)000 \
  --filter-pattern "authentication OR unauthorized OR forbidden" \
  --region us-east-1

# Check IAM access patterns
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=lead-enrichment-orchestrator \
  --start-time $(date -d '7 days ago' -u +%Y-%m-%dT%H:%M:%S) \
  --region us-east-1
```

## 📋 Deployment Procedures

### Emergency Rollback
```bash
# If current deployment is failing, rollback to previous task definition
aws ecs register-task-definition \
  --generate-cli-skeleton > rollback-template.json

# Edit rollback-template.json with previous working image
# Then register and update

aws lambda update-function-configuration \
  --function-name lead-enrichment-orchestrator \
  --environment Variables="{...,ECS_TASK_DEFINITION=lead-enrichment-worker-minimal:14}" \
  --region us-east-1
```

### Planned Deployment
```bash
# 1. Test in staging/development
# 2. Build and push new image
# 3. Create new task definition
# 4. Update orchestrator configuration
# 5. Monitor deployment
# 6. Verify with test runs

# Deployment verification
echo '{"limit": 1, "update_salesforce": false}' | base64 | \
aws lambda invoke --function-name lead-enrichment-orchestrator \
  --payload file:///dev/stdin test-response.json --region us-east-1

# Monitor logs for success
aws logs tail /ecs/lead-enrichment-worker --since 5m --region us-east-1
```

## 📞 Emergency Contacts & Escalation

### Immediate Response (< 1 hour)
- System completely down
- Data integrity issues
- Security incidents

### Standard Response (< 4 hours)
- High error rates
- Performance degradation
- Non-critical feature failures

### Planned Response (< 24 hours)
- Enhancement requests
- Configuration changes
- Routine maintenance

## 📚 Runbooks

### Daily Health Check Runbook
1. Check ECS task status
2. Verify queue is processing
3. Review error logs
4. Check recent Salesforce updates
5. Verify scheduled triggers working

### Weekly Performance Review
1. Analyze processing success rates
2. Review cost trends
3. Check error patterns
4. Verify system scaling appropriately
5. Document any issues or improvements

### Monthly System Audit
1. Security credential review
2. Performance optimization analysis
3. Cost optimization review
4. Architecture review for scaling
5. Documentation updates

---

**🚨 For urgent issues, always check CloudWatch logs first and verify basic connectivity before escalating.**