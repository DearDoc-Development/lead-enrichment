.PHONY: build deploy test clean layer

# Build the application
build:
	sam build

# Deploy to AWS
deploy: build
	sam deploy --guided

# Create Playwright layer
layer:
	mkdir -p layers/playwright/python
	pip install playwright -t layers/playwright/python/
	cd layers/playwright/python && python -m playwright install chromium
	cd layers/playwright && zip -r playwright-layer.zip .

# Run tests
test:
	pytest tests/ -v

# Clean build artifacts
clean:
	rm -rf .aws-sam
	rm -rf layers/playwright/python
	rm -f layers/playwright/playwright-layer.zip

# Local testing
local-api:
	sam local start-api

# Invoke orchestrator locally
invoke-orchestrator:
	sam local invoke OrchestratorFunction -e events/start_job.json

# Tail logs
logs:
	sam logs -n WorkerFunction --tail

# Quick deployment (skip confirmation)
quick-deploy: build
	sam deploy --no-confirm-changeset

# Format code
format:
	black src/ tests/

# Type checking
typecheck:
	mypy src/