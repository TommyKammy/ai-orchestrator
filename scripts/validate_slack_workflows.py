#!/usr/bin/env python3
import json
import sys
from pathlib import Path

def validate_slack_workflow(filepath: Path) -> tuple[bool, list[str]]:
    errors = []
    
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            workflow = json.load(f)
    except json.JSONDecodeError as e:
        return False, [f"Invalid JSON in {filepath}: {e}"]
    except Exception as e:
        return False, [f"Cannot read {filepath}: {e}"]
    
    ack_node = None
    for node in workflow.get('nodes', []):
        node_type = node.get('type', '')
        node_name = node.get('name', '').lower()
        
        if node_type == 'n8n-nodes-base.respondToWebhook':
            if 'ack' in node_name or 'immediate' in node_name:
                ack_node = node
                break
    
    if not ack_node:
        errors.append(f"No 'Immediate ACK' (respondToWebhook) node found")
        return False, errors
    
    params = ack_node.get('parameters', {})
    respond_with = params.get('respondWith', '')
    
    if respond_with != 'json':
        errors.append(f"ACK node should use 'json' response mode, found: {respond_with}")
    
    json_content = params.get('json', '')
    
    if '{"myField":"value"}' in json_content or "myField" in json_content:
        errors.append(f"ACK contains n8n placeholder - expression failed to evaluate")
    
    if '={{' in json_content:
        errors.append(f"ACK contains expression syntax '={{' - should be hard-coded JSON")
    
    if '$json' in json_content:
        errors.append(f"ACK references '$json' - should be hard-coded JSON")
    
    if json_content:
        try:
            ack_json = json.loads(json_content)
            
            if 'response_type' not in ack_json:
                errors.append(f"ACK JSON missing 'response_type' field")
            elif ack_json.get('response_type') != 'ephemeral':
                errors.append(f"ACK response_type should be 'ephemeral', found: {ack_json.get('response_type')}")
            
            if 'text' not in ack_json:
                errors.append(f"ACK JSON missing 'text' field")
            elif not ack_json.get('text'):
                errors.append(f"ACK text field is empty")
                
        except json.JSONDecodeError:
            errors.append(f"ACK 'json' field contains invalid JSON: {json_content[:100]}")
    else:
        errors.append(f"ACK 'json' field is empty")
    
    return len(errors) == 0, errors

def main():
    workflow_dirs = [
        Path.home() / 'ai-orchestrator-workflows',
        Path('/opt/ai-orchestrator/n8n/workflows-v3'),
    ]
    
    if len(sys.argv) > 1:
        workflow_dirs = [Path(p) for p in sys.argv[1:]]
    
    all_valid = True
    total_files = 0
    
    print("=" * 70)
    print("SLACK WORKFLOW VALIDATION")
    print("=" * 70)
    print()
    
    for workflow_dir in workflow_dirs:
        if not workflow_dir.exists():
            print(f"Directory not found: {workflow_dir}")
            continue
        
        workflow_files = list(workflow_dir.glob('*slack*.json'))
        
        if not workflow_files:
            print(f"No Slack workflow files found in: {workflow_dir}")
            continue
        
        print(f"Checking directory: {workflow_dir}")
        print()
        
        for filepath in workflow_files:
            total_files += 1
            print(f"  {filepath.name}")
            
            is_valid, errors = validate_slack_workflow(filepath)
            
            if is_valid:
                print(f"    PASS - Immediate ACK is correctly configured")
            else:
                all_valid = False
                for error in errors:
                    print(f"    {error}")
            
            print()
    
    print("=" * 70)
    if all_valid and total_files > 0:
        print(f"ALL CHECKS PASSED ({total_files} workflow(s) validated)")
        print()
        print("The workflow(s) are ready for import and will correctly respond to Slack.")
        sys.exit(0)
    elif total_files == 0:
        print("No workflow files found to validate")
        sys.exit(1)
    else:
        print(f"VALIDATION FAILED")
        print()
        print("Fix the issues above before importing the workflow into n8n.")
        print()
        print("Common fixes:")
        print("  1. Open workflow in n8n UI")
        print("  2. Find 'Immediate ACK' node (Respond to Webhook)")
        print("  3. Set response mode to 'JSON'")
        print("  4. Paste exact JSON:")
        print('     {"response_type": "ephemeral", "text": "Processing your request..."}')
        print("  5. Save and re-export workflow")
        sys.exit(1)

if __name__ == '__main__':
    main()
