# Required Salesforce Custom Fields

Create these custom fields on the Lead object in Salesforce:

## Enrichment Fields
- `Enriched_First_Name__c` - Text(50)
- `Enriched_Last_Name__c` - Text(50)
- `Enriched_Street__c` - Text(255)
- `Enriched_City__c` - Text(40)
- `Enriched_State__c` - Text(20)
- `Enriched_Postal_Code__c` - Text(20)
- `Enriched_Country__c` - Text(40)
- `Enriched_Full_Address__c` - Text(500) - Full concatenated address

## Metadata Fields
- `Enrichment_Date__c` - Date/Time
- `Enrichment_Confidence__c` - Number(3,2) - Decimal with 2 places
- `Enrichment_Source__c` - Text(50)
- `Enrichment_Completed__c` - Checkbox (Boolean)

## Query Logic
The system will only process leads where:
- `Website` is not null
- `Enrichment_Completed__c` is false or null
- `CreatedDate` is after the last run date

## Update Logic
Salesforce is updated when:
- Any data is extracted (regardless of confidence score)
- `update_salesforce` parameter is true
- Sets `Enrichment_Completed__c = true` after update