#!/bin/bash

# Lead Enrichment Worker Cleanup
# Stops idle workers when queue is empty

REGION="us-east-1"
CLUSTER="lead-enrichment-cluster"

echo "======================================"
echo "WORKER CLEANUP UTILITY"
echo "$(date)"
echo "======================================"

# Check queue status first
echo ""
echo "Checking queue status..."
QUEUE_ATTRS=$(aws sqs get-queue-attributes \
    --queue-url "https://sqs.us-east-1.amazonaws.com/238621222840/lead-enrichment-job-queue" \
    --attribute-names ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible \
    --region $REGION 2>/dev/null)

MESSAGES_AVAILABLE=$(echo $QUEUE_ATTRS | jq -r '.Attributes.ApproximateNumberOfMessages // 0')
MESSAGES_IN_FLIGHT=$(echo $QUEUE_ATTRS | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // 0')
TOTAL_MESSAGES=$((MESSAGES_AVAILABLE + MESSAGES_IN_FLIGHT))

echo "Messages in queue: $TOTAL_MESSAGES"

# Get current workers
TASK_ARNS=$(aws ecs list-tasks --cluster $CLUSTER --region $REGION 2>/dev/null | jq -r '.taskArns[]')
TASK_COUNT=$(echo "$TASK_ARNS" | wc -l | tr -d ' ')

if [ -z "$TASK_ARNS" ]; then
    TASK_COUNT=0
fi

echo "Active workers: $TASK_COUNT"

if [ "$TASK_COUNT" -eq 0 ]; then
    echo "No workers to clean up."
    exit 0
fi

if [ "$TOTAL_MESSAGES" -gt 0 ]; then
    echo ""
    echo "WARNING: Queue has $TOTAL_MESSAGES messages still processing."
    echo "Not stopping workers as they may be needed."
    echo ""
    echo "If you want to force stop all workers anyway, run:"
    echo "aws ecs list-tasks --cluster $CLUSTER --region $REGION | jq -r '.taskArns[]' | xargs -I {} aws ecs stop-task --cluster $CLUSTER --task {} --region $REGION"
    exit 0
fi

echo ""
echo "Queue is empty. Safe to stop idle workers."

if [ "$1" == "--force" ] || [ "$1" == "-f" ]; then
    echo "Stopping all $TASK_COUNT workers..."
    echo "$TASK_ARNS" | while read -r task_arn; do
        if [ -n "$task_arn" ]; then
            echo "Stopping $(basename $task_arn)..."
            aws ecs stop-task --cluster $CLUSTER --task "$task_arn" --region $REGION --reason "Cleanup: Queue empty" >/dev/null 2>&1
        fi
    done
    echo "All workers stopped."
else
    echo ""
    echo "To stop all idle workers, run:"
    echo "$0 --force"
    echo ""
    echo "Or stop individual workers:"
    echo "$TASK_ARNS" | while read -r task_arn; do
        if [ -n "$task_arn" ]; then
            echo "aws ecs stop-task --cluster $CLUSTER --task $(basename $task_arn) --region $REGION"
        fi
    done
fi

echo ""
echo "======================================"