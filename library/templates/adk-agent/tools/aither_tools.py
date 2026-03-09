import subprocess
import json
import os
from typing import Optional, List, Dict
from google.adk.tools import FunctionTool
# Import MCP Client tools
try:
    from .mcp_client import list_mcp_servers, list_mcp_tools, call_mcp_tool
except ImportError:
    from tools.mcp_client import list_mcp_servers, list_mcp_tools, call_mcp_tool

# Import Workflow Engine
try:
    from workflows.engine import WorkflowEngine
except ImportError:
    from agents.AitherZeroAutomationAgent.workflows.engine import WorkflowEngine

# Determine project root
CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(CURRENT_DIR, "..", "..", ".."))
MODULE_PATH = os.path.join(PROJECT_ROOT, "AitherZero", "bin", "AitherZero.psd1")

def execute_aither_script(script_name: str, parameters: Optional[dict] = None) -> str:
    """
    Executes a PowerShell automation script from the AitherZero library.

    Args:
        script_name (str): The name or ID of the script to execute (e.g., '0206', '0206_Install-Python.ps1').
        parameters (dict, optional): A dictionary of parameters to pass to the script.
                                     Example: {'PackageName': 'git', 'Force': True}

    Returns:
        str: The standard output and error from the script execution.
    """
    try:
        params_json = json.dumps(parameters if parameters else {})
        params_json_safe = params_json.replace("'", "''")
        
        cmd = [
            "pwsh", "-NoProfile", "-Command", 
            f"& {{ Import-Module '{MODULE_PATH}' -Force -ErrorAction Stop; $params = ConvertFrom-Json '{params_json_safe}' -AsHashtable; Invoke-AitherScript -Script '{script_name}' -Arguments $params }}"
        ]

        result = subprocess.run(cmd, capture_output=True, text=True, check=False)

        output = f"STDOUT:\n{result.stdout}\n\nSTDERR:\n{result.stderr}"
        if result.returncode != 0:
            output += f"\n\nExit Code: {result.returncode}"
            
            if "Script not found" in result.stderr or "Script not found" in result.stdout:
                output += "\n\n[System] Script not found. Listing available scripts for context:\n"
                output += list_automation_scripts()

        return output

    except Exception as e:
        return f"Error executing PowerShell script: {str(e)}"

