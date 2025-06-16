"""
Worker Lambda Function
Processes individual leads:
1. Receives lead from SQS queue
2. Scrapes website content
3. Extracts information using AI
4. Stores results in DynamoDB
"""

import json
import os
import asyncio
from datetime import datetime, timezone
from decimal import Decimal
from typing import Dict, Any, Optional
import boto3
from playwright.async_api import async_playwright
import openai
from simple_salesforce import Salesforce

def convert_floats_to_decimal(obj):
    """Recursively convert float values to Decimal for DynamoDB compatibility."""
    if isinstance(obj, float):
        return Decimal(str(obj))
    elif isinstance(obj, dict):
        return {k: convert_floats_to_decimal(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [convert_floats_to_decimal(item) for item in obj]
    else:
        return obj

# AWS clients
dynamodb = boto3.resource('dynamodb')
s3 = boto3.client('s3')

# Environment variables
RESULTS_TABLE = os.environ['RESULTS_TABLE']
CACHE_TABLE = os.environ['CACHE_TABLE']
JOBS_TABLE = os.environ['JOBS_TABLE']
CACHE_BUCKET = os.environ.get('CACHE_BUCKET')

# DynamoDB tables
results_table = dynamodb.Table(RESULTS_TABLE)
cache_table = dynamodb.Table(CACHE_TABLE)
jobs_table = dynamodb.Table(JOBS_TABLE)

# AI clients
openai.api_key = os.environ.get('OPENAI_API_KEY')


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler for worker.
    Processes SQS messages containing leads.
    """
    records_processed = 0
    records_failed = 0
    
    for record in event.get('Records', []):
        try:
            # Parse SQS message
            message = json.loads(record['body'])
            job_id = message['job_id']
            lead = message['lead']
            parameters = message.get('parameters', {})
            
            # Process the lead
            result = asyncio.run(process_lead(job_id, lead, parameters))
            
            if result:
                records_processed += 1
            else:
                records_failed += 1
                
        except Exception as e:
            print(f"Error processing record: {str(e)}")
            records_failed += 1
    
    return {
        'statusCode': 200,
        'body': json.dumps({
            'processed': records_processed,
            'failed': records_failed
        })
    }


async def process_lead(job_id: str, lead: Dict[str, Any], parameters: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Process a single lead through the enrichment pipeline."""
    try:
        lead_id = lead['id']
        website = lead.get('website')
        
        if not website:
            return save_error_result(job_id, lead_id, "No website URL provided")
        
        # Check cache first
        cached_content = check_cache(website)
        
        if cached_content:
            print(f"Using cached content for {website}")
            scraped_data = cached_content
        else:
            # Scrape website
            scraped_data = await scrape_website(website)
            if scraped_data:
                # Cache the scraped content
                cache_content(website, scraped_data)
        
        if not scraped_data:
            return save_error_result(job_id, lead_id, "Failed to scrape website")
        
        # Extract information using AI
        extracted_info = await extract_information(scraped_data, lead)
        
        if not extracted_info:
            return save_error_result(job_id, lead_id, "Failed to extract information")
        
        # Prepare enriched result
        enriched_lead = {
            'lead_id': lead_id,
            'job_id': job_id,
            'original_data': convert_floats_to_decimal(lead),
            'enriched_data': convert_floats_to_decimal(extracted_info),
            'enrichment_date': datetime.now(timezone.utc).isoformat(),
            'confidence_score': Decimal(str(extracted_info.get('confidence', 0))),
            'data_source': 'web_scraping'
        }
        
        # Save to DynamoDB
        results_table.put_item(Item=enriched_lead)
        
        # Update Salesforce if requested (regardless of confidence score)
        if parameters.get('update_salesforce', False) and extracted_info:
            try:
                await update_salesforce_lead(lead_id, extracted_info)
                enriched_lead['salesforce_updated'] = True
            except Exception as e:
                print(f"Failed to update Salesforce for lead {lead_id}: {str(e)}")
                enriched_lead['salesforce_error'] = str(e)
        
        # Update job progress
        update_job_progress(job_id, success=True)
        
        return enriched_lead
        
    except Exception as e:
        print(f"Error processing lead {lead.get('id')}: {str(e)}")
        return save_error_result(job_id, lead.get('id'), str(e))


async def scrape_website(url: str, max_retries: int = 3) -> Optional[Dict[str, Any]]:
    """Scrape website content using Playwright with retry logic."""
    import asyncio
    
    for attempt in range(max_retries):
        browser = None
        try:
            async with async_playwright() as p:
                # Launch browser with optimized settings
                browser = await p.chromium.launch(
                    headless=True,
                    args=[
                        '--no-sandbox',
                        '--disable-setuid-sandbox',
                        '--disable-dev-shm-usage',
                        '--disable-gpu',
                        '--no-zygote',
                        '--single-process',
                        '--disable-web-security',
                        '--ignore-certificate-errors',  # Handle cert errors
                        '--ignore-ssl-errors',
                        '--ignore-certificate-errors-spki-list'
                    ]
                )
                
                context = await browser.new_context(
                    viewport={'width': 1920, 'height': 1080},
                    user_agent='Mozilla/5.0 (compatible; LeadEnrichmentBot/1.0)',
                    ignore_https_errors=True  # Ignore HTTPS certificate errors
                )
                
                page = await context.new_page()
                
                # Progressive timeout increases with retries
                timeout = 20000 + (attempt * 10000)  # 20s, 30s, 40s
                page.set_default_timeout(timeout)
                
                print(f"Attempt {attempt + 1}/{max_retries} scraping {url} (timeout: {timeout}ms)")
                
                # Navigate to the website with retry-specific handling
                await page.goto(url, wait_until='domcontentloaded', timeout=timeout)
                
                # Extract content
                text_content = await page.evaluate('() => document.body.innerText')
                
                # Try to find contact/about pages
                contact_links = await page.locator('a:has-text("contact"), a:has-text("about")').all()
                
                additional_pages = []
                for link in contact_links[:3]:  # Limit to 3 additional pages
                    try:
                        href = await link.get_attribute('href')
                        if href and not href.startswith('mailto:'):
                            await page.goto(href, wait_until='domcontentloaded', timeout=10000)
                            additional_pages.append({
                                'url': href,
                                'content': await page.evaluate('() => document.body.innerText')
                            })
                    except:
                        pass  # Skip failed additional pages
                
                await browser.close()
                
                print(f"Successfully scraped {url} on attempt {attempt + 1}")
                return {
                    'url': url,
                    'main_content': text_content,
                    'additional_pages': additional_pages,
                    'scraped_at': datetime.now(timezone.utc).isoformat()
                }
                
        except Exception as e:
            error_msg = str(e)
            print(f"Attempt {attempt + 1}/{max_retries} failed for {url}: {error_msg}")
            
            if browser:
                try:
                    await browser.close()
                except:
                    pass
            
            # Check if it's a retryable error
            retryable_errors = [
                'timeout', 'net::err_cert_date_invalid', 'net::err_connection_refused',
                'net::err_connection_timed_out', 'net::err_name_not_resolved',
                'connection closed', 'connection reset'
            ]
            
            is_retryable = any(retry_err.lower() in error_msg.lower() for retry_err in retryable_errors)
            
            if not is_retryable or attempt == max_retries - 1:
                print(f"Failed to scrape {url} after {attempt + 1} attempts: {error_msg}")
                return None
            
            # Wait before retry with exponential backoff
            wait_time = 2 ** attempt  # 1s, 2s, 4s
            print(f"Retrying in {wait_time} seconds...")
            await asyncio.sleep(wait_time)
    
    return None


async def extract_information(scraped_data: Dict[str, Any], lead: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Extract business owner information using AI."""
    try:
        # Combine all scraped content
        all_content = scraped_data['main_content']
        for page in scraped_data.get('additional_pages', []):
            all_content += "\n\n" + page['content']
        
        # Prepare prompt
        prompt = f"""
        Analyze the following website content for company: {lead.get('company', 'Unknown')}
        
        Extract the following information:
        1. Business owner/founder's first name and last name
        2. Complete business address (street, city, state, zip, country)
        
        Website content:
        {all_content[:3000]}  # Limit content to avoid token limits
        
        Return a JSON object with:
        {{
            "first_name": "owner's first name OR null if not found",
            "last_name": "owner's last name OR null if not found",
            "address": {{
                "street": "street address OR null if not found",
                "city": "city OR null if not found",
                "state": "state OR null if not found",
                "postal_code": "zip code OR null if not found",
                "country": "country OR null if not found"
            }},
            "confidence": 0.0 to 1.0,
            "reasoning": "brief explanation"
        }}
        
        IMPORTANT: If information is not found, use null values - never use strings like "Not found" or "Unknown".
        """
        
        # Try OpenAI first (faster and cheaper)
        try:
            response = openai.ChatCompletion.create(
                model="gpt-3.5-turbo-1106",  # Supports JSON mode
                messages=[
                    {"role": "system", "content": "You are a data extraction assistant. Always return valid JSON."},
                    {"role": "user", "content": prompt}
                ],
                response_format={"type": "json_object"},
                temperature=0,
                max_tokens=500
            )
            
            result = json.loads(response.choices[0].message.content)
            return result
            
        except Exception as e:
            print(f"OpenAI failed: {str(e)}")
            # Return None if OpenAI fails
            return None
            
    except Exception as e:
        print(f"Error in AI extraction: {str(e)}")
        return None


def check_cache(website: str) -> Optional[Dict[str, Any]]:
    """Check if website content is cached in DynamoDB."""
    try:
        response = cache_table.get_item(Key={'website': website})
        if 'Item' in response:
            # Check if cache is still valid (24 hours)
            cached_time = datetime.fromisoformat(response['Item']['cached_at'])
            if (datetime.now(timezone.utc) - cached_time).days < 1:
                return response['Item']['content']
    except:
        pass
    return None


def cache_content(website: str, content: Dict[str, Any]) -> None:
    """Cache website content in DynamoDB."""
    try:
        cache_table.put_item(
            Item={
                'website': website,
                'content': convert_floats_to_decimal(content),
                'cached_at': datetime.now(timezone.utc).isoformat()
            }
        )
    except Exception as e:
        print(f"Error caching content: {str(e)}")


def save_error_result(job_id: str, lead_id: str, error: str) -> None:
    """Save error result for failed lead processing."""
    error_result = {
        'lead_id': lead_id,
        'job_id': job_id,
        'status': 'failed',
        'error': error,
        'processed_at': datetime.now(timezone.utc).isoformat()
    }
    results_table.put_item(Item=error_result)
    update_job_progress(job_id, success=False)
    return None


async def update_salesforce_lead(lead_id: str, extracted_info: Dict[str, Any]) -> None:
    """Update Salesforce lead with enriched information and standard fields."""
    try:
        # Initialize Salesforce client
        sf = Salesforce(
            username=os.environ['SF_USERNAME'],
            password=os.environ['SF_PASSWORD'],
            security_token=os.environ['SF_SECURITY_TOKEN']
        )
        
        # Prepare update data
        update_data = {}
        
        # Helper function to check if value is valid (not null, empty, or "not found" variations)
        def is_valid_value(value):
            if not value or value is None:
                return False
            if isinstance(value, str):
                lower_val = value.lower().strip()
                invalid_strings = ['not found', 'unknown', 'n/a', 'none', 'null', '']
                return lower_val not in invalid_strings
            return True
        
        # Update name fields - both enriched and standard fields
        if is_valid_value(extracted_info.get('first_name')):
            update_data['Enriched_First_Name__c'] = extracted_info['first_name']
            update_data['FirstName'] = extracted_info['first_name']
        
        if is_valid_value(extracted_info.get('last_name')):
            update_data['Enriched_Last_Name__c'] = extracted_info['last_name']
            update_data['LastName'] = extracted_info['last_name']
        
        # Update address fields - both enriched and standard fields
        address = extracted_info.get('address') or {}
        if is_valid_value(address.get('street')):
            update_data['Enriched_Street__c'] = address['street']
            update_data['Street'] = address['street']
        
        if is_valid_value(address.get('city')):
            update_data['Enriched_City__c'] = address['city']
            update_data['City'] = address['city']
        
        if is_valid_value(address.get('state')):
            update_data['Enriched_State__c'] = address['state']
            update_data['State'] = address['state']
        
        if is_valid_value(address.get('postal_code')):
            update_data['Enriched_Postal_Code__c'] = address['postal_code']
            update_data['PostalCode'] = address['postal_code']
        
        if is_valid_value(address.get('country')):
            update_data['Enriched_Country__c'] = address['country']
            update_data['Country'] = address['country']
        
        # Build full address field
        address_parts = []
        if is_valid_value(address.get('street')):
            address_parts.append(address['street'])
        if is_valid_value(address.get('city')):
            address_parts.append(address['city'])
        if is_valid_value(address.get('state')):
            address_parts.append(address['state'])
        if is_valid_value(address.get('postal_code')):
            address_parts.append(address['postal_code'])
        if is_valid_value(address.get('country')):
            address_parts.append(address['country'])
        
        if address_parts:
            update_data['Enriched_Full_Address__c'] = ', '.join(address_parts)
        
        # Add metadata (Salesforce expects datetime without timezone)
        update_data['Enrichment_Date__c'] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
        update_data['Enrichment_Confidence__c'] = extracted_info.get('confidence', 0) if extracted_info else 0
        update_data['Enrichment_Source__c'] = 'AI_Web_Scraping'
        update_data['Enrichment_Completed__c'] = True
        
        # Update the lead in Salesforce
        if update_data:
            sf.Lead.update(lead_id, update_data)
            print(f"Successfully updated Salesforce lead {lead_id} with {len(update_data)} fields")
        
    except Exception as e:
        print(f"Error updating Salesforce lead {lead_id}: {str(e)}")
        raise


def update_job_progress(job_id: str, success: bool) -> None:
    """Update job progress counters."""
    try:
        if success:
            jobs_table.update_item(
                Key={'job_id': job_id},
                UpdateExpression='ADD processed_leads :inc',
                ExpressionAttributeValues={':inc': 1}
            )
        else:
            jobs_table.update_item(
                Key={'job_id': job_id},
                UpdateExpression='ADD failed_leads :inc',
                ExpressionAttributeValues={':inc': 1}
            )
    except Exception as e:
        print(f"Error updating job progress: {str(e)}")


def main():
    """Main ECS worker loop that polls SQS for messages."""
    import time
    import signal
    
    # Setup graceful shutdown
    shutdown = False
    
    def signal_handler(_signum, _frame):
        nonlocal shutdown
        print("Received shutdown signal, finishing current work...")
        shutdown = True
    
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)
    
    # Initialize SQS client
    sqs = boto3.client('sqs')
    queue_url = os.environ['JOB_QUEUE_URL']
    
    # Auto-shutdown configuration
    AUTO_SHUTDOWN_ENABLED = os.environ.get('AUTO_SHUTDOWN_ENABLED', 'true').lower() == 'true'
    IDLE_TIMEOUT_MINUTES = int(os.environ.get('IDLE_TIMEOUT_MINUTES', '5'))
    MAX_IDLE_POLLS = IDLE_TIMEOUT_MINUTES * 3  # 20-second polls = 3 per minute
    
    idle_poll_count = 0
    total_processed = 0
    
    if AUTO_SHUTDOWN_ENABLED:
        print(f"Worker starting with auto-shutdown enabled (idle timeout: {IDLE_TIMEOUT_MINUTES} minutes)")
    else:
        print("Worker starting with auto-shutdown disabled")
    
    print(f"Polling queue: {queue_url}")
    
    while not shutdown:
        try:
            # Poll for messages
            response = sqs.receive_message(
                QueueUrl=queue_url,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=20,  # Long polling
                MessageAttributeNames=['All']
            )
            
            messages = response.get('Messages', [])
            
            if not messages:
                idle_poll_count += 1
                print(f"No messages available, continuing to poll... (idle: {idle_poll_count}/{MAX_IDLE_POLLS})")
                
                # Check for auto-shutdown
                if AUTO_SHUTDOWN_ENABLED and idle_poll_count >= MAX_IDLE_POLLS:
                    print(f"🔄 Auto-shutdown triggered: No work for {IDLE_TIMEOUT_MINUTES} minutes")
                    print(f"📊 Worker processed {total_processed} leads before shutting down")
                    break
                
                continue
            
            # Reset idle counter when work is found
            idle_poll_count = 0
            
            for message in messages:
                try:
                    # Parse message
                    body = json.loads(message['Body'])
                    receipt_handle = message['ReceiptHandle']
                    
                    print(f"Processing message for lead: {body.get('lead', {}).get('id', 'Unknown')}")
                    
                    # Process the lead
                    job_id = body['job_id']
                    lead = body['lead']
                    parameters = body.get('parameters', {})
                    
                    result = asyncio.run(process_lead(job_id, lead, parameters))
                    
                    if result:
                        total_processed += 1
                        print(f"Successfully processed lead {lead['id']} (total: {total_processed})")
                        # Delete message from queue
                        sqs.delete_message(
                            QueueUrl=queue_url,
                            ReceiptHandle=receipt_handle
                        )
                    else:
                        print(f"Failed to process lead {lead['id']}")
                        # Leave message in queue to be retried
                        
                except Exception as e:
                    print(f"Error processing message: {str(e)}")
                    # Leave message in queue to be retried
                    
        except Exception as e:
            print(f"Error polling queue: {str(e)}")
            time.sleep(5)  # Wait before retrying
    
    print("Worker shutting down gracefully")


if __name__ == "__main__":
    main()