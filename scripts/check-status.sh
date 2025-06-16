#\!/bin/bash

# Lead Enrichment Status Checker
# Simple script to check current job status

REGION="us-east-1"

echo "======================================"
echo "LEAD ENRICHMENT STATUS CHECK"
echo "$(date)"
echo "======================================"

# Get latest job
echo ""
echo "LATEST JOB:"
LATEST_JOB=$(aws dynamodb scan \
    --table-name lead-enrichment-jobs \
    --region $REGION \
    --limit 50 \
    --projection-expression "job_id,created_at,#s,leads_found,leads_queued,workers_started" \
    --expression-attribute-names '{"#s": "status"}' \
    2>/dev/null | jq -r '.Items | sort_by(.created_at.S) | reverse | .[0]')

if [ -z "$LATEST_JOB" ] || [ "$LATEST_JOB" = "null" ]; then
    echo "No jobs found in scan results!"
    echo ""
    echo "Checking for any historical jobs..."
    LATEST_JOB=$(aws dynamodb scan \
        --table-name lead-enrichment-jobs \
        --region $REGION \
        2>/dev/null | jq -r '.Items | sort_by(.created_at.S) | reverse | .[0]')
    
    if [ -z "$LATEST_JOB" ] || [ "$LATEST_JOB" = "null" ]; then
        echo "No jobs found at all!"
        echo ""
        echo "You can start a new job with:"
        echo "echo '{\"limit\": 5, \"update_salesforce\": true}' | base64 | \\"
        echo "aws lambda invoke --function-name lead-enrichment-orchestrator \\"
        echo "  --payload file:///dev/stdin response.json --region us-east-1"
        exit 1
    else
        echo "Found historical job (may be completed)"
    fi
fi

JOB_ID=$(echo $LATEST_JOB | jq -r '.job_id.S')
echo "Job ID:          $JOB_ID"
echo "Status:          $(echo $LATEST_JOB | jq -r '.status.S')"
echo "Created:         $(echo $LATEST_JOB | jq -r '.created_at.S')"
echo "Leads Found:     $(echo $LATEST_JOB | jq -r '.leads_found.N // 0')"
echo "Leads Queued:    $(echo $LATEST_JOB | jq -r '.leads_queued.N // 0')"
echo "Workers Started: $(echo $LATEST_JOB | jq -r '.workers_started.N // 0')"

# Get queue status
echo ""
echo "QUEUE STATUS:"
QUEUE_ATTRS=$(aws sqs get-queue-attributes \
    --queue-url "https://sqs.us-east-1.amazonaws.com/238621222840/lead-enrichment-job-queue" \
    --attribute-names All \
    --region $REGION 2>/dev/null)

MESSAGES_AVAILABLE=$(echo $QUEUE_ATTRS | jq -r '.Attributes.ApproximateNumberOfMessages // 0')
MESSAGES_IN_FLIGHT=$(echo $QUEUE_ATTRS | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // 0')

echo "Messages Waiting:    $MESSAGES_AVAILABLE"
echo "Messages Processing: $MESSAGES_IN_FLIGHT"
echo "Total Remaining:     $((MESSAGES_AVAILABLE + MESSAGES_IN_FLIGHT))"

# Calculate progress
LEADS_QUEUED=$(echo $LATEST_JOB | jq -r '.leads_queued.N // 0')
if [ "$LEADS_QUEUED" -gt 0 ]; then
    PROCESSED=$((LEADS_QUEUED - MESSAGES_AVAILABLE - MESSAGES_IN_FLIGHT))
    PROGRESS=$((PROCESSED * 100 / LEADS_QUEUED))
    echo ""
    echo "Progress: $PROCESSED / $LEADS_QUEUED ($PROGRESS%)"
fi

# Get worker status
echo ""
echo "WORKER STATUS:"
TASK_COUNT=$(aws ecs list-tasks --cluster lead-enrichment-cluster --region $REGION 2>/dev/null | jq '.taskArns | length')
echo "Active Workers: $TASK_COUNT"

# Recent activity
echo ""
echo "RECENT ACTIVITY (last minute):"
aws logs tail /ecs/lead-enrichment-worker --since 1m --region $REGION 2>/dev/null | \
    grep -E "(Successfully processed|Failed to process)" | \
    tail -5

# Check specific job results
echo ""
echo "RESULTS FOR THIS JOB:"
RESULTS_COUNT=$(aws dynamodb query \
    --table-name lead-enrichment-results \
    --index-name job_id-index \
    --key-condition-expression "job_id = :jobid" \
    --expression-attribute-values "{\":jobid\":{\"S\":\"$JOB_ID\"}}" \
    --select COUNT \
    --region $REGION 2>/dev/null | jq -r '.Count // 0')

echo "Results saved: $RESULTS_COUNT"

echo ""
echo "======================================"
echo "Commands:"
echo "- Watch logs:  aws logs tail /ecs/lead-enrichment-worker --since 5m --region us-east-1 --follow"
echo "- Stop all:    aws ecs list-tasks --cluster lead-enrichment-cluster --region us-east-1 | jq -r '.taskArns[]' | xargs -I {} aws ecs stop-task --cluster lead-enrichment-cluster --task {} --region us-east-1"
echo "======================================"