def list_automation_scripts(filter: str = "") -> str:
    """
    Lists available automation scripts in the AitherZero library.
    
    Args:
        filter (str, optional): A keyword to filter scripts by name or description. Defaults to empty string (all scripts).
    """
    try:
        safe_filter = filter.replace("'", "''")
        
        cmd = [
            "pwsh", "-NoProfile", "-Command",
            f"& {{ Import-Module '{MODULE_PATH}' -Force -ErrorAction Stop; $scripts = Get-AitherScript; if ('{safe_filter}') {{ $scripts = $scripts | Where-Object {{ $_.Name -like '*{safe_filter}*' -or $_.Description -like '*{safe_filter}*' }} }}; $scripts | Select-Object Number, Name, Description | ConvertTo-Json -Depth 2 }}"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        if result.returncode != 0:
            return f"Error executing PowerShell: {result.stderr}"
            
        if not result.stdout.strip():
            return "No scripts found matching the filter."
            
        return result.stdout
    except Exception as e:
        return f"Error listing scripts: {str(e)}"

def list_playbooks(filter: str = "") -> str:
    """
    Lists available automation playbooks in the AitherZero library.
    
    Args:
        filter (str, optional): A keyword to filter playbooks by name or description.
    """
    try:
        safe_filter = filter.replace("'", "''")
        
        cmd = [
            "pwsh", "-NoProfile", "-Command",
            f"& {{ Import-Module '{MODULE_PATH}' -Force -ErrorAction Stop; $playbooks = Get-AitherPlaybook; if ('{safe_filter}') {{ $playbooks = $playbooks | Where-Object {{ $_.Name -like '*{safe_filter}*' -or $_.Description -like '*{safe_filter}*' }} }}; $playbooks | Select-Object Name, Description | ConvertTo-Json -Depth 2 }}"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        if result.returncode != 0:
            return f"Error executing PowerShell: {result.stderr}"
            
        if not result.stdout.strip():
            return "No playbooks found matching the filter."
            
        return result.stdout
    except Exception as e:
        return f"Error listing playbooks: {str(e)}"

def execute_aither_playbook(playbook_name: str, variables: Optional[dict] = None) -> str:
    """
    Executes an automation playbook.
    
    Args:
        playbook_name (str): The name of the playbook to execute.
        variables (dict, optional): Variables to pass to the playbook.
    """
    try:
        params_json = json.dumps(variables if variables else {})
        params_json_safe = params_json.replace("'", "''")
        
        cmd = [
            "pwsh", "-NoProfile", "-Command",
            f"& {{ Import-Module '{MODULE_PATH}' -Force -ErrorAction Stop; $vars = ConvertFrom-Json '{params_json_safe}' -AsHashtable; Invoke-AitherPlaybook -Name '{playbook_name}' -Variables $vars }}"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        output = f"STDOUT:\n{result.stdout}\n\nSTDERR:\n{result.stderr}"
        if result.returncode != 0:
            output += f"\n\nExit Code: {result.returncode}"
            
            if "Playbook not found" in result.stderr:
                output += "\n\n[System] Playbook not found. Listing available playbooks for context:\n"
                output += list_playbooks()
                
        return output
    except Exception as e:
        return f"Error executing playbook: {str(e)}"

def get_automation_help(target: str, type: str = 'script') -> str:
    """
    Retrieves help/documentation for a specific script or playbook.
    
    Args:
        target (str): The script ID (e.g., '0206') or playbook name (e.g., 'ci-pr-validation').
        type (str, optional): 'script' or 'playbook'. Defaults to 'script'.
    """
    try:
        cmd_str = ""
        if type.lower() == 'playbook':
            cmd_str = f"Get-AitherPlaybook -Name '{target}' | ConvertTo-Json -Depth 5"
        else:
            cmd_str = f"Get-AitherScript -Script '{target}' -ShowParameters | ConvertTo-Json -Depth 3"

        cmd = [
            "pwsh", "-NoProfile", "-Command",
            f"& {{ Import-Module '{MODULE_PATH}' -Force -ErrorAction Stop; {cmd_str} }}"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        if result.returncode != 0:
            return f"Error getting help: {result.stderr}"
            
        return result.stdout
    except Exception as e:
        return f"Error retrieving help: {str(e)}"

def get_aither_config(section: Optional[str] = None, key: Optional[str] = None) -> str:
    """
    Retrieves the current AitherZero configuration (merges base, OS, and local configs).
    
    Args:
        section (str, optional): The configuration section (e.g., 'Core', 'Automation', 'Features').
        key (str, optional): Specific key within the section (e.g., 'Environment', 'Node.Enabled').
    """
    try:
        cmd_parts = ["Get-AitherConfigs"]
        if section:
            cmd_parts.append(f"-Section '{section}'")
        if key:
            cmd_parts.append(f"-Key '{key}'")
            
        # Use -Print or ConvertTo-Json to get clean output
        cmd_parts.append("| ConvertTo-Json -Depth 5")
        
        cmd_str = " ".join(cmd_parts)
        
        cmd = [
            "pwsh", "-NoProfile", "-Command",
            f"& {{ Import-Module '{MODULE_PATH}' -Force -ErrorAction Stop; {cmd_str} }}"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        if result.returncode != 0:
            return f"Error getting config: {result.stderr}"
            
        return result.stdout
    except Exception as e:
        return f"Error getting config: {str(e)}"

def set_aither_config(section: str, key: str, value: str, scope: str = "local") -> str:
    """
    Updates AitherZero configuration. By default saves to config.local.psd1 (gitignored).
    
    Args:
        section (str): Configuration section (e.g., 'Core', 'Automation').
        key (str): Key to update (e.g., 'Environment', 'MaxConcurrency'). Use dots for nested keys.
        value (str): The value to set. Can be string, bool ($true/$false), number. 
                     Note: Complex objects should be passed as JSON strings if supported by tool logic, 
                     but simple types are safest here.
        scope (str): 'local' (default, recommended) or 'global' (modifies config.psd1).
    """
    try:
        # Determine scope switch
        scope_switch = "-Global" if scope.lower() == "global" else "-Local"
        
        # Handle value typing nicely for PowerShell
        ps_value = f"'{value}'" # Default to string
        if value.lower() == "true":
            ps_value = "$true"
        elif value.lower() == "false":
            ps_value = "$false"
        elif value.isdigit():
            ps_value = value # Pass as number
            
        cmd_str = f"Set-AitherConfig -Section '{section}' -Key '{key}' -Value {ps_value} {scope_switch} -ShowOutput | ConvertTo-Json"
        
        cmd = [
            "pwsh", "-NoProfile", "-Command",
            f"& {{ Import-Module '{MODULE_PATH}' -Force -ErrorAction Stop; {cmd_str} }}"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        if result.returncode != 0:
            return f"Error setting config: {result.stderr}"
            
        return f"Configuration updated successfully.\n{result.stdout}"
    except Exception as e:
        return f"Error setting config: {str(e)}"

def manage_mcp_server(action: str, name: Optional[str] = None, command: Optional[str] = None, args: Optional[List[str]] = None, env: Optional[Dict[str, str]] = None) -> str:
    """
    Manages MCP Servers (Model Context Protocol).
    
    Args:
        action (str): 'install' (installs local server), 'list' (shows config), 'register' (adds server to config).
        name (str, optional): Server name (required for 'register').
        command (str, optional): Command to run server (required for 'register').
        args (list[str], optional): Arguments for command.
        env (dict[str,str], optional): Environment variables.
    """
    try:
        if action.lower() == 'install':
            cmd_str = "Install-AitherMCPServer -Force -Verbose"
        
        elif action.lower() == 'list':
            cmd_str = "Get-AitherMCPConfig | ConvertTo-Json -Depth 5"
            
        elif action.lower() == 'register':
            if not name or not command:
                return "Error: 'name' and 'command' are required for 'register' action."
            
            # Use JSON serialization for robust parameter passing
            ps_params = {
                'Name': name,
                'Command': command,
                'Args': args if args else [],
                'Env': env if env else {},
                'Verbose': True
            }
            
            params_json = json.dumps(ps_params)
            params_json_safe = params_json.replace("'", "''")
            
            cmd_str = f"$p = ConvertFrom-Json '{params_json_safe}' -AsHashtable; Set-AitherMCPConfig @p"
            
        else:
            return f"Unknown action: {action}"

        cmd = [
            "pwsh", "-NoProfile", "-Command",
            f"& {{ Import-Module '{MODULE_PATH}' -Force -ErrorAction Stop; {cmd_str} }}"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        
        if result.returncode != 0:
            return f"Error executing MCP task: {result.stderr}"
            
        return result.stdout
        
    except Exception as e:
        return f"Error managing MCP server: {str(e)}"

async def execute_agent_workflow(workflow_name: str, variables: Optional[dict] = None) -> str:
    """
    Executes an Agent Workflow (multi-step orchestration) defined in YAML.
    Workflows are stored in library/agent-workflows/.
    
    Args:
        workflow_name (str): Name of the workflow file (e.g. 'test-mcp').
        variables (dict, optional): Context variables.
    """
    try:
        root = os.environ.get("AITHERZERO_ROOT", PROJECT_ROOT)
        path = os.path.join(root, "library/agent-workflows", f"{workflow_name}.yaml")
        
        engine = WorkflowEngine(mcp_client=True)
        result = await engine.execute_workflow(path, variables)
        return f"Workflow completed.\nResult Context: {json.dumps(result, indent=2)}"
    except Exception as e:
        return f"Error executing workflow: {str(e)}"

# Export as FunctionTools
aither_tools = [
    FunctionTool(execute_aither_script),
    FunctionTool(list_automation_scripts),
    FunctionTool(list_playbooks),
    FunctionTool(execute_aither_playbook),
    FunctionTool(execute_agent_workflow),
    FunctionTool(get_automation_help),
    FunctionTool(get_aither_config),
    FunctionTool(set_aither_config),
    FunctionTool(manage_mcp_server),
    # MCP Client Tools
    FunctionTool(list_mcp_servers),
    FunctionTool(list_mcp_tools),
    FunctionTool(call_mcp_tool)
]
