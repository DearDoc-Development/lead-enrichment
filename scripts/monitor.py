#!/usr/bin/env python3
"""
Lead Enrichment Progress Monitor
Interactive dashboard for monitoring lead enrichment jobs
"""

import boto3
import json
import sys
import time
from datetime import datetime, timedelta
from collections import defaultdict
import argparse

# AWS clients
dynamodb = boto3.resource('dynamodb', region_name='us-east-1')
sqs = boto3.client('sqs', region_name='us-east-1')
ecs = boto3.client('ecs', region_name='us-east-1')
logs = boto3.client('logs', region_name='us-east-1')

# Tables and resources
jobs_table = dynamodb.Table('lead-enrichment-jobs')
results_table = dynamodb.Table('lead-enrichment-results')
QUEUE_URL = 'https://sqs.us-east-1.amazonaws.com/238621222840/lead-enrichment-job-queue'
CLUSTER_NAME = 'lead-enrichment-cluster'
LOG_GROUP = '/ecs/lead-enrichment-worker'

# ANSI color codes
class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'

def clear_screen():
    """Clear the terminal screen"""
    print('\033[2J\033[H')

def get_latest_jobs(limit=5):
    """Get the most recent jobs"""
    try:
        # First try with limit
        response = jobs_table.scan(Limit=50)
        jobs = response.get('Items', [])
        
        if not jobs:
            # If no jobs found, try full scan
            print(f"{Colors.YELLOW}No jobs found in limited scan, checking all records...{Colors.ENDC}")
            response = jobs_table.scan()
            jobs = response.get('Items', [])
            
        if not jobs:
            return []
        
        # Sort by created_at descending
        jobs.sort(key=lambda x: x.get('created_at', ''), reverse=True)
        return jobs[:limit]
    except Exception as e:
        print(f"{Colors.RED}Error fetching jobs: {e}{Colors.ENDC}")
        return []

def get_queue_status():
    """Get SQS queue statistics"""
    response = sqs.get_queue_attributes(
        QueueUrl=QUEUE_URL,
        AttributeNames=['All']
    )
    attrs = response['Attributes']
    return {
        'available': int(attrs.get('ApproximateNumberOfMessages', 0)),
        'in_flight': int(attrs.get('ApproximateNumberOfMessagesNotVisible', 0)),
        'delayed': int(attrs.get('ApproximateNumberOfMessagesDelayed', 0))
    }

def get_worker_status():
    """Get ECS worker information"""
    response = ecs.list_tasks(cluster=CLUSTER_NAME)
    task_arns = response.get('taskArns', [])
    
    if task_arns:
        tasks = ecs.describe_tasks(
            cluster=CLUSTER_NAME,
            tasks=task_arns
        )
        return {
            'count': len(task_arns),
            'tasks': tasks.get('tasks', [])
        }
    return {'count': 0, 'tasks': []}

def get_processing_stats(job_id, time_window_minutes=5):
    """Get processing statistics from logs"""
    start_time = int((datetime.now() - timedelta(minutes=time_window_minutes)).timestamp() * 1000)
    
    stats = {
        'successful': 0,
        'failed': 0,
        'errors': defaultdict(int)
    }
    
    try:
        # Get successful processing
        response = logs.filter_log_events(
            logGroupName=LOG_GROUP,
            startTime=start_time,
            filterPattern='Successfully processed'
        )
        stats['successful'] = len(response.get('events', []))
        
        # Get failures
        response = logs.filter_log_events(
            logGroupName=LOG_GROUP,
            startTime=start_time,
            filterPattern='Failed to process'
        )
        stats['failed'] = len(response.get('events', []))
        
    except Exception as e:
        print(f"Error getting log stats: {e}")
    
    return stats

def get_job_results(job_id):
    """Get results count for a specific job"""
    try:
        response = results_table.query(
            IndexName='job_id-index',
            KeyConditionExpression='job_id = :job_id',
            ExpressionAttributeValues={':job_id': job_id},
            Select='COUNT'
        )
        return response.get('Count', 0)
    except:
        return 0

