# Quick Start Guide

## Before You Deploy

### 1. Install Required Tools
```bash
# Install AWS CLI
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /

# Install AWS SAM CLI
brew install aws-sam-cli

# Install Docker (required for building Lambda layers)
# Download from https://www.docker.com/products/docker-desktop/
```

### 2. Configure AWS Credentials
```bash
aws configure
# Enter your AWS Access Key ID
# Enter your AWS Secret Access Key
# Enter default region (e.g., us-east-1)
```

### 3. Update Credentials
Edit `samconfig.toml` and add your actual credentials:
```toml
parameter_overrides = [
    "SalesforceUsername='your.email@company.com'",
    "SalesforcePassword='YourPassword'", 
    "SalesforceSecurityToken='YourSecurityToken'",
    "OpenAIApiKey='sk-...'",
    "AnthropicApiKey='sk-ant-...'"
]
```

## Deploy

### First Time Only
```bash
# Create the Playwright Lambda layer
make layer
```

### Deploy to AWS
```bash
# This will create all AWS resources
make deploy

# You'll be asked to confirm:
# - Stack Name [lead-enrichment-serverless]: (press enter)
# - AWS Region [us-east-1]: (press enter)
# - Confirm changes before deploy [Y/n]: Y
# - Allow SAM CLI IAM role creation [Y/n]: Y
# - Save parameters to samconfig.toml [Y/n]: Y
```

## After Deployment

The deployment will output:
```
Outputs:
ApiEndpoint = https://xxxxx.execute-api.us-east-1.amazonaws.com/prod/jobs
ApiKeyId = xxxxxxxxxx
```

### Get Your API Key
```bash
# Get the actual API key value
aws apigateway get-api-key --api-key <ApiKeyId> --include-value
```

## Run a Job

```bash
# Start processing 10 leads
curl -X POST https://xxxxx.execute-api.us-east-1.amazonaws.com/prod/jobs \
  -H "x-api-key: your-actual-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "start_job",
    "parameters": {
      "limit": 10,
      "created_after": "2024-01-01"
    }
  }'

# Response:
{
  "job_id": "abc123...",
  "status": "processing",
  "total_leads": 10,
  "message": "Job started successfully. Processing 10 leads."
}
```

## Check Job Status

```bash
curl -X POST https://xxxxx.execute-api.us-east-1.amazonaws.com/prod/jobs \
  -H "x-api-key: your-actual-api-key" \
  -H "Content-Type: application/json" \
  -d '{
    "action": "check_status",
    "job_id": "abc123..."
  }'

# Response:
{
  "job_id": "abc123...",
  "status": "processing",
  "total_leads": 10,
  "processed_leads": 7,
  "progress_percentage": 70.0
}
```

## View Results

Results are stored in DynamoDB. View them in AWS Console:
1. Go to DynamoDB in AWS Console
2. Find table `lead-enrichment-serverless-results`
3. Click "Explore table items"

## Common Issues

1. **"Docker not found"**: Install Docker Desktop first
2. **"No credentials found"**: Run `aws configure`
3. **"AccessDenied"**: Check your AWS IAM permissions
4. **"Invalid API Key"**: Use the actual key value, not the ID

## Clean Up

To delete all AWS resources and stop billing:
```bash
sam delete
```