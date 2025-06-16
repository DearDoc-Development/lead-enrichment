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
from typing import Dict, Any, Optional, List
import boto3
from playwright.async_api import async_playwright, Browser
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


async def scrape_website(url: str) -> Optional[Dict[str, Any]]:
    """Scrape website content using Playwright."""
    browser = None
    try:
        async with async_playwright() as p:
            # Launch browser with Lambda-optimized settings
            browser = await p.chromium.launch(
                headless=True,
                args=[
                    '--no-sandbox',
                    '--disable-setuid-sandbox',
                    '--disable-dev-shm-usage',
                    '--disable-gpu',
                    '--no-zygote',
                    '--single-process',
                    '--disable-web-security'
                ]
            )
            
            context = await browser.new_context(
                viewport={'width': 1920, 'height': 1080},
                user_agent='Mozilla/5.0 (compatible; LeadEnrichmentBot/1.0)'
            )
            
            page = await context.new_page()
            
            # Set timeout for navigation
            page.set_default_timeout(15000)  # 15 seconds
            
            # Navigate to the website
            await page.goto(url, wait_until='networkidle')
            
            # Extract content
            content = await page.content()
            text_content = await page.evaluate('() => document.body.innerText')
            
            # Try to find contact/about pages
            contact_links = await page.locator('a:has-text("contact"), a:has-text("about")').all()
            
            additional_pages = []
            for link in contact_links[:3]:  # Limit to 3 additional pages
                try:
                    href = await link.get_attribute('href')
                    if href and not href.startswith('mailto:'):
                        await page.goto(href, wait_until='networkidle')
                        additional_pages.append({
                            'url': href,
                            'content': await page.evaluate('() => document.body.innerText')
                        })
                except:
                    pass
            
            await browser.close()
            
            return {
                'url': url,
                'main_content': text_content,
                'additional_pages': additional_pages,
                'scraped_at': datetime.utcnow().isoformat()
            }
            
    except Exception as e:
        print(f"Error scraping {url}: {str(e)}")
        if browser:
            await browser.close()
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
            "first_name": "owner's first name",
            "last_name": "owner's last name",
            "address": {{
                "street": "street address",
                "city": "city",
                "state": "state",
                "postal_code": "zip code",
                "country": "country"
            }},
            "confidence": 0.0 to 1.0,
            "reasoning": "brief explanation"
        }}
        
        If information is not found, return null values.
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
        
        # Update name fields - both enriched and standard fields
        if extracted_info.get('first_name') and extracted_info['first_name'].lower() != 'not found':
            update_data['Enriched_First_Name__c'] = extracted_info['first_name']
            update_data['FirstName'] = extracted_info['first_name']
        
        if extracted_info.get('last_name') and extracted_info['last_name'].lower() != 'not found':
            update_data['Enriched_Last_Name__c'] = extracted_info['last_name']
            update_data['LastName'] = extracted_info['last_name']
        
        # Update address fields - both enriched and standard fields
        address = extracted_info.get('address', {})
        if address.get('street'):
            update_data['Enriched_Street__c'] = address['street']
            update_data['Street'] = address['street']
        
        if address.get('city'):
            update_data['Enriched_City__c'] = address['city']
            update_data['City'] = address['city']
        
        if address.get('state'):
            update_data['Enriched_State__c'] = address['state']
            update_data['State'] = address['state']
        
        if address.get('postal_code'):
            update_data['Enriched_Postal_Code__c'] = address['postal_code']
            update_data['PostalCode'] = address['postal_code']
        
        if address.get('country'):
            update_data['Enriched_Country__c'] = address['country']
            update_data['Country'] = address['country']
        
        # Build full address field
        address_parts = []
        if address.get('street'):
            address_parts.append(address['street'])
        if address.get('city'):
            address_parts.append(address['city'])
        if address.get('state'):
            address_parts.append(address['state'])
        if address.get('postal_code'):
            address_parts.append(address['postal_code'])
        if address.get('country'):
            address_parts.append(address['country'])
        
        if address_parts:
            update_data['Enriched_Full_Address__c'] = ', '.join(address_parts)
        
        # Add metadata
        update_data['Enrichment_Date__c'] = datetime.now(timezone.utc).isoformat()
        update_data['Enrichment_Confidence__c'] = extracted_info.get('confidence', 0)
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