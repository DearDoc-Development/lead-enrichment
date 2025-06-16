# CLAUDE.md

This file provides comprehensive guidance to Claude Code (claude.ai/code) when working with the Lead Enrichment system.

## Project Overview

Lead Enrichment is a production-ready AWS-based system that automatically extracts business owner information from company websites and updates Salesforce with enriched data. The system runs on a hybrid architecture using AWS Lambda for orchestration and Amazon ECS Fargate for scalable worker processing.

## Build, Test, and Lint Commands

```bash
# Environment setup
python -m venv venv
source venv/bin/activate  # On macOS/Linux
# venv\Scripts\activate   # On Windows
pip install -r requirements.txt

# Install browser dependencies for web scraping
playwright install chromium

# Production monitoring and operations (use these commands)
./scripts/monitor-progress.sh --watch       # Real-time job monitoring
./scripts/check-status.sh                   # Quick system status check
./scripts/deploy-auto-shutdown.sh          # Deploy latest changes
./scripts/test-auto-shutdown.sh            # Test system functionality

# Development tools
black src/ tests/                           # Format code
isort src/ tests/                           # Sort imports
flake8 src/ tests/                          # Lint code
mypy src/                                   # Type checking

# Testing
pytest tests/                               # Run all tests
pytest tests/test_specific.py              # Run specific test
pytest -v --cov=src                        # Run with coverage

# Docker operations
docker build --platform linux/amd64 -t lead-enrichment .  # Build for ECS
docker push <ecr-repo>:latest                              # Push to ECR

# AWS deployment
./scripts/deploy-auto-shutdown.sh          # Primary deployment script
./scripts/deploy-manual.sh                 # Manual deployment steps
sam build && sam deploy                     # SAM deployment

# Monitoring and debugging
aws logs tail /ecs/lead-enrichment-worker --since 10m      # View worker logs
aws logs tail /aws/lambda/lead-enrichment-orchestrator     # View orchestrator logs
aws ecs list-tasks --cluster lead-enrichment-cluster      # Check running workers
aws sqs get-queue-attributes --queue-url <url>            # Check queue status
```

## Architecture & System Design

### High-Level Architecture

The system uses a **hybrid serverless + containerized architecture**:

1. **Orchestrator** (AWS Lambda): Coordinates jobs, fetches leads, manages workers
2. **Workers** (ECS Fargate): Process individual leads with web scraping and AI
3. **Queue** (Amazon SQS): Distributes work between orchestrator and workers
4. **Storage** (DynamoDB): Stores results, cache, and job tracking
5. **Scheduling** (EventBridge): Triggers automatic runs every 6 hours

### Core Components

**Orchestrator Lambda** (`src/orchestrator/handler.py`):
- Entry point for all job requests (manual and scheduled)
- Fetches leads from Salesforce using SOQL queries
- Creates SQS messages for each lead
- Starts ECS workers automatically
- Handles both EventBridge scheduled triggers and manual invocations

**ECS Workers** (`src/workers/enrichment_worker.py`):
- Continuously poll SQS for lead messages
- Use Playwright for web scraping (with retry logic)
- Extract information using OpenAI GPT-4 with structured prompts
- Update both standard and enriched fields in Salesforce
- Handle graceful shutdown and error recovery

**SalesforceClient Integration**:
- Uses simple-salesforce library for API interactions
- Dual field updates: standard SF fields + custom enriched fields
- Handles authentication with username/password/security token
- Only updates empty fields, never overwrites existing data

**Web Scraping Engine**:
- Playwright with Chromium browser automation
- Intelligent page discovery (contact/about pages)
- Certificate error handling and retry logic
- Progressive timeouts (20s → 30s → 40s)
- Exponential backoff for retries (1s → 2s → 4s)

**AI Extraction Pipeline**:
- OpenAI GPT-4 with structured JSON prompts
- Extracts business owner names and complete addresses
- Returns confidence scores and reasoning
- Handles "not found" cases by returning null values
- Robust validation to prevent "Not found" strings in Salesforce

### Data Flow

