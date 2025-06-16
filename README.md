# Lead Enrichment System

A production-ready lead enrichment system that automatically extracts business owner information from company websites and updates Salesforce with enriched data.

## 🎯 What It Does

1. **Fetches leads** from Salesforce (companies with websites but missing contact info)
2. **Scrapes websites** using AI-powered browser automation
3. **Extracts owner information** (names, addresses) using GPT-4/Claude
4. **Updates Salesforce** with both standard and custom enriched fields
5. **Runs automatically** every 6 hours via scheduled triggers

## 📁 **Project Structure**

```
lead-enrichment/
├── src/                     # Source code
│   ├── orchestrator/        # Lambda orchestrator
│   └── workers/            # ECS worker containers
├── docs/                   # 📚 All documentation
│   ├── README.md          # Documentation index
│   ├── QUICK_START.md     # Getting started guide
│   ├── TESTING_GUIDE.md   # Testing procedures
│   └── ...               # Deployment, operations guides
├── scripts/               # 🔧 All operational scripts
│   ├── README.md         # Scripts index
│   ├── monitor-progress.sh # Real-time monitoring
│   ├── deploy-auto-shutdown.sh # Deployment
│   └── ...              # Testing, utility scripts
├── CLAUDE.md             # 🤖 Claude Code instructions
├── README.md            # This file
└── ...                 # Config files, templates
```

## 🚀 **Quick Start**

1. **See documentation**: `docs/QUICK_START.md`
2. **Monitor system**: `./scripts/monitor-progress.sh --watch`
3. **Check status**: `./scripts/check-status.sh`
4. **Deploy changes**: `./scripts/deploy-auto-shutdown.sh`

For detailed guides, see the `docs/` directory.

## 🏗️ Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   EventBridge   │───▶│   Orchestrator   │───▶│   SQS Queue     │
│ (Every 6 hours) │    │     Lambda       │    │ (Lead Messages) │
└─────────────────┘    └──────────────────┘    └─────────┬───────┘
                                                         │
                                  ┌─────────────────────┼─────────────────────┐
                                  ▼                     ▼                     ▼
                       ┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
                       │  ECS Worker 1   │   │  ECS Worker 2   │   │  ECS Worker N   │
                       │ - Web Scraping  │   │ - Web Scraping  │   │ - Web Scraping  │
                       │ - AI Extraction │   │ - AI Extraction │   │ - AI Extraction │
                       │ - SF Updates    │   │ - SF Updates    │   │ - SF Updates    │
                       └─────────┬───────┘   └─────────┬───────┘   └─────────┬───────┘
                                 │                     │                     │
                                 ▼                     ▼                     ▼
                              ┌──────────────────────────────────────────────────────┐
                              │                 DynamoDB Tables                     │
                              │ • Results (enriched data)  • Cache (scraped content)│
                              │ • Jobs (progress tracking) • Error logs             │
                              └──────────────────────────────────────────────────────┘
                                                         │
                                                         ▼
                                              ┌─────────────────┐
                                              │   Salesforce    │
                                              │  (Updated with  │
                                              │ enriched data)  │
                                              └─────────────────┘
```

## ✨ Key Features

### 🚀 **Production Ready**
- **Auto-scaling ECS workers** on AWS Fargate
- **Retry logic** with exponential backoff for failed websites
- **Certificate error handling** for problematic sites
- **Graceful error handling** and comprehensive logging
- **Progress tracking** and job monitoring

### 🎯 **Smart Data Extraction**
- **AI-powered extraction** using OpenAI GPT-4
- **Empty field handling** - only updates when valid data found
- **Confidence scoring** for extracted information
- **Multi-page scraping** (main page + contact/about pages)

### 🔄 **Salesforce Integration**
- **Dual field updates**: Both standard and enriched custom fields
- **Standard fields**: FirstName, LastName, Street, City, State, PostalCode, Country
- **Enriched fields**: Enriched_First_Name__c, Enriched_Last_Name__c, etc.
- **Full address field**: Enriched_Full_Address__c (comma-separated)
- **Metadata tracking**: Date, confidence, source, completion status

### 📅 **Automated Scheduling**
- **Every 6 hours** via EventBridge
- **Manual triggers** supported
- **Configurable limits** and filters

## 🛠️ Technology Stack

- **Orchestration**: AWS Lambda (Python)
- **Workers**: Amazon ECS Fargate (Docker containers)
- **Queue**: Amazon SQS
- **Database**: Amazon DynamoDB  
- **Storage**: Amazon ECR (Docker images)
- **Scheduling**: Amazon EventBridge
- **Secrets**: AWS Secrets Manager
- **Web Scraping**: Playwright (Chromium)
- **AI Extraction**: OpenAI GPT-4
- **CRM Integration**: Salesforce (simple-salesforce)

## 🚀 Quick Start

### Prerequisites
- AWS CLI configured
- Docker installed
- Salesforce credentials
- OpenAI API key

### 1. Environment Setup
```bash
# Clone repository
git clone <repository-url>
cd lead-enrichment

