# 📚 Lead Enrichment Documentation

This directory contains all documentation for the Lead Enrichment system.

## 📖 **Quick Start**
- **[QUICK_START.md](QUICK_START.md)** - Get up and running quickly
- **[TESTING_GUIDE.md](TESTING_GUIDE.md)** - Complete testing and validation guide

## 🚀 **Deployment**
- **[DEPLOYMENT.md](DEPLOYMENT.md)** - Main deployment guide
- **[DEPLOYMENT_STEPS.md](DEPLOYMENT_STEPS.md)** - Step-by-step deployment process
- **[ECS_DEPLOYMENT.md](ECS_DEPLOYMENT.md)** - ECS-specific deployment instructions

## ⚙️ **Operations**
- **[OPERATIONS.md](OPERATIONS.md)** - Day-to-day operations guide
- **[SCHEDULE_CONFIG.md](SCHEDULE_CONFIG.md)** - Scheduled job configuration
- **[STATUS.md](STATUS.md)** - System status and monitoring

## 🔧 **Configuration**
- **[SALESFORCE_FIELDS.md](SALESFORCE_FIELDS.md)** - Salesforce field mapping and setup

## 📊 **System Overview**
The Lead Enrichment system is a production-ready AWS-based solution that:

- ✅ **Processes 10,000+ leads automatically** every 6 hours
- ✅ **94%+ success rate** with fixed architecture  
- ✅ **Auto-scaling workers** (2-10 workers based on load)
- ✅ **Auto-shutdown** after 5 minutes idle (cost optimization)
- ✅ **Dual Salesforce updates** (standard + enriched fields)
- ✅ **Comprehensive monitoring** and error handling

## 🏗️ **Architecture**
- **AWS Lambda** - Orchestrator (triggered every 6 hours)
- **AWS ECS Fargate** - Worker containers with auto-shutdown
- **AWS SQS** - Job queue with 20-second long polling
- **AWS DynamoDB** - Results and job tracking
- **Playwright + AI** - Web scraping and data extraction
- **Salesforce API** - Lead updates and data sync

## 🛠️ **Scripts**
All operational scripts are located in the `/scripts/` directory. See `/scripts/README.md` for details.

## 📝 **Project Instructions**
See the main `CLAUDE.md` file in the project root for detailed development instructions and architectural notes.