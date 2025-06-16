#!/bin/bash

echo "🔧 Creating Lambda layer with REAL simple-salesforce library..."

# Clean up
rm -rf layer-real layer-real.zip

# Create layer structure
mkdir -p layer-real/python
cd layer-real/python

# Install the REAL simple-salesforce library with all dependencies
echo "📦 Installing real simple-salesforce..."
pip install simple-salesforce --target . --no-cache-dir

# List what was installed
echo "📋 Installed packages:"
ls -la

cd ..

# Create deployment package
echo "📦 Creating layer package..."
zip -r ../layer-real.zip . -x "*.pyc" "*/__pycache__/*"

cd ..

# Publish the layer
echo "🚀 Publishing real simple-salesforce layer..."
LAYER_VERSION=$(aws lambda publish-layer-version \
    --layer-name real-simple-salesforce-layer \
    --description "Real simple-salesforce library with all dependencies" \
    --zip-file fileb://layer-real.zip \
    --compatible-runtimes python3.9 python3.8 python3.7 \
    --query 'Version' --output text)

echo "✅ Real layer published as version: $LAYER_VERSION"

# Get the layer ARN
LAYER_ARN=$(aws lambda get-layer-version \
    --layer-name real-simple-salesforce-layer \
    --version-number $LAYER_VERSION \
    --query 'LayerVersionArn' --output text)

# Update the Lambda function to use real simple-salesforce
echo "🔗 Updating Lambda function to use REAL simple-salesforce..."
aws lambda update-function-configuration \
    --function-name lead-enrichment-orchestrator \
    --layers "$LAYER_ARN"

# Wait for update to complete
echo "⏳ Waiting for function update..."
sleep 15

# Test the function
echo "🧪 Testing with REAL simple-salesforce..."
aws lambda invoke \
    --function-name lead-enrichment-orchestrator \
    --payload '{}' \
    response-real.json

echo "📋 Response:"
cat response-real.json

# Clean up
rm -rf layer-real layer-real.zip

echo ""
echo "✅ Real simple-salesforce layer complete!"
echo "Layer ARN: $LAYER_ARN"
echo "Layer Version: $LAYER_VERSION"
echo ""
echo "Now using the ACTUAL simple-salesforce library that works locally!"