1. **Trigger**: EventBridge (every 6 hours) or manual Lambda invoke
2. **Orchestration**: Lambda fetches leads, creates SQS messages, starts workers
3. **Processing**: ECS workers poll SQS, scrape websites, extract data
4. **Enrichment**: AI processes scraped content to extract owner information
5. **Update**: Both standard and enriched Salesforce fields updated
6. **Storage**: Results stored in DynamoDB for tracking and caching

### Concurrency & Scaling

- **SQS Queue**: Decouples orchestrator from workers
- **ECS Auto-scaling**: Workers scale based on queue depth
- **Parallel Processing**: Multiple workers process leads concurrently
- **Rate Limiting**: Controlled by worker count and SQS visibility timeout
- **Resource Management**: Fargate provides isolated compute resources

## Important Implementation Details

### Salesforce Field Updates

The system updates **both standard and enriched fields** simultaneously:

**Standard Fields Updated**:
- `FirstName` and `LastName`
- `Street`, `City`, `State`, `PostalCode`, `Country`

**Enriched Fields Updated**:
- `Enriched_First_Name__c`, `Enriched_Last_Name__c`
- `Enriched_Street__c`, `Enriched_City__c`, etc.
- `Enriched_Full_Address__c` (comma-separated full address)

**Metadata Fields**:
- `Enrichment_Date__c`: Timestamp in Salesforce format
- `Enrichment_Confidence__c`: AI confidence score (0.0-1.0)
- `Enrichment_Source__c`: "AI_Web_Scraping"
- `Enrichment_Completed__c`: Boolean completion flag

### Error Handling & Retry Logic

**Web Scraping Retries**:
- 3 attempts with progressive timeouts (20s, 30s, 40s)
- Exponential backoff between attempts (1s, 2s, 4s)
- Certificate error handling with browser flags
- Only retries transient errors (timeouts, connection issues)

**SQS Message Handling**:
- Messages deleted only on successful processing
- Failed messages return to queue for retry
- Dead letter queue for permanently failed messages

**Graceful Error Recovery**:
- Workers handle SIGTERM for graceful shutdown
- Partial results preserved on failure
- Comprehensive error logging for debugging

### AI Integration Strategy

**Prompt Engineering**:
- Structured JSON response format required
- Explicit instructions to return null for missing data
- Business owner focus (not general employees)
- Address component extraction with validation

**Response Validation**:
- `is_valid_value()` function filters invalid responses
- Rejects "Not found", "Unknown", null, empty strings
- Only valid data reaches Salesforce updates

**Confidence Scoring**:
- AI provides confidence scores for extracted data
- Stored in Salesforce for quality assessment
- Can be used for future filtering/validation

### Docker & Deployment

**Container Architecture**:
- Built for linux/amd64 (ECS Fargate requirement)
- Includes Playwright + Chromium for web scraping
- Python 3.9 with all required dependencies
- Optimized for ECS execution environment

**ECS Configuration**:
- Fargate with 2048 CPU, 4096 MB memory
- Environment variables for AWS resources
- Secrets Manager integration for credentials
- CloudWatch logging enabled

**Deployment Pipeline**:
- Manual: `./deploy-manual.sh` script
- Automated: GitHub Actions on main branch push
- Task definition versioning for rollback capability

## Configuration Management

### Environment Variables (Required)

**AWS Resources**:
```bash
JOB_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/.../lead-enrichment-job-queue
RESULTS_TABLE=lead-enrichment-results
CACHE_TABLE=lead-enrichment-cache
JOBS_TABLE=lead-enrichment-jobs
```

**Credentials (Secrets Manager)**:
```bash
SF_USERNAME=salesforce-username
SF_PASSWORD=salesforce-password  
SF_SECURITY_TOKEN=salesforce-security-token
OPENAI_API_KEY=openai-api-key
```

**System Configuration**:
```bash
ECS_CLUSTER=lead-enrichment-cluster
ECS_TASK_DEFINITION=lead-enrichment-worker-minimal:15
ECS_SUBNETS=subnet-xxx
ECS_SECURITY_GROUP=sg-xxx
```