# Set up environment variables
export SF_USERNAME="your-salesforce-username"
export SF_PASSWORD="your-salesforce-password" 
export SF_SECURITY_TOKEN="your-salesforce-token"
export OPENAI_API_KEY="your-openai-key"
```

### 2. Deploy Infrastructure
```bash
# Deploy using SAM
sam build && sam deploy --guided

# Or use the deployment script
./deploy-manual.sh
```

### 3. Test the System
```bash
# Test with 1 lead
aws lambda invoke \
  --function-name lead-enrichment-orchestrator \
  --payload '{"limit": 1, "update_salesforce": true}' \
  response.json
```

## 🔧 Configuration

### Salesforce Custom Fields Required
Create these custom fields in your Salesforce Lead object:

**Name Fields:**
- `Enriched_First_Name__c` - Text(50)
- `Enriched_Last_Name__c` - Text(50)

**Address Fields:**
- `Enriched_Street__c` - Text(255)
- `Enriched_City__c` - Text(50)
- `Enriched_State__c` - Text(20)
- `Enriched_Postal_Code__c` - Text(20)
- `Enriched_Country__c` - Text(40)
- `Enriched_Full_Address__c` - Text(500)

**Metadata Fields:**
- `Enrichment_Date__c` - Date/Time
- `Enrichment_Confidence__c` - Number(3,2)
- `Enrichment_Source__c` - Text(50)
- `Enrichment_Completed__c` - Checkbox

### Environment Variables
```bash
# Required secrets (stored in AWS Secrets Manager)
SF_USERNAME=your-salesforce-username
SF_PASSWORD=your-salesforce-password
SF_SECURITY_TOKEN=your-salesforce-security-token
OPENAI_API_KEY=your-openai-api-key

# System configuration (in Lambda/ECS environment)
RESULTS_TABLE=lead-enrichment-results
CACHE_TABLE=lead-enrichment-cache
JOBS_TABLE=lead-enrichment-jobs
JOB_QUEUE_URL=https://sqs.us-east-1.amazonaws.com/.../lead-enrichment-job-queue
```

## 📊 Monitoring & Logs

### CloudWatch Logs
- **Orchestrator logs**: `/aws/lambda/lead-enrichment-orchestrator`
- **Worker logs**: `/ecs/lead-enrichment-worker`

### Key Metrics to Monitor
- **Success rate**: Percentage of leads successfully processed
- **Processing time**: Average time per lead
- **Error rate**: Failed leads due to website issues
- **Salesforce updates**: Number of fields updated per lead

### Example Log Messages
```
✅ Successfully scraped https://example.com on attempt 1
✅ Successfully updated Salesforce lead 00QPZ000... with 15 fields
❌ Attempt 1/3 failed for https://example.com: Timeout 20000ms exceeded
🔄 Retrying in 2 seconds...
```

## 🔄 Deployment & CI/CD

### Manual Deployment
```bash
# Quick deployment
./deploy-manual.sh
```

### GitHub Actions (Automatic)
Push to main branch triggers automatic deployment:
```yaml
# .github/workflows/deploy.yml handles:
# 1. Docker build (AMD64 architecture)
# 2. ECR push
# 3. ECS task definition update
# 4. Deployment verification
```

## 🚨 Troubleshooting

### Common Issues

**Workers not processing messages:**
- Check ECS task definition revision is latest
- Verify worker containers are running (not stopped)
- Check security groups allow outbound HTTPS

**Certificate errors:**
- System automatically retries with certificate error handling
- Logs will show retry attempts

**Salesforce update failures:**
- Verify custom fields exist in Salesforce
- Check Salesforce credentials in Secrets Manager
- Review field character limits

**High failure rate:**
- Many websites have issues (timeouts, certificates)
- System automatically retries up to 3 times
- Check logs for specific error patterns

### Useful Commands
```bash
# Check running workers
aws ecs list-tasks --cluster lead-enrichment-cluster

# View recent logs
aws logs tail /ecs/lead-enrichment-worker --since 10m

# Check queue status
aws sqs get-queue-attributes \
  --queue-url https://sqs.us-east-1.amazonaws.com/.../lead-enrichment-job-queue \
  --attribute-names All

# Manual trigger test
echo '{"limit": 5, "update_salesforce": true}' | base64 | \
aws lambda invoke --function-name lead-enrichment-orchestrator \
  --payload file:///dev/stdin response.json
```

## 📈 Performance & Scaling

### Current Capacity
- **Concurrent workers**: 2-10 (auto-scaling)
- **Processing rate**: ~50-100 leads/hour
- **Success rate**: 60-80% (depends on website availability)
- **Cost**: ~$10-50/month for typical usage

### Scaling Options
- **Increase workers**: Modify ECS service desired count
- **Faster processing**: Reduce scraping timeouts
- **More retries**: Increase retry attempts for difficult sites

## 🤝 Contributing

### Development Setup
```bash
# Local development
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Run tests
pytest tests/

# Code formatting
black src/
isort src/
flake8 src/
```

### Making Changes
1. Create feature branch
2. Make changes
3. Test locally
4. Push to GitHub (triggers auto-deployment)
5. Monitor deployment and test

---

**🎉 The system is production-ready and processes leads automatically every 6 hours!**