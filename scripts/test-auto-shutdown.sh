#!/bin/bash

# Test Auto-Shutdown Feature
# This script tests the worker auto-shutdown functionality

echo "🧪 Testing Auto-Shutdown Feature"
echo "================================="

REGION="us-east-1"

echo "1. Starting a small test job..."
echo '{"limit": 2, "update_salesforce": false}' | base64 | \
aws lambda invoke --function-name lead-enrichment-orchestrator \
  --payload file:///dev/stdin test-response.json --region $REGION

if [ $? -eq 0 ]; then
    echo "✅ Test job started"
    echo "Response: $(cat test-response.json)"
else
    echo "❌ Failed to start test job"
    exit 1
fi

echo ""
echo "2. Waiting for workers to start (30 seconds)..."
sleep 30

echo ""
echo "3. Checking worker status..."
WORKER_COUNT=$(aws ecs list-tasks --cluster lead-enrichment-cluster --region $REGION | jq '.taskArns | length')
echo "Active workers: $WORKER_COUNT"

if [ "$WORKER_COUNT" -eq 0 ]; then
    echo "❌ No workers started. Check the deployment."
    exit 1
fi

echo ""
echo "4. Monitoring worker logs for auto-shutdown behavior..."
echo "   (Press Ctrl+C to stop monitoring)"
echo ""

# Monitor logs for auto-shutdown messages
aws logs tail /ecs/lead-enrichment-worker --since 30s --region $REGION --follow | \
grep -E "(auto-shutdown|Auto-shutdown|idle timeout|shutting down|processed.*leads)"

echo ""
echo "Test complete! Workers should have shut down automatically after processing."
echo ""
echo "To verify workers stopped:"
echo "aws ecs list-tasks --cluster lead-enrichment-cluster --region us-east-1"

# Cleanup
rm -f test-response.json