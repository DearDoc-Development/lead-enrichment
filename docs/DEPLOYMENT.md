# Deployment Guide

## Prerequisites

1. **AWS CLI** configured with credentials
2. **AWS SAM CLI** installed
3. **Docker** installed (for building Lambda layers)
4. **Python 3.9** installed

## First-Time Setup

1. **Install AWS SAM CLI**:
   ```bash
   pip install aws-sam-cli
   ```

2. **Configure AWS credentials**:
   ```bash
   aws configure
   ```

3. **Create Playwright Layer** (one-time):
   ```bash
   make layer
   ```

## Deployment Steps

1. **Set environment variables** in `samconfig.toml`:
   ```toml
   parameter_overrides = [
       "SalesforceUsername='your-username'",
       "SalesforcePassword='your-password'", 
       "SalesforceSecurityToken='your-token'",
       "OpenAIApiKey='your-key'",
       "AnthropicApiKey='your-key'"
   ]
   ```

2. **Deploy the stack**:
   ```bash
   make deploy
   ```

   Or manually:
   ```bash
   sam build
   sam deploy --guided
   ```

3. **Note the outputs**:
   - API endpoint URL
   - API key ID (retrieve actual key from AWS Console)

## Usage

### Start a Job

```bash
curl -X POST https://your-api-endpoint/prod/jobs \
  -H "x-api-key: your-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "start_job",
    "parameters": {
      "limit": 1000,
      "created_after": "2024-01-01"
    }
  }'
```

### Check Job Status

```bash
curl -X POST https://your-api-endpoint/prod/jobs \
  -H "x-api-key: your-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "check_status",
    "job_id": "your-job-id"
  }'
```

## Cost Optimization Tips

1. **Reserved Concurrency**: Set to limit costs
   ```yaml
   ReservedConcurrentExecutions: 100
   ```

2. **Memory Optimization**: 
   - Orchestrator: 1GB
   - Worker: 2GB (for Playwright)

3. **DynamoDB On-Demand**: Pay only for usage

4. **SQS Long Polling**: Reduces API calls

## Monitoring

1. **CloudWatch Dashboard**: Auto-created with deployment
2. **X-Ray Tracing**: Enable for debugging
3. **Cost Explorer**: Monitor spending

## Scaling

To process 200,000 leads in 5 hours:

1. Increase worker concurrency:
   ```yaml
   ReservedConcurrentExecutions: 1000
   ```

2. Adjust SQS batch size:
   ```yaml
   BatchSize: 10
   ```

3. Consider multiple regions for higher limits

## Troubleshooting

### Common Issues

1. **Playwright crashes**: Increase Lambda memory to 3GB
2. **Timeouts**: Increase Lambda timeout to 900s (15 min)
3. **Rate limits**: Implement exponential backoff
4. **Cold starts**: Use provisioned concurrency

### Debug Commands

```bash
# View logs
make logs

# Test locally
make local-api

# Invoke function
make invoke-orchestrator
```