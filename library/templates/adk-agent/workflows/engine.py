import asyncio
import logging
from typing import Dict, Any, List, Optional
import yaml
import os

# We will reuse the MCP client to call "external agents" if defined as such
# Or use the main agent's runner if it's a local step.

class WorkflowContext:
    def __init__(self, variables: Dict[str, Any] = None):
        self.variables = variables or {}
        self.history = []
        
    def set(self, key: str, value: Any):
        self.variables[key] = value
        
    def get(self, key: str, default: Any = None) -> Any:
        return self.variables.get(key, default)

class WorkflowEngine:
    def __init__(self, mcp_client=None):
        self.mcp_client = mcp_client

    async def execute_workflow(self, workflow_path: str, initial_vars: Dict[str, Any] = None) -> Dict[str, Any]:
        """
        Executes a workflow defined in a YAML file.
        """
        if not os.path.exists(workflow_path):
            raise FileNotFoundError(f"Workflow file not found: {workflow_path}")
            
        with open(workflow_path, 'r') as f:
            definition = yaml.safe_load(f)
            
        ctx = WorkflowContext(initial_vars)
        
        await self._execute_block(definition, ctx)
        return ctx.variables

    async def _execute_block(self, block: Dict[str, Any], ctx: WorkflowContext):
        b_type = block.get('type', 'sequential')
        
        if b_type == 'sequential':
            await self._run_sequential(block, ctx)
        elif b_type == 'parallel':
            await self._run_parallel(block, ctx)
        elif b_type == 'loop':
            await self._run_loop(block, ctx)
        elif b_type == 'action':
            await self._run_action(block, ctx)
        else:
            raise ValueError(f"Unknown workflow block type: {b_type}")

    async def _run_sequential(self, block: Dict[str, Any], ctx: WorkflowContext):
        steps = block.get('steps', [])
        for step in steps:
            await self._execute_block(step, ctx)

    async def _run_parallel(self, block: Dict[str, Any], ctx: WorkflowContext):
        steps = block.get('steps', [])
        tasks = [self._execute_block(step, ctx) for step in steps] # Note: Sharing ctx in parallel might be race-condition prone if writing same vars
        await asyncio.gather(*tasks)

    async def _run_loop(self, block: Dict[str, Any], ctx: WorkflowContext):
        condition = block.get('until') # Expression string?
        max_iter = block.get('max_iterations', 5)
        body = block.get('body')
        
        count = 0
        while count < max_iter:
            await self._execute_block(body, ctx)
            count += 1
            # Check condition logic (simplified for now)
            if condition:
                # Evaluate condition against ctx.variables
                # WARNING: unsafe eval, need safer parser later.
                # For prototype, simple key check: "result.status == 'success'"
                if self._evaluate_condition(condition, ctx):
                    break
    
    def _evaluate_condition(self, condition: str, ctx: WorkflowContext) -> bool:
        # Very basic eval: "key == value"
        try:
            # Safe replacement of variables
            # Using simple python eval with limited globals is "okay" for local prototype but risky in prod
            # We'll restrict it.
            allowed_names = ctx.variables
            return eval(condition, {"__builtins__": {}}, allowed_names)
        except Exception as e:
            logging.error(f"Condition eval failed: {e}")
            return False

    async def _run_action(self, block: Dict[str, Any], ctx: WorkflowContext):
        """
        Executes an action. 
        - 'tool': Call an MCP tool or internal tool.
        - 'agent': Delegate to another agent (via MCP).
        """
        action_name = block.get('name', 'Unnamed Action')
        tool_call = block.get('tool')
        agent_call = block.get('agent')
        output_var = block.get('output')
        
        result = None
        
        if tool_call:
            # { server: "aither", name: "Get-Version", args: {...} }
            server = tool_call.get('server')
            tool = tool_call.get('name')
            args = tool_call.get('args', {})
            
            # Interpolate args
            final_args = self._interpolate_args(args, ctx)
            
            if self.mcp_client:
                # We need to import call_mcp_tool logic or pass it in
                # Since mcp_client is imported in tools, we can import it here too
                from tools.mcp_client import call_mcp_tool
                result = await call_mcp_tool(server, tool, final_args)
            else:
                result = "Error: MCP Client not available."
                
        elif agent_call:
            # Placeholder for Agent Delegation
            result = f"Delegated to {agent_call} (Simulated)"
            
        if output_var:
            ctx.set(output_var, result)
            
    def _interpolate_args(self, args: Dict, ctx: WorkflowContext) -> Dict:
        new_args = {}
        for k, v in args.items():
            if isinstance(v, str) and v.startswith("$"):
                var_name = v[1:]
                new_args[k] = ctx.get(var_name, v)
            else:
                new_args[k] = v
        return new_args
