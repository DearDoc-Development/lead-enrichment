#!/usr/bin/env python3
"""
Quick fix for orchestrator to limit ECS workers to maximum of 10.
This patches the deployed Lambda function.
"""

import json
import os
import uuid
import boto3
from datetime import datetime, timezone
from typing import Dict, List, Any

# AWS clients
sqs = boto3.client('sqs')
dynamodb = boto3.resource('dynamodb')
ecs = boto3.client('ecs')

# Environment variables
JOB_QUEUE_URL = os.environ['JOB_QUEUE_URL']
JOBS_TABLE = os.environ['JOBS_TABLE']
RESULTS_TABLE = os.environ['RESULTS_TABLE']
ECS_CLUSTER = os.environ['ECS_CLUSTER']
ECS_TASK_DEFINITION = os.environ['ECS_TASK_DEFINITION']
ECS_SUBNETS = os.environ['ECS_SUBNETS']
ECS_SECURITY_GROUP = os.environ['ECS_SECURITY_GROUP']

# DynamoDB tables
jobs_table = dynamodb.Table(JOBS_TABLE)
results_table = dynamodb.Table(RESULTS_TABLE)

def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler for orchestration with ECS worker management.
    """
    try:
        print(f"Event received: {event}")
        
        # Get Salesforce credentials from Secrets Manager
        import boto3
        secrets_client = boto3.client('secretsmanager')
        
        try:
            sf_secret = secrets_client.get_secret_value(SecretId='lead-enrichment/salesforce')
            sf_creds = json.loads(sf_secret['SecretString'])
            os.environ['SF_USERNAME'] = sf_creds['username']
            os.environ['SF_PASSWORD'] = sf_creds['password']
            os.environ['SF_SECURITY_TOKEN'] = sf_creds['token']
        except Exception as e:
            print(f"Error getting Salesforce credentials: {e}")
            # Fall back to environment variables if they exist
        
        # Check if this is a scheduled event
        if event.get('source') == 'aws.events':
            print("Triggered by scheduled event")
            # Use no limit for scheduled runs (process all available leads)
            default_params = {
                'update_salesforce': True,
                'limit': 10000  # Process up to 10k leads per run, but limit workers
            }
            return start_enrichment_job(default_params)
        
        # Handle manual invocations (direct payload or from base64)
        # Check for base64 encoded payload first
        if isinstance(event, str):
            try:
                import base64
                decoded_event = base64.b64decode(event).decode('utf-8')
                event = json.loads(decoded_event)
            except:
                pass
        
        # Extract parameters
        limit = event.get('limit')
        update_salesforce = event.get('update_salesforce', False)
        
        params = {
            'update_salesforce': update_salesforce
        }
        if limit:
            params['limit'] = limit
            
        return start_enrichment_job(params)
        
    except Exception as e:
        print(f"Error in orchestrator: {str(e)}")
        import traceback
        traceback.print_exc()
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }


def start_enrichment_job(parameters: Dict[str, Any]) -> Dict[str, Any]:
    """Start a new lead enrichment job with ECS workers."""
    # Generate job ID
    job_id = str(uuid.uuid4())
    print(f"Created job: {job_id}")
    
    # Connect to Salesforce
    print("✅ simple_salesforce imported successfully from layer")
    from simple_salesforce import Salesforce
    
    try:
        sf = Salesforce(
            username=os.environ['SF_USERNAME'],
            password=os.environ['SF_PASSWORD'],
            security_token=os.environ['SF_SECURITY_TOKEN']
        )
        print("✅ Connected to Salesforce successfully")
    except Exception as e:
        print(f"❌ Failed to connect to Salesforce: {e}")
        raise
    
    # Create job record
    job_record = {
        'job_id': job_id,
        'status': 'fetching_leads',
        'created_at': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'),
        'parameters': parameters
    }
    
    # Save job to DynamoDB
    jobs_table.put_item(Item=job_record)
    
    # Fetch leads from Salesforce
    try:
        leads = fetch_salesforce_leads(sf, parameters)
        leads_found = len(leads)
        print(f"Found {leads_found} leads")
        
        # Update job record
        jobs_table.update_item(
            Key={'job_id': job_id},
            UpdateExpression='SET #status = :status, leads_found = :found',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':status': 'queuing_leads',
                ':found': leads_found
            }
        )
        
        # Send leads to SQS queue
        queued_count = 0
        for lead in leads:
            message_body = json.dumps({
                'job_id': job_id,
                'lead': lead,
                'parameters': parameters
            })
            
            sqs.send_message(
                QueueUrl=JOB_QUEUE_URL,
                MessageBody=message_body
            )
            queued_count += 1
        
        print(f"Queued {queued_count} leads for processing")
        
        # Calculate optimal worker count with maximum limit of 10
        optimal_workers = min(max(2, queued_count // 500), 10)  # 2-10 workers
        print(f"Starting {optimal_workers} workers for {queued_count} leads")
        
        # Start ECS workers with limit
        workers_started = start_ecs_workers(optimal_workers)
        print(f"Started {workers_started} ECS workers")
        
        # Update job status
        jobs_table.update_item(
            Key={'job_id': job_id},
            UpdateExpression='SET #status = :status, leads_queued = :queued, workers_started = :workers',
            ExpressionAttributeNames={'#status': 'status'},
            ExpressionAttributeValues={
                ':status': 'processing',
                ':queued': queued_count,
                ':workers': workers_started
            }
        )
        
        return {
            'statusCode': 200,
            'body': json.dumps({
                'job_id': job_id,
                'status': 'processing',
                'leads_found': leads_found,
                'leads_queued': queued_count,
                'workers_started': workers_started,
                'message': f'Job started successfully. Processing {queued_count} leads with {workers_started} workers.'
            })
        }
        
    except Exception as e:
        print(f"Error in job processing: {str(e)}")
        # Update job status to failed
        jobs_table.update_item(
            Key={'job_id': job_id},
            UpdateExpression='SET #status = :status, #error = :error',
            ExpressionAttributeNames={'#status': 'status', '#error': 'error'},
            ExpressionAttributeValues={
                ':status': 'failed',
                ':error': str(e)
            }
        )
        raise


def fetch_salesforce_leads(sf: Any, parameters: Dict[str, Any]) -> List[Dict[str, Any]]:
    """Fetch leads from Salesforce based on parameters."""
    # Set limit
    limit = parameters.get('limit', 10000)
    print(f"Executing SOQL query with limit: {limit}")
    
    # Build SOQL query for leads with websites but missing contact info
    query = """
        SELECT Id, Company, Website, FirstName, LastName, Email, Phone,
               Street, City, State, PostalCode, Country, Title, CreatedDate,
               Enriched_First_Name__c, Enriched_Last_Name__c, Enrichment_Completed__c
        FROM Lead
        WHERE Website != null
        AND (Enrichment_Completed__c = false OR Enrichment_Completed__c = null)
        AND CreatedById = '0054V00000GJFtbQAH'
        ORDER BY CreatedDate DESC
    """
    
    if limit:
        query += f" LIMIT {limit}"
    
    print("Executing query:")
    query_lines = query.strip().split('\n')
    for line in query_lines[:5]:  # Print first 5 lines
        print(line.strip())
    if len(query_lines) > 5:
        print("...")
    
    # Execute query with pagination
    results = sf.query_all(query)
    total_records = len(results['records'])
    print(f"✅ Query successful, returned {total_records} total records")
    
    # Convert to list of dicts
    leads = []
    for record in results['records']:
        lead = {
            'id': record['Id'],
            'company': record.get('Company'),
            'website': record.get('Website'),
            'email': record.get('Email'),
            'phone': record.get('Phone'),
            'first_name': record.get('FirstName'),
            'last_name': record.get('LastName'),
            'title': record.get('Title'),
            'created_date': record.get('CreatedDate'),
            'address': {
                'street': record.get('Street'),
                'city': record.get('City'), 
                'state': record.get('State'),
                'postal_code': record.get('PostalCode'),
                'country': record.get('Country')
            }
        }
        leads.append(lead)
    
    return leads


def start_ecs_workers(count: int) -> int:
    """Start ECS workers with maximum limit."""
    try:
        # Ensure count doesn't exceed 10 (AWS ECS default limit)
        safe_count = min(count, 10)
        
        response = ecs.run_task(
            cluster=ECS_CLUSTER,
            taskDefinition=ECS_TASK_DEFINITION,
            count=safe_count,
            launchType='FARGATE',
            networkConfiguration={
                'awsvpcConfiguration': {
                    'subnets': [ECS_SUBNETS],
                    'securityGroups': [ECS_SECURITY_GROUP],
                    'assignPublicIp': 'ENABLED'
                }
            }
        )
        
        successful_tasks = len(response.get('tasks', []))
        failed_tasks = len(response.get('failures', []))
        
        if failed_tasks > 0:
            print(f"Warning: {failed_tasks} tasks failed to start")
            for failure in response.get('failures', []):
                print(f"Task failure: {failure}")
        
        print(f"✅ Successfully started {successful_tasks} ECS workers")
        return successful_tasks
        
    except Exception as e:
        print(f"❌ Error starting ECS workers: {e}")
        return 0