### Trigger Configuration

**Scheduled Execution** (Every 6 hours):
- EventBridge rule: `lead-enrichment-production-ScheduleRule`
- Automatically sets `update_salesforce: true`
- No limit on lead count (processes all available)

**Manual Execution**:
```bash
# Test with limited leads
echo '{"limit": 5, "update_salesforce": true}' | base64 | \
aws lambda invoke --function-name lead-enrichment-orchestrator \
  --payload file:///dev/stdin response.json

# Production run
echo '{"update_salesforce": true}' | base64 | \
aws lambda invoke --function-name lead-enrichment-orchestrator \
  --payload file:///dev/stdin response.json
```

## Data Models & Database Schema

### Lead Data Structure
```python
# Input from Salesforce
{
    "id": "00QPZ00000JoABC2AV",
    "name": "Info Needed",  # Often placeholder
    "company": "Acme Corp",
    "website": "https://acme.com",
    "email": "contact@acme.com",
    "phone": "(555) 123-4567",
    "address": {
        "street": "123 Main St",
        "city": "Anytown", 
        "state": "CA",
        "postal_code": "12345",
        "country": "United States"
    },
    "first_name": "Info",      # Usually placeholder
    "last_name": "Needed",     # Usually placeholder
    "title": null,
    "created_date": "2025-06-09T22:00:23.000+0000"
}
```

### Enriched Data Structure
```python
# AI Extraction Result
{
    "first_name": "John",           # Owner's actual name
    "last_name": "Smith",
    "address": {
        "street": "456 Business Ave", # Business address
        "city": "Business City",
        "state": "NY", 
        "postal_code": "67890",
        "country": "United States"
    },
    "confidence": 0.85,             # AI confidence score
    "reasoning": "Found owner information on About page"
}
```

### DynamoDB Tables

**Results Table** (`lead-enrichment-results`):
- Primary key: `lead_id` (string)
- Contains original lead data and enriched results
- Includes processing metadata and timestamps

**Cache Table** (`lead-enrichment-cache`):
- Primary key: `website` (string) 
- Stores scraped website content (24-hour TTL)
- Avoids re-scraping same websites

**Jobs Table** (`lead-enrichment-jobs`):
- Primary key: `job_id` (string)
- Tracks job progress and statistics
- Contains lead counts and processing status

## Monitoring & Debugging

### CloudWatch Logs

**Orchestrator Logs** (`/aws/lambda/lead-enrichment-orchestrator`):
```
Job created successfully and workers started
job_id: abc123, leads_found: 150, leads_queued: 150, workers_started: 2
```

**Worker Logs** (`/ecs/lead-enrichment-worker`):
```
Worker starting, polling queue: https://sqs...
Processing message for lead: 00QPZ00000JoABC2AV
Attempt 1/3 scraping https://example.com (timeout: 20000ms)
Successfully scraped https://example.com on attempt 1
Successfully updated Salesforce lead 00QPZ00000JoABC2AV with 15 fields
Successfully processed lead 00QPZ00000JoABC2AV
```

### Key Metrics to Monitor

1. **Processing Success Rate**: Ratio of successful to failed leads
2. **Salesforce Update Rate**: Leads with successful SF updates
3. **Average Processing Time**: Time per lead (should be 1-3 minutes)
4. **Queue Depth**: SQS message count (should drain to zero)
5. **Worker Health**: ECS task status and restart frequency
6. **Error Patterns**: Common failure reasons in logs

### Common Debugging Scenarios

**Workers Not Processing**:
- Check ECS task definition revision
- Verify workers are running (not stopped)
- Check SQS queue has messages
- Verify network connectivity (security groups)

**High Failure Rate**:
- Review website error patterns in logs
- Check retry attempts and reasons
- Verify Salesforce field configuration
- Monitor OpenAI API quota and errors

**Salesforce Update Failures**:
- Verify custom fields exist in Salesforce
- Check field character limits and data types
- Validate Salesforce credentials in Secrets Manager
- Review API rate limits and permissions

