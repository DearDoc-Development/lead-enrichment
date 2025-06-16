#\!/bin/bash

# Lead Enrichment Progress Monitor
# This script monitors the current lead enrichment job progress

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# AWS Region
REGION="us-east-1"

# Function to print section headers
print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  $1${NC}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

# Function to get latest job
get_latest_job() {
    aws dynamodb scan \
        --table-name lead-enrichment-jobs \
        --region $REGION \
        --limit 10 \
        --scan-filter '{
            "created_at": {
                "ComparisonOperator": "NOT_NULL"
            }
        }' \
        --projection-expression "job_id,created_at,#s,leads_found,leads_queued,workers_started" \
        --expression-attribute-names '{"#s": "status"}' \
        2>/dev/null | \
    jq -r '.Items | sort_by(.created_at.S) | reverse | .[0]'
}

# Main monitoring function
main() {
    clear
    printf "${BOLD}${GREEN}🔍 LEAD ENRICHMENT PROGRESS MONITOR${NC}\n"
    printf "   $(date)\n"
    
    # Get latest job
    LATEST_JOB=$(get_latest_job)
    
    if [ -z "$LATEST_JOB" ] || [ "$LATEST_JOB" = "null" ]; then
        echo -e "${RED}❌ No jobs found in limited scan${NC}"
        echo ""
        echo -e "${YELLOW}Checking for any historical jobs...${NC}"
        LATEST_JOB=$(aws dynamodb scan \
            --table-name lead-enrichment-jobs \
            --region $REGION \
            2>/dev/null | \
        jq -r '.Items | sort_by(.created_at.S) | reverse | .[0]')
        
        if [ -z "$LATEST_JOB" ] || [ "$LATEST_JOB" = "null" ]; then
            echo -e "${RED}❌ No jobs found at all!${NC}"
            echo ""
            echo -e "${YELLOW}You can start a new job with:${NC}"
            echo -e "${BLUE}echo '{\"limit\": 5, \"update_salesforce\": true}' | base64 | \\${NC}"
            echo -e "${BLUE}aws lambda invoke --function-name lead-enrichment-orchestrator \\${NC}"
            echo -e "${BLUE}  --payload file:///dev/stdin response.json --region us-east-1${NC}"
            exit 1
        else
            echo -e "${YELLOW}Found historical job (may be completed)${NC}"
        fi
    fi
    
    JOB_ID=$(echo $LATEST_JOB | jq -r '.job_id.S')
    JOB_STATUS=$(echo $LATEST_JOB | jq -r '.status.S')
    LEADS_FOUND=$(echo $LATEST_JOB | jq -r '.leads_found.N // 0')
    LEADS_QUEUED=$(echo $LATEST_JOB | jq -r '.leads_queued.N // 0')
    WORKERS_STARTED=$(echo $LATEST_JOB | jq -r '.workers_started.N // 0')
    CREATED_AT=$(echo $LATEST_JOB | jq -r '.created_at.S')
    
    print_header "📋 JOB INFORMATION"
    echo -e "Job ID:          ${YELLOW}$JOB_ID${NC}"
    echo -e "Status:          ${GREEN}$JOB_STATUS${NC}"
    echo -e "Created:         $CREATED_AT"
    echo -e "Leads Found:     ${BOLD}$LEADS_FOUND${NC}"
    echo -e "Leads Queued:    ${BOLD}$LEADS_QUEUED${NC}"
    echo -e "Workers Started: ${BOLD}$WORKERS_STARTED${NC}"
    
    # Get queue status
    print_header "📊 QUEUE STATUS"
    QUEUE_ATTRS=$(aws sqs get-queue-attributes \
        --queue-url "https://sqs.us-east-1.amazonaws.com/238621222840/lead-enrichment-job-queue" \
        --attribute-names All \
        --region $REGION 2>/dev/null)
    
    MESSAGES_AVAILABLE=$(echo $QUEUE_ATTRS | jq -r '.Attributes.ApproximateNumberOfMessages // 0')
    MESSAGES_IN_FLIGHT=$(echo $QUEUE_ATTRS | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // 0')
    
    echo -e "Messages Waiting:     ${YELLOW}$MESSAGES_AVAILABLE${NC}"
    echo -e "Messages Processing:  ${GREEN}$MESSAGES_IN_FLIGHT${NC}"
    echo -e "Total Remaining:      ${BOLD}$((MESSAGES_AVAILABLE + MESSAGES_IN_FLIGHT))${NC}"
    
    # Calculate progress
    if [ "$LEADS_QUEUED" -gt 0 ]; then
        PROCESSED=$((LEADS_QUEUED - MESSAGES_AVAILABLE - MESSAGES_IN_FLIGHT))
        PROGRESS=$((PROCESSED * 100 / LEADS_QUEUED))
        echo ""
        echo -e "Progress:             ${GREEN}$PROCESSED / $LEADS_QUEUED${NC} (${BOLD}$PROGRESS%${NC})"
        
        # Progress bar
        echo -n "["
        FILLED=$((PROGRESS / 2))
        for i in $(seq 1 50); do
            if [ $i -le $FILLED ]; then
                echo -n "█"
            else
                echo -n "░"
            fi
        done
        echo "]"
    fi
    
    # Get worker status
    print_header "👷 WORKER STATUS"
    TASKS=$(aws ecs list-tasks --cluster lead-enrichment-cluster --region $REGION 2>/dev/null)
    TASK_COUNT=$(echo $TASKS | jq '.taskArns | length')
    
    echo -e "Active Workers: ${GREEN}$TASK_COUNT${NC}"
    
    if [ "$TASK_COUNT" -gt 0 ]; then
        echo ""
        echo "Recent Worker Activity:"
        aws logs tail /ecs/lead-enrichment-worker \
            --since 30s \
            --region $REGION 2>/dev/null | \
        grep -E "(Successfully updated|Successfully processed|Failed|Error)" | \
        tail -5 | \
        while IFS= read -r line; do
            if [[ $line == *"Successfully"* ]]; then
                echo -e "  ${GREEN}✓${NC} ${line##*] }"
            else
                echo -e "  ${RED}✗${NC} ${line##*] }"
            fi
        done
    fi
    
    # Get processing stats
    print_header "📈 PROCESSING STATISTICS"
    
    # Count recent results
    RECENT_RESULTS=$(aws dynamodb query \
        --table-name lead-enrichment-results \
        --index-name job_id-index \
        --key-condition-expression "job_id = :jobid" \
        --expression-attribute-values "{\":jobid\":{\"S\":\"$JOB_ID\"}}" \
        --select COUNT \
        --region $REGION 2>/dev/null | jq -r '.Count // 0')
    
    echo -e "Results Saved: ${GREEN}$RECENT_RESULTS${NC}"
    
    # Get success/failure counts from logs (last 5 minutes)
    echo ""
    echo "Recent Processing Rates (last 5 min):"
    
    SUCCESS_COUNT=$(aws logs filter-log-events \
        --log-group-name /ecs/lead-enrichment-worker \
        --start-time $(($(date +%s)*1000 - 300000)) \
        --filter-pattern "Successfully processed" \
        --region $REGION 2>/dev/null | jq '.events | length' || echo 0)
    
    FAILURE_COUNT=$(aws logs filter-log-events \
        --log-group-name /ecs/lead-enrichment-worker \
        --start-time $(($(date +%s)*1000 - 300000)) \
        --filter-pattern "Failed to process" \
        --region $REGION 2>/dev/null | jq '.events | length' || echo 0)
    
    echo -e "  Successful: ${GREEN}$SUCCESS_COUNT${NC}"
    echo -e "  Failed:     ${RED}$FAILURE_COUNT${NC}"
    
    if [ $((SUCCESS_COUNT + FAILURE_COUNT)) -gt 0 ]; then
        SUCCESS_RATE=$((SUCCESS_COUNT * 100 / (SUCCESS_COUNT + FAILURE_COUNT)))
        echo -e "  Success Rate: ${BOLD}$SUCCESS_RATE%${NC}"
    fi
    
    # Estimate completion time
    if [ "$MESSAGES_IN_FLIGHT" -gt 0 ] && [ "$SUCCESS_COUNT" -gt 0 ]; then
        RATE_PER_MIN=$((SUCCESS_COUNT / 5))
        if [ "$RATE_PER_MIN" -gt 0 ]; then
            REMAINING=$((MESSAGES_AVAILABLE + MESSAGES_IN_FLIGHT))
            MINUTES_LEFT=$((REMAINING / RATE_PER_MIN))
            echo ""
            echo -e "Estimated Time Remaining: ${YELLOW}~$MINUTES_LEFT minutes${NC}"
        fi
    fi
    
    print_header "💡 QUICK COMMANDS"
    echo "Watch live logs:"
    echo -e "  ${BLUE}aws logs tail /ecs/lead-enrichment-worker --since 5m --region us-east-1 --follow${NC}"
    echo ""
    echo "Check specific job:"
    echo -e "  ${BLUE}aws dynamodb get-item --table-name lead-enrichment-jobs --key '{\"job_id\": {\"S\": \"$JOB_ID\"}}' --region us-east-1${NC}"
    echo ""
    echo "Stop all workers:"
    echo -e "  ${BLUE}aws ecs list-tasks --cluster lead-enrichment-cluster --region us-east-1 | jq -r '.taskArns[]' | xargs -I {} aws ecs stop-task --cluster lead-enrichment-cluster --task {} --region us-east-1${NC}"
    
    echo ""
    echo -e "${BOLD}Press Ctrl+C to exit. Refreshing in 30 seconds...${NC}"
}

# Continuous monitoring loop
if [ "$1" == "--watch" ] || [ "$1" == "-w" ]; then
    while true; do
        main
        sleep 30
        clear
    done
else
    main
    echo ""
    echo -e "${YELLOW}Tip: Use '$0 --watch' for continuous monitoring${NC}"
fi