def print_progress_bar(current, total, width=50):
    """Print a progress bar"""
    if total == 0:
        percent = 0
    else:
        percent = int((current / total) * 100)
    
    filled = int(width * current // total) if total > 0 else 0
    bar = '█' * filled + '░' * (width - filled)
    
    print(f"[{bar}] {percent}% ({current}/{total})")

def display_dashboard(job_id=None):
    """Display the monitoring dashboard"""
    clear_screen()
    
    print(f"{Colors.BOLD}{Colors.HEADER}📊 LEAD ENRICHMENT MONITOR{Colors.ENDC}")
    print(f"Last Updated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print("=" * 80)
    
    # Get data
    jobs = get_latest_jobs()
    queue_status = get_queue_status()
    worker_status = get_worker_status()
    
    # Check if no jobs found
    if not jobs:
        print(f"{Colors.RED}❌ No jobs found in the system!{Colors.ENDC}")
        print(f"\n{Colors.YELLOW}You can start a new job with:{Colors.ENDC}")
        print(f"{Colors.BLUE}echo '{{\"limit\": 5, \"update_salesforce\": true}}' | base64 | \\{Colors.ENDC}")
        print(f"{Colors.BLUE}aws lambda invoke --function-name lead-enrichment-orchestrator \\{Colors.ENDC}")
        print(f"{Colors.BLUE}  --payload file:///dev/stdin response.json --region us-east-1{Colors.ENDC}")
        return
    
    # Display specific job or latest
    if job_id:
        job = next((j for j in jobs if j.get('job_id') == job_id), None)
        if not job:
            print(f"{Colors.RED}Job {job_id} not found!{Colors.ENDC}")
            return
        jobs = [job]
    
    # Job information
    for idx, job in enumerate(jobs[:1]):  # Show only one job at a time
        job_id = job.get('job_id', 'Unknown')
        status = job.get('status', 'Unknown')
        leads_found = int(job.get('leads_found', 0))
        leads_queued = int(job.get('leads_queued', 0))
        workers_started = int(job.get('workers_started', 0))
        created_at = job.get('created_at', 'Unknown')
        
        print(f"\n{Colors.BOLD}📋 JOB INFORMATION{Colors.ENDC}")
        print(f"Job ID:          {Colors.YELLOW}{job_id}{Colors.ENDC}")
        print(f"Status:          {Colors.GREEN if status == 'processing' else Colors.YELLOW}{status}{Colors.ENDC}")
        print(f"Created:         {created_at}")
        print(f"Leads Found:     {leads_found:,}")
        print(f"Leads Queued:    {leads_queued:,}")
        print(f"Workers Started: {workers_started}")
        
        # Queue status
        print(f"\n{Colors.BOLD}📦 QUEUE STATUS{Colors.ENDC}")
        print(f"Messages Waiting:    {Colors.YELLOW}{queue_status['available']:,}{Colors.ENDC}")
        print(f"Messages Processing: {Colors.GREEN}{queue_status['in_flight']:,}{Colors.ENDC}")
        total_remaining = queue_status['available'] + queue_status['in_flight']
        print(f"Total Remaining:     {Colors.BOLD}{total_remaining:,}{Colors.ENDC}")
        
        # Progress calculation (for current job only)
        if leads_queued > 0:
            # Get actual results count
            results_count = get_job_results(job_id)
            progress_percent = int((results_count / leads_queued) * 100) if leads_queued > 0 else 0
            
            print(f"\n{Colors.BOLD}📈 PROGRESS{Colors.ENDC}")
            print(f"Completed: {results_count:,} / {leads_queued:,} ({progress_percent}%)")
            print_progress_bar(results_count, leads_queued)
        
        # Worker status
        print(f"\n{Colors.BOLD}👷 WORKER STATUS{Colors.ENDC}")
        print(f"Active Workers: {Colors.GREEN}{worker_status['count']}{Colors.ENDC}")
        
        # Processing stats
        stats = get_processing_stats(job_id)
        total_processed = stats['successful'] + stats['failed']
        success_rate = int((stats['successful'] / total_processed * 100)) if total_processed > 0 else 0
        
        print(f"\n{Colors.BOLD}📊 PROCESSING STATS (Last 5 min){Colors.ENDC}")
        print(f"Successful: {Colors.GREEN}{stats['successful']}{Colors.ENDC}")
        print(f"Failed:     {Colors.RED}{stats['failed']}{Colors.ENDC}")
        if total_processed > 0:
            print(f"Success Rate: {Colors.BOLD}{success_rate}%{Colors.ENDC}")
            
            # Estimate completion time
            if stats['successful'] > 0 and total_remaining > 0:
                rate_per_min = stats['successful'] / 5
                minutes_remaining = int(total_remaining / rate_per_min)
                hours = minutes_remaining // 60
                mins = minutes_remaining % 60
                print(f"\nEstimated Time Remaining: {Colors.YELLOW}{hours}h {mins}m{Colors.ENDC}")
    
    # Other recent jobs
    if len(jobs) > 1 and not job_id:
        print(f"\n{Colors.BOLD}📋 OTHER RECENT JOBS{Colors.ENDC}")
        for job in jobs[1:4]:
            print(f"• {job.get('job_id', 'Unknown')[:8]}... - {job.get('status', 'Unknown')} - {job.get('created_at', 'Unknown')[:19]}")

def main():
    parser = argparse.ArgumentParser(description='Monitor lead enrichment progress')
    parser.add_argument('--job-id', '-j', help='Monitor specific job ID')
    parser.add_argument('--watch', '-w', action='store_true', help='Auto-refresh every 30 seconds')
    parser.add_argument('--interval', '-i', type=int, default=30, help='Refresh interval in seconds')
    
    args = parser.parse_args()
    
    try:
        if args.watch:
            while True:
                display_dashboard(args.job_id)
                print(f"\n{Colors.YELLOW}Refreshing in {args.interval} seconds... (Ctrl+C to exit){Colors.ENDC}")
                time.sleep(args.interval)
        else:
            display_dashboard(args.job_id)
            print(f"\n{Colors.YELLOW}Tip: Use --watch for continuous monitoring{Colors.ENDC}")
    except KeyboardInterrupt:
        print(f"\n{Colors.GREEN}Monitoring stopped.{Colors.ENDC}")
        sys.exit(0)
    except Exception as e:
        print(f"{Colors.RED}Error: {e}{Colors.ENDC}")
        sys.exit(1)

if __name__ == '__main__':
    main()