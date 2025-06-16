# Schedule Configuration

## Current Schedule: Every 6 Hours

The orchestrator Lambda runs automatically every 6 hours and:
1. Fetches new leads created since the last run
2. Automatically updates Salesforce with enriched data (confidence > 70%)
3. Processes up to 1000 leads per run

## Batch Processing

- **1 lead per worker**: Each Lambda worker processes exactly 1 lead
- **Up to 100 concurrent workers**: Maximum 100 leads processed simultaneously  
- **Salesforce updates**: Automatic updates for high-confidence results (>70%)

## Schedule Options

### Change Schedule Frequency

Edit `template.yaml` and modify the schedule:

```yaml
Events:
  ScheduledEvent:
    Type: Schedule
    Properties:
      Schedule: rate(1 hour)    # Every hour
      # OR
      Schedule: rate(12 hours)  # Every 12 hours
      # OR  
      Schedule: cron(0 9 * * ? *) # Daily at 9 AM UTC
```

### Common Schedule Patterns

- `rate(1 hour)` - Every hour
- `rate(6 hours)` - Every 6 hours (current)
- `rate(1 day)` - Daily
- `cron(0 9 * * ? *)` - Daily at 9 AM UTC
- `cron(0 9 * * MON-FRI *)` - Weekdays at 9 AM UTC
- `cron(0 */4 * * ? *)` - Every 4 hours

### Disable Automatic Schedule

To disable automatic runs, set `Enabled: false`:

```yaml
Events:
  ScheduledEvent:
    Type: Schedule
    Properties:
      Schedule: rate(6 hours)
      Enabled: false  # Disable automatic runs
```

## Manual Triggers

You can still trigger jobs manually via API:

```bash
curl -X POST https://your-api-endpoint/Prod/trigger \
  -H "Content-Type: application/json" \
  -d '{
    "action": "start_job", 
    "parameters": {
      "limit": 100,
      "update_salesforce": true
    }
  }'
```

## Monitoring Scheduled Runs

View scheduled executions in:
1. **CloudWatch Logs**: `/aws/lambda/lead-enrichment-serverless-orchestrator`
2. **CloudWatch Events**: See all scheduled triggers
3. **DynamoDB Jobs Table**: Track job history and status

## Cost Impact

**Every 6 hours = 4 runs per day:**
- If 100 new leads per run: 400 leads/day
- Monthly cost: ~$20-40 for 12,000 leads
- Yearly cost: ~$240-480 for 144,000 leads

**Hourly runs = 24 runs per day:**
- If 50 new leads per run: 1,200 leads/day  
- Monthly cost: ~$60-120 for 36,000 leads

## Salesforce Custom Fields

The worker updates these custom fields in Salesforce:
- `Enriched_First_Name__c`
- `Enriched_Last_Name__c` 
- `Enriched_Street__c`
- `Enriched_City__c`
- `Enriched_State__c`
- `Enriched_Postal_Code__c`
- `Enriched_Country__c`
- `Enrichment_Date__c`
- `Enrichment_Confidence__c`
- `Enrichment_Source__c`

**Note**: You'll need to create these custom fields in Salesforce before deployment.