## Performance Optimization

### Current Performance Characteristics
- **Processing Rate**: 50-100 leads/hour (depends on website complexity)
- **Success Rate**: 60-80% (varies by website availability)
- **Concurrency**: 2-10 workers typically
- **Memory Usage**: ~4GB per worker
- **Cost**: ~$10-50/month for typical usage

### Scaling Recommendations
- **Increase Workers**: Modify ECS service desired count
- **Optimize Timeouts**: Reduce scraping timeouts for faster processing
- **Improve Caching**: Extend cache TTL for frequently scraped domains
- **Batch Processing**: Process leads in larger batches

### Cost Optimization
- **ECS Fargate**: Pay only for running time
- **Lambda**: Pay per invocation (orchestrator)
- **DynamoDB**: On-demand pricing scales with usage
- **SQS**: Very low cost for message processing

## Security & Compliance

### Credential Management
- All secrets stored in AWS Secrets Manager
- No hardcoded credentials in code
- IAM roles with least-privilege access
- Regular credential rotation recommended

### Data Handling
- Lead data processed in-memory only
- Results stored in DynamoDB with encryption
- No persistent storage of website content
- Cache has 24-hour TTL

### Network Security
- ECS tasks in private subnets with NAT gateway
- Security groups restrict access to required ports
- All external communication over HTTPS
- No inbound access to worker containers

## Troubleshooting Guide

### Quick Diagnostic Commands
```bash
# Check system status
aws ecs list-tasks --cluster lead-enrichment-cluster
aws sqs get-queue-attributes --queue-url $QUEUE_URL --attribute-names All
aws logs tail /ecs/lead-enrichment-worker --since 10m

# Test orchestrator
echo '{"limit": 1, "update_salesforce": true}' | base64 | \
aws lambda invoke --function-name lead-enrichment-orchestrator \
  --payload file:///dev/stdin test-response.json

# Check recent results
aws dynamodb scan --table-name lead-enrichment-results --limit 5
```

### Common Issues & Solutions

1. **"No workers processing messages"**
   - Solution: Check ECS task definition revision, restart workers

2. **"Certificate errors on websites"**
   - Solution: System automatically handles this with retry logic

3. **"Salesforce field not found errors"**
   - Solution: Create missing custom fields in Salesforce

4. **"High memory usage in workers"** 
   - Solution: Increase ECS memory allocation or reduce concurrency

5. **"Queue messages not being consumed"**
   - Solution: Check worker logs, verify SQS permissions

## Best Practices for Modifications

### Code Changes
1. **Always test locally** with small datasets first
2. **Use feature branches** for significant changes  
3. **Update tests** when modifying core logic
4. **Monitor logs** after deployment for issues
5. **Rollback capability** via ECS task definition versions

### Infrastructure Changes
1. **Use CloudFormation/SAM** for reproducible deployments
2. **Test in staging** environment before production
3. **Monitor costs** after scaling changes
4. **Backup configurations** before major changes
5. **Document changes** in deployment logs

### Performance Tuning
1. **Profile before optimizing** - measure actual bottlenecks
2. **Test timeout changes** with various website types
3. **Monitor error rates** when adjusting retry logic
4. **Scale gradually** - don't jump to maximum capacity
5. **Consider cost impact** of performance improvements

---

## Important Reminders for AI Assistants

1. **Always check ECS task definition revision** when deploying changes
2. **The system updates BOTH standard and enriched Salesforce fields**
3. **Retry logic is comprehensive** - don't add more retries without reason
4. **Use `is_valid_value()` function** for all Salesforce field validation
5. **Build Docker images with `--platform linux/amd64`** for ECS compatibility
6. **Test with small limits first** before processing large batches
7. **Monitor CloudWatch logs** for debugging and verification
8. **The scheduled trigger runs every 6 hours automatically**
9. **Empty fields are left empty** - never populate with "Not found"
10. **Always update both the image tag and task definition** for deployments

**The system is production-ready and handles lead enrichment automatically!**