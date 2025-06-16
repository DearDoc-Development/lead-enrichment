# Complete Deployment Steps

## Prerequisites (One-time Setup)

### 1. Install Required Tools
```bash
# Install AWS CLI (if not already installed)
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /

# Install AWS SAM CLI
brew install aws-sam-cli

# Verify installations
aws --version
sam --version
```

### 2. Configure AWS Account
```bash
# Configure AWS credentials
aws configure
# Enter:
# - AWS Access Key ID
# - AWS Secret Access Key  
# - Default region (e.g., us-east-1)
# - Default output format (json)
```

### 3. Create Salesforce Custom Fields
In Salesforce Setup, create these custom fields on the Lead object:
- `Enriched_First_Name__c` (Text, 50 chars)
- `Enriched_Last_Name__c` (Text, 50 chars)
- `Enriched_Street__c` (Text, 255 chars)
- `Enriched_City__c` (Text, 40 chars)
- `Enriched_State__c` (Text, 20 chars)
- `Enriched_Postal_Code__c` (Text, 20 chars)
- `Enriched_Country__c` (Text, 40 chars)
- `Enrichment_Date__c` (DateTime)
- `Enrichment_Confidence__c` (Number, 2 decimal places)
- `Enrichment_Source__c` (Text, 50 chars)

## Deployment Steps

### 1. Navigate to Project Directory
```bash
cd /path/to/lead-enrichment-serverless
```

### 2. Update Configuration
Edit `samconfig.toml` with your credentials:
```toml
parameter_overrides = [
    "SalesforceUsername='your.email@company.com'",
    "SalesforcePassword='YourPassword'", 
    "SalesforceSecurityToken='YourSecurityToken'",
    "OpenAIApiKey='sk-...'",
    "AnthropicApiKey='sk-ant-...'"
]
```

### 3. Create Playwright Layer (First Time Only)
```bash
make layer
# This creates the Lambda layer with Playwright and Chromium
# Takes 5-10 minutes the first time
```

### 4. Deploy to AWS
```bash
make deploy
```

You'll see prompts:
- **Stack Name** `[lead-enrichment-serverless]`: Press Enter
- **AWS Region** `[us-east-1]`: Press Enter or choose your region
- **Confirm changes** `[Y/n]`: Y
- **Allow SAM CLI IAM role creation** `[Y/n]`: Y
- **Save parameters** `[Y/n]`: Y

### 5. Note the Outputs
After deployment, you'll see:
```
Outputs:
OrchestratorFunction = lead-enrichment-serverless-orchestrator
ManualTriggerEndpoint = https://xxxxx.execute-api.us-east-1.amazonaws.com/Prod/trigger
JobsTable = lead-enrichment-serverless-jobs
ResultsTable = lead-enrichment-serverless-results
ScheduleStatus = Every 6 hours (rate(6 hours))
```

## Testing the Deployment

### 1. Test Manual Trigger (Optional)
```bash
# Test with a small batch first
curl -X POST https://xxxxx.execute-api.us-east-1.amazonaws.com/Prod/trigger \
  -H "Content-Type: application/json" \
  -d '{
    "action": "start_job",
    "parameters": {
      "limit": 5,
      "update_salesforce": false,
      "created_after": "2024-01-01"
    }
  }'
```

Expected response:
```json
{
  "job_id": "abc123-def456-...",
  "status": "processing", 
  "total_leads": 5,
  "message": "Job started successfully. Processing 5 leads."
}
```

### 2. Monitor Job Progress
```bash
# Check job status
curl -X POST https://xxxxx.execute-api.us-east-1.amazonaws.com/Prod/trigger \
  -H "Content-Type: application/json" \
  -d '{
    "action": "check_status",
    "job_id": "abc123-def456-..."
  }'
```

### 3. View Logs
```bash
# Watch orchestrator logs
aws logs tail /aws/lambda/lead-enrichment-serverless-orchestrator --follow

# Watch worker logs  
aws logs tail /aws/lambda/lead-enrichment-serverless-worker --follow
```

### 4. Check Results in AWS Console
1. Go to **DynamoDB** in AWS Console
2. Find table `lead-enrichment-serverless-results`
3. Click **"Explore table items"**
4. View enriched lead data

### 5. Verify Salesforce Updates (if enabled)
Check your Salesforce leads for the new enriched fields being populated.

## Schedule Verification

The system will now run automatically every 6 hours. To verify:

1. **CloudWatch Events**: Go to AWS Console > CloudWatch > Events > Rules
2. Find rule `lead-enrichment-serverless-OrchestratorFunctionScheduledEvent-...`
3. Check it's **Enabled** and shows schedule `rate(6 hours)`

## Monitoring

### CloudWatch Dashboards
- Go to **CloudWatch** > **Dashboards**
- Find `lead-enrichment-serverless-monitoring`
- View Lambda metrics, SQS metrics, and performance data

### Cost Monitoring  
- Go to **Cost Explorer** in AWS Console
- Filter by service: Lambda, DynamoDB, SQS
- Set up billing alerts if desired

## Common Issues & Solutions

### Issue: "Docker not found"
**Solution**: Install Docker Desktop from docker.com

### Issue: "AccessDenied" errors
**Solution**: Ensure your AWS user has admin permissions or these specific permissions:
- Lambda full access
- DynamoDB full access  
- SQS full access
- CloudWatch Events full access
- IAM role creation

### Issue: Playwright crashes in Lambda
**Solution**: The layer should handle this, but if issues persist, increase Lambda memory to 3GB

### Issue: No leads being processed
**Solution**: 
1. Check your Salesforce query matches leads with websites
2. Verify leads have been created recently
3. Check CloudWatch logs for errors

## Clean Up (if needed)
To delete all resources and stop billing:
```bash
sam delete
```

## Next Steps After Deployment

1. **Monitor first few runs** via CloudWatch logs
2. **Adjust schedule** if needed (edit template.yaml)
3. **Scale up concurrency** if processing too slowly
4. **Set up alerts** for failures or high costs