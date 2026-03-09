#!/usr/bin/env node

/**
 * AitherZero MCP Server v2.0
 *
 * Modern Model Context Protocol server for AitherZero infrastructure automation platform.
 *
 * Features:
 * - 880+ automation scripts in library/automation-scripts/
 * - 11 functional domains in aithercore/
 * - Playbook orchestration system
 * - Configuration-driven architecture
 * - Extension system support
 * - GitHub workflow integration
 * - Prompts for guided workflows
 * - Sampling for multi-step operations
 *
 * Aligned with GitHub Copilot MCP best practices:
 * - Extended context through resources
 * - Seamless integration with multiple tools
 * - Security through minimal permissions
 * - Clear tool descriptions for agent mode
 */

import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  ListResourcesRequestSchema,
  ReadResourceRequestSchema,
  ListPromptsRequestSchema,
  GetPromptRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { spawn } from 'child_process';
import { promisify } from 'util';
import { exec as execCallback } from 'child_process';
import * as path from 'path';
import * as os from 'os';

const exec = promisify(execCallback);

// Configuration
const AITHERZERO_ROOT = process.env.AITHERZERO_ROOT || '/workspaces/AitherZero';
const PWSH_PATH = 'pwsh';
const NONINTERACTIVE = process.env.AITHERZERO_NONINTERACTIVE === '1';

/**
 * Execute a PowerShell command and return the result
 * Handles non-interactive mode for CI/automation environments
 *
 * Uses -EncodedCommand on Windows to avoid cmd.exe breaking on
 * multi-line double-quoted strings.  Falls back to -Command with
 * newlines collapsed to semicolons on other platforms.
 */
async function executePowerShell(script: string): Promise<{ stdout: string; stderr: string }> {
  try {
    const nonInteractiveFlag = NONINTERACTIVE ? '-NonInteractive' : '';

    let cmd: string;
    if (os.platform() === 'win32') {
      // Windows: cmd.exe silently truncates multi-line "-Command" strings.
      // Encode the script as UTF-16LE base64 for -EncodedCommand.
      const encoded = Buffer.from(script, 'utf16le').toString('base64');
      cmd = `${PWSH_PATH} -NoProfile ${nonInteractiveFlag} -EncodedCommand ${encoded}`;
    } else {
      // Unix: shell handles multi-line strings fine, but collapse anyway for safety.
      const collapsed = script.replace(/\r?\n/g, '; ').replace(/;(\s*;)+/g, ';');
      cmd = `${PWSH_PATH} -NoProfile ${nonInteractiveFlag} -Command "${collapsed.replace(/"/g, '\\"')}"`;
    }

    const { stdout, stderr } = await exec(cmd, { maxBuffer: 10 * 1024 * 1024 });
    return { stdout, stderr };
  } catch (error: any) {
    return {
      stdout: error.stdout || '',
      stderr: error.stderr || error.message
    };
  }
}

/**
 * Execute an AitherZero script by number using new CLI cmdlets
 */
async function executeAitherScript(
  scriptNumber: string,
  params: Record<string, any> = {},
  options: { verbose?: boolean; dryRun?: boolean; showOutput?: boolean } = {}
): Promise<string> {
  const paramString = Object.entries(params)
    .map(([key, value]) => `-${key} ${JSON.stringify(value)}`)
    .join(' ');

  const flags = [];
  if (options.verbose) flags.push('-Verbose');
  if (options.dryRun) flags.push('-DryRun');
  if (options.showOutput) flags.push('-ShowOutput');
  const flagsStr = flags.join(' ');

  // Escape single quotes for PowerShell string if needed, though JSON.stringify usually handles most
  // We pass parameters via -Arguments which accepts a string of arguments
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber ${scriptNumber} -Arguments '${paramString}' ${flagsStr} | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Get list of available automation scripts using new CLI cmdlets
 */
async function listAutomationScripts(category?: string): Promise<string> {
  const categoryParam = category ? `-Category '${category}'` : '';
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Get-AitherScript ${categoryParam} | Format-Table -AutoSize | Out-String
  `;

  const { stdout } = await executePowerShell(command);
  return stdout;
}

/**
 * Search automation scripts by keyword using new CLI cmdlets
 */
async function searchScripts(query: string): Promise<string> {
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Get-AitherScript -Search '${query}' | Format-Table -AutoSize | Out-String
  `;

  const { stdout } = await executePowerShell(command);
  return stdout;
}

/**
 * Execute a playbook using new CLI cmdlets
 */
async function executePlaybook(playbookName: string, profile?: string, variables: Record<string, any> = {}): Promise<string> {
  const profileParam = profile ? `-Profile ${profile}` : '';

  // Serialize variables to hashtable string for PowerShell
  // Note: This is a simple serialization, complex objects might need better handling
  let varsParam = '';
  if (Object.keys(variables).length > 0) {
    const varsJson = JSON.stringify(variables).replace(/'/g, "''");
    varsParam = `-Variables (ConvertFrom-Json '${varsJson}' -AsHashtable)`;
  }

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherPlaybook -Name ${playbookName} ${profileParam} ${varsParam} | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Get configuration value using correct function name
 */
async function getConfiguration(section?: string, key?: string): Promise<string> {
  const sectionParam = section ? `-Section '${section}'` : '';
  const keyParam = key ? `-Key '${key}'` : '';
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Get-Configuration ${sectionParam} ${keyParam} | ConvertTo-Json -Depth 10
  `;

  const { stdout } = await executePowerShell(command);
  return stdout;
}

/**
 * Set configuration value
 */
async function setConfiguration(section: string, key: string, value: string | number | boolean, scope: string = 'local'): Promise<string> {
  const scopeSwitch = scope.toLowerCase() === 'global' ? '-Global' : '-Local';

  let psValue = `'${value}'`;
  if (typeof value === 'boolean') {
    psValue = value ? '$true' : '$false';
  } else if (typeof value === 'number') {
    psValue = value.toString();
  }

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Set-AitherConfig -Section '${section}' -Key '${key}' -Value ${psValue} ${scopeSwitch} -ShowOutput | ConvertTo-Json
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : `Configuration updated successfully.\n${stdout}`;
}

/**
 * Get automation help/documentation
 */
async function getAutomationHelp(target: string, type: string = 'script'): Promise<string> {
  let cmdStr = '';
  if (type.toLowerCase() === 'playbook') {
    cmdStr = `Get-AitherPlaybook -Name '${target}' | ConvertTo-Json -Depth 5`;
  } else {
    cmdStr = `Get-AitherScript -Script '${target}' -ShowParameters | ConvertTo-Json -Depth 3`;
  }

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    ${cmdStr}
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Manage MCP Server configuration
 */
async function manageMCPServer(action: string, name?: string, commandStr?: string, args?: string[], env?: Record<string, string>): Promise<string> {
  let cmdStr = '';

  if (action.toLowerCase() === 'install') {
    cmdStr = 'Install-AitherMCPServer -Force -Verbose';
  } else if (action.toLowerCase() === 'list') {
    cmdStr = 'Get-AitherMCPConfig | ConvertTo-Json -Depth 5';
  } else if (action.toLowerCase() === 'register') {
    if (!name || !commandStr) {
      return "Error: 'name' and 'command' are required for 'register' action.";
    }

    const psParams = {
      Name: name,
      Command: commandStr,
      Args: args || [],
      Env: env || {},
      Verbose: true
    };

    // Escape single quotes for PowerShell
    const paramsJson = JSON.stringify(psParams).replace(/'/g, "''");
    cmdStr = `$p = ConvertFrom-Json '${paramsJson}' -AsHashtable; Set-AitherMCPConfig @p`;
  } else {
    return `Unknown action: ${action}`;
  }

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    ${cmdStr}
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Run Pester tests
 */
async function runTests(path?: string, tag?: string): Promise<string> {
  const argsParts = [];
  if (path) argsParts.push(`-Path '${path}'`);
  if (tag) argsParts.push(`-Tag '${tag}'`);
  const argsString = argsParts.join(' ');

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber 0402 -Arguments "${argsString}" | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Run quality validation - updated path to aithercore
 */
async function runQualityCheck(path?: string): Promise<string> {
  const pathParam = path ? `-Path '${path}'` : '-Path ./AitherZero/src -Recursive';
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber 0404 -Arguments "${pathParam}" | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Validate component quality
 */
async function validateComponent(path: string): Promise<string> {
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber 0908 -Arguments "-Path '${path}'" | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Get system information
 */
async function getSystemInfo(
  sections?: string,
  quick?: boolean,
  format?: string
): Promise<string> {
  const sectionsArg = sections ? `-Sections '${sections.replace(/'/g, "''")}'` : '';
  const quickArg = quick ? '-Quick' : '';
  const formatArg = format ? `-OutputFormat ${format}` : '-OutputFormat Json';

  const command = `
    cd '${AITHERZERO_ROOT}'
    $script = Get-ChildItem -Recurse -Path './AitherZero/library/automation-scripts' -Filter '0011_Get-SystemFingerprint.ps1' | Select-Object -First 1
    if ($script) {
      & $script.FullName ${sectionsArg} ${quickArg} ${formatArg} | Out-String
    } else {
      Import-Module ./AitherZero/AitherZero.psd1 -Force -ErrorAction SilentlyContinue
      Invoke-AitherScript -ScriptNumber 0011 ${quickArg} | Out-String
    }
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Get logs
 */
async function getLogs(lines: number = 100): Promise<string> {
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber 0514 -Arguments "-Lines ${lines}" | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Get project report with comprehensive metrics
 */
async function getProjectReport(format?: string): Promise<string> {
  const formatParam = format ? `-Format ${format}` : '';
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber 0510 -Arguments "-ShowAll ${formatParam}" | Out-String
  `;

  const { stdout } = await executePowerShell(command);
  return stdout;
}

/**
 * List available playbooks
 */
async function listPlaybooks(): Promise<string> {
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Get-AitherPlaybook | Format-Table -AutoSize | Out-String
  `;

  const { stdout } = await executePowerShell(command);
  return stdout;
}

/**
 * Get information about aithercore domains
 */
async function getDomainInfo(domain?: string): Promise<string> {
  const domainParam = domain ? ` | Where-Object Name -eq '${domain}'` : '';
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Get-ChildItem ./AitherZero/src/public -Directory${domainParam} |
      ForEach-Object {
        [PSCustomObject]@{
          Domain = $_.Name
          Modules = (Get-ChildItem $_.FullName -Filter *.ps1).Count
          Path = $_.FullName
        }
      } | Format-Table -AutoSize | Out-String
  `;

  const { stdout } = await executePowerShell(command);
  return stdout;
}

/**
 * List available extensions
 */
async function listExtensions(): Promise<string> {
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Get-ChildItem ./extensions -Directory |
      ForEach-Object {
        $manifest = Join-Path $_.FullName 'extension.psd1'
        if (Test-Path $manifest) {
          $ext = Import-PowerShellDataFile $manifest
          [PSCustomObject]@{
            Name = $ext.Name
            Version = $ext.Version
            Description = $ext.Description
            Enabled = $ext.Enabled
          }
        }
      } | Format-Table -AutoSize | Out-String
  `;

  const { stdout } = await executePowerShell(command);
  return stdout;
}

/**
 * Get GitHub workflow status
 */
async function getWorkflowStatus(): Promise<string> {
  const command = `
    cd '${AITHERZERO_ROOT}'
    gh workflow list --json name,state,id 2>$null | ConvertFrom-Json | Format-Table -AutoSize | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr && stderr.includes('not found')
    ? 'GitHub CLI not available or not authenticated'
    : stdout;
}

/**
 * Generate documentation (Placeholder - script 0530 not found)
 */
/*
async function generateDocumentation(domain?: string): Promise<string> {
  const domainParam = domain ? `-Domain '${domain}'` : '';
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber 0530 ${domainParam} | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}
*/

/**
 * Build and import AitherZero module
 */
async function buildAndImportModule(): Promise<string> {
  const command = `
    cd '${AITHERZERO_ROOT}'
    ./AitherZero/build.ps1
    Copy-Item -Path ./AitherZero/bin/AitherZero.psm1 -Destination ./AitherZero/AitherZero.psm1 -Force
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    "Module built and imported successfully. Version: $((Get-Module AitherZero).Version)"
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Create a new AitherZero project
 */
async function createProject(
  path: string,
  name?: string,
  template: string = 'Standard',
  language: string = 'PowerShell',
  includeCI: boolean = false,
  includeVSCode: boolean = false,
  includeModule: boolean = false,
  gitInit: boolean = false,
  registerProject: boolean = false,
  force: boolean = false
): Promise<string> {
  const argsParts = [`-Path '${path}'`];
  if (name) argsParts.push(`-Name '${name}'`);
  if (template) argsParts.push(`-Template '${template}'`);
  if (language) argsParts.push(`-Language '${language}'`);
  if (includeCI) argsParts.push('-IncludeCI');
  if (includeVSCode) argsParts.push('-IncludeVSCode');
  if (includeModule) argsParts.push('-IncludeModule');
  if (gitInit) argsParts.push('-GitInit');
  if (registerProject) argsParts.push('-RegisterProject');
  if (force) argsParts.push('-Force');

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    New-AitherProject ${argsParts.join(' ')} -ShowOutput
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * List registered AitherZero projects
 */
async function listProjects(name?: string): Promise<string> {
  const nameParam = name ? `-Name '${name}'` : '';
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Get-AitherProject ${nameParam} | Format-Table -AutoSize | Out-String
  `;

  const { stdout } = await executePowerShell(command);
  return stdout;
}

/**
 * Register an existing project
 */
async function registerProject(path: string, name: string, language?: string, template?: string): Promise<string> {
  const argsParts = [`-Path '${path}'`, `-Name '${name}'`];
  if (language) argsParts.push(`-Language '${language}'`);
  if (template) argsParts.push(`-Template '${template}'`);

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Register-AitherProject ${argsParts.join(' ')} | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Invoke an AI agent via CLI
 */
async function invokeAgent(agent: string, prompt: string, context?: string): Promise<string> {
  // Escape arguments for PowerShell
  // Note: Simple escaping, might need more robust handling for complex strings
  const safePrompt = prompt.replace(/'/g, "''");
  const contextParam = context ? `-Context '${context.replace(/'/g, "''")}'` : '';

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherAgent -Agent '${agent}' -Prompt '${safePrompt}' ${contextParam} | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Manage secrets
 */
async function manageSecrets(action: string, key?: string, value?: string, scope?: string): Promise<string> {
  const argsParts = [`-Action '${action}'`];
  if (key) argsParts.push(`-Key '${key}'`);
  if (value) argsParts.push(`-Value '${value}'`);
  if (scope) argsParts.push(`-Scope '${scope}'`);
  const argsString = argsParts.join(' ');

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber 0601 -Arguments "${argsString}" | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Manage SSH keys
 */
async function manageSSHKeys(email: string, name?: string, type?: string): Promise<string> {
  const argsParts = [`-Email '${email}'`];
  if (name) argsParts.push(`-Name '${name}'`);
  if (type) argsParts.push(`-Type '${type}'`);
  const argsString = argsParts.join(' ');

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber 0602 -Arguments "${argsString}" | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Git operations
 */
async function gitOperations(operation: string, args: Record<string, any>): Promise<string> {
  let scriptNumber = '';
  const argsParts = [];

  switch (operation) {
    case 'create_branch':
      scriptNumber = '0701';
      if (args.name) argsParts.push(`-Name '${args.name}'`);
      if (args.base) argsParts.push(`-Base '${args.base}'`);
      break;
    case 'commit':
      scriptNumber = '0702';
      if (args.message) argsParts.push(`-Message '${args.message}'`);
      if (args.files) argsParts.push(`-Files '${args.files}'`);
      break;
    case 'create_pr':
      scriptNumber = '0703';
      if (args.title) argsParts.push(`-Title '${args.title}'`);
      if (args.body) argsParts.push(`-Body '${args.body}'`);
      if (args.draft) argsParts.push('-Draft');
      break;
    default:
      return `Unknown git operation: ${operation}`;
  }

  const argsString = argsParts.join(' ');
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber ${scriptNumber} -Arguments "${argsString}" | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Repo Sync — commit and push to all repos (origin, AitherZero public, Alpha)
 */
async function repoSync(action: string, args: Record<string, any>): Promise<string> {
  const argsParts = [];

  switch (action) {
    case 'push_all': {
      // Use the master sync script 7011
      if (args.message) argsParts.push(`-Message '${args.message}'`);
      if (args.force) argsParts.push('-Force');
      if (args.dry_run) argsParts.push('-DryRun');
      if (args.skip_commit) argsParts.push('-SkipCommit');
      if (args.aitherzero_only) argsParts.push('-AitherZeroOnly');

      const command = `
        cd '${AITHERZERO_ROOT}'
        & ./AitherZero/library/automation-scripts/70-git/7011_Sync-AllRepos.ps1 ${argsParts.join(' ')} | Out-String
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'sync_aitherzero': {
      // Sync just AitherZero to public
      if (args.message) argsParts.push(`-Message '${args.message}'`);
      if (args.dry_run) argsParts.push('-DryRun');
      const direction = args.direction || 'push';

      const command = `
        cd '${AITHERZERO_ROOT}'
        & ./AitherZero/library/automation-scripts/70-git/7010_Sync-OpenSource.ps1 -Direction ${direction} ${argsParts.join(' ')} | Out-String
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'status': {
      const command = `
        cd '${AITHERZERO_ROOT}'
        $status = @{}
        $status['branch'] = git symbolic-ref --short HEAD 2>$null
        $status['commit'] = git rev-parse --short HEAD 2>$null
        $status['pending'] = (git status --porcelain 2>$null).Count
        $status['ahead_origin'] = [int](git rev-list 'origin/develop..HEAD' --count 2>$null)
        $remotes = git remote -v 2>$null
        $status['remotes'] = ($remotes | Select-Object -Unique) -join "\\n"
        $status | ConvertTo-Json -Depth 3
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    default:
      return `Unknown repo_sync action: ${action}. Available: push_all, sync_aitherzero, status`;
  }
}

/**
 * Infrastructure Manage — comprehensive infrastructure status and replication monitoring
 */
async function infrastructureManage(action: string, args: Record<string, any>): Promise<string> {
  switch (action) {
    case 'status': {
      const argsParts = [];
      if (args.include_replication) argsParts.push('-IncludeReplication');
      if (args.include_containers) argsParts.push('-IncludeContainers');
      if (args.check_remote_nodes) argsParts.push('-CheckRemoteNodes');
      if (args.format) argsParts.push(`-Format '${args.format}'`);
      argsParts.push('-PassThru');

      const command = `
        cd '${AITHERZERO_ROOT}'
        Import-Module ./AitherZero/AitherZero.psd1 -Force -ErrorAction SilentlyContinue
        Get-AitherInfraStatus ${argsParts.join(' ')} | ConvertTo-Json -Depth 5
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'replication': {
      const argsParts = [];
      if (args.include_details) argsParts.push('-IncludeDetails');
      if (args.node_hosts && Array.isArray(args.node_hosts)) {
        argsParts.push(`-NodeHosts @('${args.node_hosts.join("','")}')`);
      }
      argsParts.push('-PassThru');

      const command = `
        cd '${AITHERZERO_ROOT}'
        Import-Module ./AitherZero/AitherZero.psd1 -Force -ErrorAction SilentlyContinue
        Get-AitherReplicationStatus ${argsParts.join(' ')} | ConvertTo-Json -Depth 5
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'mesh': {
      const meshAction = args.mesh_action || 'Status';
      const argsParts = [`-Action '${meshAction}'`];
      if (args.node_name) argsParts.push(`-NodeName '${args.node_name}'`);
      if (args.target_role) argsParts.push(`-TargetRole '${args.target_role}'`);
      argsParts.push('-PassThru');

      const command = `
        cd '${AITHERZERO_ROOT}'
        Import-Module ./AitherZero/AitherZero.psd1 -Force -ErrorAction SilentlyContinue
        Get-AitherMeshStatus ${argsParts.join(' ')} | ConvertTo-Json -Depth 5
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    default:
      return `Unknown infrastructure_manage action: ${action}. Available: status, replication, mesh`;
  }
}

/**
 * Node Deploy — manage remote node lifecycle (deploy, status, update, restart, remove)
 */
async function nodeDeploy(action: string, args: Record<string, any>): Promise<string> {
  const argsParts = [`-Action '${action}'`];

  if (args.computer_name) {
    const hosts = Array.isArray(args.computer_name) ? args.computer_name : [args.computer_name];
    argsParts.push(`-ComputerName @('${hosts.join("','")}')`);
  }
  if (args.credential_name) argsParts.push(`-CredentialName '${args.credential_name}'`);
  if (args.profile) argsParts.push(`-Profile '${args.profile}'`);
  if (args.gpu) argsParts.push('-GPU');
  if (args.failover_priority) argsParts.push(`-FailoverPriority ${args.failover_priority}`);
  if (args.skip_bootstrap) argsParts.push('-SkipBootstrap');
  if (args.skip_replication) argsParts.push('-SkipReplication');
  if (args.start_watchdog) argsParts.push('-StartWatchdog');
  if (args.dry_run) argsParts.push('-DryRun');
  if (args.force) argsParts.push('-Force');
  argsParts.push('-PassThru');

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force -ErrorAction SilentlyContinue
    Invoke-AitherNodeDeploy ${argsParts.join(' ')} | ConvertTo-Json -Depth 5
  `;
  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Windows ISO Pipeline — build custom ISOs and deploy VMs via OpenTofu + Hyper-V
 */
async function windowsIsoPipeline(action: string, args: Record<string, any>): Promise<string> {
  switch (action) {
    case 'build': {
      const argsParts = [];
      if (args.source_iso) argsParts.push(`-SourceISO '${args.source_iso}'`);
      if (args.computer_name) argsParts.push(`-ComputerName '${args.computer_name}'`);
      if (args.node_profile) argsParts.push(`-NodeProfile '${args.node_profile}'`);
      if (args.include_openssh) argsParts.push('-IncludeOpenSSH');
      if (args.include_hyperv) argsParts.push('-IncludeHyperV');
      if (args.mesh_core_url) argsParts.push(`-MeshCoreUrl '${args.mesh_core_url}'`);
      if (args.output_name) argsParts.push(`-OutputName '${args.output_name}'`);
      if (args.dry_run) argsParts.push('-DryRun');

      const command = `
        cd '${AITHERZERO_ROOT}'
        & ./AitherZero/library/automation-scripts/31-remote/3105_Build-WindowsISO.ps1 ${argsParts.join(' ')} 2>&1 | Out-String
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'deploy': {
      const argsParts = [];
      if (args.source_iso) argsParts.push(`-SourceISO '${args.source_iso}'`);
      if (args.iso_path) argsParts.push(`-ISOPath '${args.iso_path}' -SkipISOBuild`);
      if (args.node_names && Array.isArray(args.node_names)) {
        argsParts.push(`-NodeName @('${args.node_names.join("','")}')`);
      }
      if (args.node_count) argsParts.push(`-NodeCount ${args.node_count}`);
      if (args.profile) argsParts.push(`-Profile '${args.profile}'`);
      if (args.cpu_count) argsParts.push(`-CpuCount ${args.cpu_count}`);
      if (args.memory_gb) argsParts.push(`-MemoryGB ${args.memory_gb}`);
      if (args.disk_gb) argsParts.push(`-DiskGB ${args.disk_gb}`);
      if (args.switch_name) argsParts.push(`-SwitchName '${args.switch_name}'`);
      if (args.auto_approve) argsParts.push('-TofuAutoApprove');
      if (args.skip_post_install) argsParts.push('-SkipPostInstall');
      if (args.dry_run) argsParts.push('-DryRun');
      argsParts.push('-PassThru');

      const command = `
        cd '${AITHERZERO_ROOT}'
        Import-Module ./AitherZero/AitherZero.psd1 -Force -ErrorAction SilentlyContinue
        New-AitherWindowsISO ${argsParts.join(' ')} | ConvertTo-Json -Depth 5
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'status': {
      const command = `
        cd '${AITHERZERO_ROOT}/AitherZero/library/infrastructure/environments/local-hyperv'
        $tofuCmd = if (Get-Command tofu -ErrorAction SilentlyContinue) { 'tofu' } else { 'terraform' }
        $output = & $tofuCmd output -json 2>&1 | Out-String
        $state = & $tofuCmd show -json 2>&1 | Out-String
        @{ TofuOutput = $output; StateResources = ($state | ConvertFrom-Json -ErrorAction SilentlyContinue).values.root_module.resources.Count } | ConvertTo-Json -Depth 3
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'destroy': {
      const argsParts = ['-no-color'];
      if (args.auto_approve) argsParts.push('-auto-approve');

      const command = `
        cd '${AITHERZERO_ROOT}/AitherZero/library/infrastructure/environments/local-hyperv'
        $tofuCmd = if (Get-Command tofu -ErrorAction SilentlyContinue) { 'tofu' } else { 'terraform' }
        & $tofuCmd destroy ${argsParts.join(' ')} 2>&1 | Out-String
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    default:
      return `Unknown windows_iso_pipeline action: ${action}. Available: build, deploy, status, destroy`;
  }
}

/**
 * Ring Deploy — manage ring-based deployments
 */
async function ringDeploy(action: string, args: Record<string, any>): Promise<string> {
  const argsParts = [];

  switch (action) {
    case 'status': {
      const ring = args.ring || 'all';
      const command = `
        cd '${AITHERZERO_ROOT}'
        & ./AitherZero/library/automation-scripts/30-deploy/3025_Ring-Deploy.ps1 -Action status -Ring ${ring} -NonInteractive | Out-String
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'promote': {
      const from = args.from || 'dev';
      const to = args.to || 'staging';
      argsParts.push(`-From ${from}`, `-To ${to}`);
      if (args.approve || args.auto_approve) argsParts.push('-Approve');
      if (args.skip_tests) argsParts.push('-SkipTests');
      if (args.skip_build) argsParts.push('-SkipBuild');
      if (args.dry_run) argsParts.push('-DryRun');
      if (args.force) argsParts.push('-Force');
      argsParts.push('-NonInteractive');

      const command = `
        cd '${AITHERZERO_ROOT}'
        & ./AitherZero/library/automation-scripts/30-deploy/3025_Ring-Deploy.ps1 -Action promote ${argsParts.join(' ')} | Out-String
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'history': {
      const ring = args.ring || 'all';
      const command = `
        cd '${AITHERZERO_ROOT}'
        & ./AitherZero/library/automation-scripts/30-deploy/3025_Ring-Deploy.ps1 -Action history -Ring ${ring} -NonInteractive | Out-String
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    case 'rollback': {
      const ring = args.ring || 'dev';
      argsParts.push(`-Ring ${ring}`);
      if (args.dry_run) argsParts.push('-DryRun');
      argsParts.push('-NonInteractive');

      const command = `
        cd '${AITHERZERO_ROOT}'
        & ./AitherZero/library/automation-scripts/30-deploy/3025_Ring-Deploy.ps1 -Action rollback ${argsParts.join(' ')} | Out-String
      `;
      const { stdout, stderr } = await executePowerShell(command);
      return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
    }
    default:
      return `Unknown ring_deploy action: ${action}. Available: status, promote, history, rollback`;
  }
}

/**
 * Manage Agent Project
 */
async function manageAgentProject(action: string, args: Record<string, any>): Promise<string> {
  let scriptNumber = '';
  const argsParts = [];

  switch (action) {
    case 'create':
      scriptNumber = '0750';
      if (args.name) argsParts.push(`-Name '${args.name}'`);
      if (args.path) argsParts.push(`-Path '${args.path}'`);
      break;
    case 'configure_creds':
      scriptNumber = '0751';
      break;
    case 'setup_venv':
      scriptNumber = '0752';
      if (args.path) argsParts.push(`-Path '${args.path}'`);
      break;
    case 'new_subagent':
      scriptNumber = '0753';
      if (args.name) argsParts.push(`-Name '${args.name}'`);
      if (args.parent) argsParts.push(`-Parent '${args.parent}'`);
      break;
    default:
      return `Unknown agent project action: ${action}`;
  }

  const argsString = argsParts.join(' ');
  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber ${scriptNumber} -Arguments "${argsString}" | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Release management operations
 * Wraps the 2010_Manage-Version.ps1 script for version bumping, tagging, and release lifecycle
 */
async function releaseManagement(action: string, args: Record<string, any>): Promise<string> {
  const argsParts: string[] = [];

  switch (action) {
    case 'show':
      // Show current versions across all version files
      argsParts.push('-Action show');
      break;

    case 'bump':
      argsParts.push('-Action bump');
      if (args.component) argsParts.push(`-Component '${args.component}'`);
      break;

    case 'set':
      argsParts.push('-Action set');
      if (args.version) argsParts.push(`-Version '${args.version}'`);
      break;

    case 'tag':
      argsParts.push('-Action tag');
      if (args.version) argsParts.push(`-Version '${args.version}'`);
      break;

    case 'prepare':
      argsParts.push('-Action prepare');
      if (args.component) argsParts.push(`-Component '${args.component}'`);
      if (args.push) argsParts.push('-Push');
      break;

    case 'validate':
      argsParts.push('-Action validate');
      if (args.version) argsParts.push(`-Version '${args.version}'`);
      break;

    case 'history':
      argsParts.push('-Action history');
      break;

    default:
      return `Unknown release action: ${action}. Valid actions: show, bump, set, tag, prepare, validate, history`;
  }

  const argsString = argsParts.join(' ');
  const command = `
    cd '${AITHERZERO_ROOT}'
    & './AitherZero/library/automation-scripts/20-build/2010_Manage-Version.ps1' ${argsString} | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Trigger GitHub Actions release workflows via gh CLI
 */
async function triggerReleaseWorkflow(
  workflow: 'release-manager' | 'release-rollback',
  inputs: Record<string, string>
): Promise<string> {
  const inputFlags = Object.entries(inputs)
    .map(([key, value]) => `-f ${key}=${value}`)
    .join(' ');

  const command = `
    cd '${AITHERZERO_ROOT}'
    gh workflow run '${workflow}.yml' ${inputFlags} 2>&1
    if ($LASTEXITCODE -eq 0) {
      Write-Output "Workflow '${workflow}' triggered successfully"
      Start-Sleep -Seconds 2
      gh run list --workflow='${workflow}.yml' --limit 1 --json status,conclusion,databaseId,createdAt | ConvertFrom-Json | ForEach-Object {
        Write-Output "Run ID: $($_.databaseId) | Status: $($_.status) | Created: $($_.createdAt)"
      }
    } else {
      Write-Output "Failed to trigger workflow '${workflow}'"
    }
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * Scan disk usage
 */
async function scanDiskUsage(path?: string, depth?: number): Promise<string> {
  const argsParts = [];
  if (path) argsParts.push(`-Path '${path}'`);
  if (depth) argsParts.push(`-Depth ${depth}`);
  const argsString = argsParts.join(' ');

  const command = `
    cd '${AITHERZERO_ROOT}'
    Import-Module ./AitherZero/AitherZero.psd1 -Force
    Invoke-AitherScript -ScriptNumber 9010 -Arguments "${argsString}" | Out-String
  `;

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

// Create MCP server

/**
 * GitHub Issues management via gh CLI
 */
async function manageGitHubIssues(
  action: string,
  args: Record<string, any> = {}
): Promise<string> {
  let command: string;

  switch (action) {
    case 'list':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh issue list --state '${args.state || 'open'}' --limit ${args.limit || 20} --json number,title,state,labels,assignees,createdAt,updatedAt | ConvertFrom-Json | Format-Table -AutoSize | Out-String
      `;
      break;
    case 'get':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh issue view ${args.number} --json number,title,state,body,labels,assignees,comments | ConvertFrom-Json | ConvertTo-Json -Depth 5
      `;
      break;
    case 'create':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh issue create --title '${(args.title || '').replace(/'/g, "''")}' --body '${(args.body || '').replace(/'/g, "''")}' ${args.labels ? `--label '${args.labels}'` : ''} ${args.assignee ? `--assignee '${args.assignee}'` : ''}
      `;
      break;
    case 'update':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh issue edit ${args.number} ${args.title ? `--title '${args.title.replace(/'/g, "''")}'` : ''} ${args.body ? `--body '${args.body.replace(/'/g, "''")}'` : ''} ${args.add_labels ? `--add-label '${args.add_labels}'` : ''} ${args.remove_labels ? `--remove-label '${args.remove_labels}'` : ''}
      `;
      break;
    case 'close':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh issue close ${args.number} ${args.reason ? `--reason '${args.reason}'` : ''}
      `;
      break;
    case 'reopen':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh issue reopen ${args.number}
      `;
      break;
    case 'comment':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh issue comment ${args.number} --body '${(args.body || '').replace(/'/g, "''")}'
      `;
      break;
    case 'search':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh issue list --search '${(args.query || '').replace(/'/g, "''")}' --state '${args.state || 'open'}' --limit ${args.limit || 20} --json number,title,state,labels,createdAt | ConvertFrom-Json | Format-Table -AutoSize | Out-String
      `;
      break;
    default:
      return `Unknown issue action: ${action}. Valid: list, get, create, update, close, reopen, comment, search`;
  }

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * GitHub Pull Requests management via gh CLI
 */
async function manageGitHubPRs(
  action: string,
  args: Record<string, any> = {}
): Promise<string> {
  let command: string;

  switch (action) {
    case 'list':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh pr list --state '${args.state || 'open'}' --limit ${args.limit || 20} --json number,title,state,headRefName,baseRefName,author,createdAt,isDraft | ConvertFrom-Json | Format-Table -AutoSize | Out-String
      `;
      break;
    case 'get':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh pr view ${args.number} --json number,title,state,body,headRefName,baseRefName,author,reviews,comments,mergeable,additions,deletions | ConvertFrom-Json | ConvertTo-Json -Depth 5
      `;
      break;
    case 'create':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh pr create --title '${(args.title || '').replace(/'/g, "''")}' --body '${(args.body || '').replace(/'/g, "''")}' ${args.head ? `--head '${args.head}'` : ''} ${args.base ? `--base '${args.base}'` : ''} ${args.draft ? '--draft' : ''} ${args.reviewer ? `--reviewer '${args.reviewer}'` : ''}
      `;
      break;
    case 'merge':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh pr merge ${args.number} --${args.method || 'squash'} ${args.delete_branch ? '--delete-branch' : ''} ${args.auto ? '--auto' : ''}
      `;
      break;
    case 'review':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh pr review ${args.number} --${args.event || 'comment'} --body '${(args.body || 'LGTM').replace(/'/g, "''")}'
      `;
      break;
    case 'close':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh pr close ${args.number}
      `;
      break;
    case 'diff':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh pr diff ${args.number} | Select-Object -First 200 | Out-String
      `;
      break;
    case 'checks':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh pr checks ${args.number} --json name,state,conclusion,startedAt,completedAt | ConvertFrom-Json | Format-Table -AutoSize | Out-String
      `;
      break;
    default:
      return `Unknown PR action: ${action}. Valid: list, get, create, merge, review, close, diff, checks`;
  }

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

/**
 * GitHub Actions management and analytics via gh CLI
 */
async function manageGitHubActions(
  action: string,
  args: Record<string, any> = {}
): Promise<string> {
  let command: string;

  switch (action) {
    case 'list-runs':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh run list --limit ${args.limit || 20} ${args.workflow ? `--workflow '${args.workflow}'` : ''} ${args.status ? `--status '${args.status}'` : ''} --json databaseId,displayTitle,status,conclusion,workflowName,createdAt,updatedAt | ConvertFrom-Json | Format-Table -AutoSize | Out-String
      `;
      break;
    case 'get-run':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh run view ${args.run_id} --json databaseId,displayTitle,status,conclusion,workflowName,jobs,createdAt,updatedAt | ConvertFrom-Json | ConvertTo-Json -Depth 5
      `;
      break;
    case 'list-workflows':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh workflow list --json id,name,state,path | ConvertFrom-Json | Format-Table -AutoSize | Out-String
      `;
      break;
    case 'trigger':
      const inputFlags = args.inputs
        ? Object.entries(args.inputs as Record<string, string>).map(([k, v]) => `-f ${k}=${v}`).join(' ')
        : '';
      command = `
        cd '${AITHERZERO_ROOT}'
        gh workflow run '${args.workflow}' ${inputFlags} ${args.ref ? `--ref '${args.ref}'` : ''}
        if ($LASTEXITCODE -eq 0) {
          Write-Output "Workflow '${args.workflow}' triggered successfully"
          Start-Sleep -Seconds 2
          gh run list --workflow='${args.workflow}' --limit 1 --json databaseId,status,createdAt | ConvertFrom-Json | ForEach-Object {
            Write-Output "Run ID: $($_.databaseId) | Status: $($_.status)"
          }
        }
      `;
      break;
    case 'cancel':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh run cancel ${args.run_id}
      `;
      break;
    case 'rerun':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh run rerun ${args.run_id} ${args.failed_only ? '--failed' : ''}
      `;
      break;
    case 'download-logs':
      command = `
        cd '${AITHERZERO_ROOT}'
        gh run view ${args.run_id} --log | Select-Object -Last ${args.lines || 100} | Out-String
      `;
      break;
    case 'analytics':
      command = `
        cd '${AITHERZERO_ROOT}'
        $runs = gh run list --limit ${args.limit || 100} --json databaseId,displayTitle,status,conclusion,workflowName,createdAt,updatedAt 2>$null | ConvertFrom-Json
        $total = $runs.Count
        $success = ($runs | Where-Object { $_.conclusion -eq 'success' }).Count
        $failed = ($runs | Where-Object { $_.conclusion -eq 'failure' }).Count
        $cancelled = ($runs | Where-Object { $_.conclusion -eq 'cancelled' }).Count
        $inProgress = ($runs | Where-Object { $_.status -eq 'in_progress' }).Count
        $rate = if ($total -gt 0) { [math]::Round(($success / $total) * 100, 1) } else { 0 }
        $byWorkflow = $runs | Group-Object workflowName | ForEach-Object {
          $wfRuns = $_.Group
          $wfSuccess = ($wfRuns | Where-Object { $_.conclusion -eq 'success' }).Count
          $wfRate = if ($wfRuns.Count -gt 0) { [math]::Round(($wfSuccess / $wfRuns.Count) * 100, 1) } else { 0 }
          [PSCustomObject]@{ Workflow = $_.Name; Total = $wfRuns.Count; Success = $wfSuccess; Rate = "$wfRate%"; }
        }
        Write-Output "=== GitHub Actions Analytics ==="
        Write-Output "Total Runs: $total | Success: $success | Failed: $failed | Cancelled: $cancelled | In Progress: $inProgress"
        Write-Output "Overall Success Rate: $rate%"
        Write-Output ""
        Write-Output "=== Per Workflow ==="
        $byWorkflow | Format-Table -AutoSize | Out-String
      `;
      break;
    default:
      return `Unknown actions command: ${action}. Valid: list-runs, get-run, list-workflows, trigger, cancel, rerun, download-logs, analytics`;
  }

  const { stdout, stderr } = await executePowerShell(command);
  return stderr ? `${stdout}\n\nErrors: ${stderr}` : stdout;
}

// Create MCP server
const server = new Server(
  {
    name: 'aitherzero-server',
    version: '2.1.0',
  },
  {
    capabilities: {
      tools: {},
      resources: {},
      prompts: {},
    },
  }
);

// Register tool handlers
server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: [
    {
      name: 'invoke_agent',
      description: 'Invoke a CLI-based AI agent (Gemini, Claude, Codex/OpenAI) with a prompt and optional context. Wraps standard CLI tools for agentic workflows.',
      inputSchema: {
        type: 'object',
        properties: {
          agent: {
            type: 'string',
            enum: ['Gemini', 'Claude', 'Codex'],
            description: 'The AI agent to invoke. "Codex" uses OpenAI CLI.',
          },
          prompt: {
            type: 'string',
            description: 'The instruction or query for the agent.',
          },
          context: {
            type: 'string',
            description: 'Optional context data (code, logs, etc.) to pipe to the agent.',
          },
        },
        required: ['agent', 'prompt'],
      },
    },
    {
      name: 'new_project',
      description: 'Scaffold a new AitherZero project (PowerShell, Python, or OpenTofu). Creates directory structure, configuration, CI/CD workflows, and optional modules.',
      inputSchema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path where the new project should be created' },
          name: { type: 'string', description: 'Name of the project (defaults to folder name)' },
          template: { type: 'string', enum: ['Standard', 'Minimal'], description: 'Project template to use', default: 'Standard' },
          language: { type: 'string', enum: ['PowerShell', 'Python', 'OpenTofu'], description: 'Project language/type', default: 'PowerShell' },
          includeCI: { type: 'boolean', description: 'Generate GitHub Actions CI/CD workflow' },
          includeVSCode: { type: 'boolean', description: 'Generate VS Code configuration (.vscode)' },
          includeModule: { type: 'boolean', description: 'Create a default PowerShell module (PowerShell only)' },
          gitInit: { type: 'boolean', description: 'Initialize a git repository' },
          registerProject: { type: 'boolean', description: 'Register the project in the AitherZero registry' },
          force: { type: 'boolean', description: 'Overwrite existing files' }
        },
        required: ['path']
      },
    },
    {
      name: 'list_projects',
      description: 'List registered AitherZero projects from the central registry.',
      inputSchema: {
        type: 'object',
        properties: {
          name: { type: 'string', description: 'Filter by project name (wildcards supported)' }
        }
      },
    },
    {
      name: 'register_project',
      description: 'Manually register an existing project in the AitherZero registry.',
      inputSchema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to the project root' },
          name: { type: 'string', description: 'Name of the project' },
          language: { type: 'string', enum: ['PowerShell', 'Python', 'OpenTofu'], description: 'Project language' },
          template: { type: 'string', enum: ['Standard', 'Minimal'], description: 'Project template' }
        },
        required: ['path', 'name']
      },
    },
    {
      name: 'manage_secrets',
      description: 'Manage secure secrets in the AitherZero vault.',
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['Set', 'Get', 'List', 'Remove'], description: 'Action to perform' },
          key: { type: 'string', description: 'Secret key name' },
          value: { type: 'string', description: 'Secret value (for Set action)' },
          scope: { type: 'string', enum: ['User', 'System', 'Process'], description: 'Scope of the secret' }
        },
        required: ['action']
      }
    },
    {
      name: 'manage_ssh_keys',
      description: 'Generate and manage SSH keys for GitHub/GitLab authentication.',
      inputSchema: {
        type: 'object',
        properties: {
          email: { type: 'string', description: 'Email address for the key comment' },
          name: { type: 'string', description: 'Key name (default: id_ed25519)' },
          type: { type: 'string', enum: ['ed25519', 'rsa'], description: 'Key type (default: ed25519)' }
        },
        required: ['email']
      }
    },
    {
      name: 'git_operations',
      description: 'Perform Git operations like branching, committing, and creating PRs.',
      inputSchema: {
        type: 'object',
        properties: {
          operation: { type: 'string', enum: ['create_branch', 'commit', 'create_pr'], description: 'Operation to perform' },
          args: {
            type: 'object',
            description: 'Arguments for the operation (e.g., name, message, title, body)',
            additionalProperties: true
          }
        },
        required: ['operation']
      }
    },
    {
      name: 'repo_sync',
      description: 'Synchronize changes across all repositories. Push to origin (AitherOS private), sync AitherZero subtree to public repo, and optionally trigger AitherOS-Alpha sync. This is the primary tool for agents to commit and push updates.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['push_all', 'sync_aitherzero', 'status'],
            description: 'push_all: commit+push to all repos. sync_aitherzero: sync only AitherZero public. status: show sync state.'
          },
          args: {
            type: 'object',
            description: 'Arguments: message (commit msg), force (force push), dry_run, skip_commit, aitherzero_only, direction (push/pull for sync_aitherzero)',
            properties: {
              message: { type: 'string', description: 'Commit message (auto-generated if omitted)' },
              force: { type: 'boolean', description: 'Force-push if repos have diverged' },
              dry_run: { type: 'boolean', description: 'Show what would happen without executing' },
              skip_commit: { type: 'boolean', description: 'Skip commit, only push existing commits' },
              aitherzero_only: { type: 'boolean', description: 'Only sync AitherZero public (skip Alpha)' },
              direction: { type: 'string', enum: ['push', 'pull'], description: 'Sync direction for sync_aitherzero' }
            },
            additionalProperties: false
          }
        },
        required: ['action']
      }
    },
    {
      name: 'ring_deploy',
      description: 'Manage ring-based deployments for AitherOS. Check ring status, promote between rings (dev→staging→prod), view deployment history, and rollback.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['status', 'promote', 'history', 'rollback'],
            description: 'status: check all rings. promote: promote between rings. history: deployment log. rollback: revert a ring.'
          },
          args: {
            type: 'object',
            description: 'Arguments for the action',
            properties: {
              ring: { type: 'string', enum: ['dev', 'staging', 'prod', 'all'], description: 'Target ring (for status/history/rollback)' },
              from: { type: 'string', enum: ['dev', 'staging'], description: 'Source ring for promotion' },
              to: { type: 'string', enum: ['staging', 'prod'], description: 'Target ring for promotion' },
              approve: { type: 'boolean', description: 'Auto-approve (skip manual gate)' },
              skip_tests: { type: 'boolean', description: 'Skip test gate' },
              skip_build: { type: 'boolean', description: 'Skip build gate' },
              dry_run: { type: 'boolean', description: 'Show what would happen' },
              force: { type: 'boolean', description: 'Force even if gates fail' }
            },
            additionalProperties: false
          }
        },
        required: ['action']
      }
    },
    {
      name: 'manage_agent_project',
      description: 'Manage AgenticOS projects and sub-agents.',
      inputSchema: {
        type: 'object',
        properties: {
          action: { type: 'string', enum: ['create', 'configure_creds', 'setup_venv', 'new_subagent'], description: 'Action to perform' },
          args: {
            type: 'object',
            description: 'Arguments for the action (e.g., name, path, parent)',
            additionalProperties: true
          }
        },
        required: ['action']
      }
    },
    {
      name: 'scan_disk_usage',
      description: 'Scan and analyze disk usage to identify large files and directories.',
      inputSchema: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Path to scan (default: current directory)' },
          depth: { type: 'number', description: 'Scan depth (default: 2)' }
        }
      }
    },
    {
      name: 'release_management',
      description: 'Manage release versions across AitherOS/AitherZero. Show current versions, bump (major/minor/patch), set explicit versions, create git tags, prepare releases (bump+commit+tag+push), validate semver, and view release history.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['show', 'bump', 'set', 'tag', 'prepare', 'validate', 'history'],
            description: 'Action: show (current versions), bump (increment), set (explicit version), tag (git tag), prepare (full release: bump+commit+tag+push), validate (check semver), history (list release tags)'
          },
          args: {
            type: 'object',
            description: 'Arguments for the action. bump/prepare: {component: "major"|"minor"|"patch", push: true}. set/tag/validate: {version: "1.2.3"}',
            properties: {
              version: { type: 'string', description: 'Explicit version string (semver format: X.Y.Z or X.Y.Z-prerelease)' },
              component: { type: 'string', enum: ['major', 'minor', 'patch'], description: 'Version component to bump' },
              push: { type: 'boolean', description: 'Push tags to remote after prepare' }
            },
            additionalProperties: false
          }
        },
        required: ['action']
      }
    },
    {
      name: 'trigger_release_workflow',
      description: 'Trigger GitHub Actions release workflows. Use "release-manager" to create a new release or "release-rollback" to rollback/DQ/cleanup an existing release. Requires GitHub CLI (gh) authentication.',
      inputSchema: {
        type: 'object',
        properties: {
          workflow: {
            type: 'string',
            enum: ['release-manager', 'release-rollback'],
            description: '"release-manager" to create releases, "release-rollback" to rollback/disqualify/cleanup/restore'
          },
          inputs: {
            type: 'object',
            description: 'Workflow inputs. release-manager: {version, release_type, skip_tests, dry_run, release_notes}. release-rollback: {release_tag, action, reason}',
            additionalProperties: { type: 'string' }
          }
        },
        required: ['workflow', 'inputs']
      }
    },
    {
      name: 'github_issues',
      description: 'Manage GitHub issues: list, get, create, update, close, reopen, comment, search. Requires GitHub CLI (gh) authentication.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['list', 'get', 'create', 'update', 'close', 'reopen', 'comment', 'search'],
            description: 'Action to perform on issues'
          },
          args: {
            type: 'object',
            description: 'Arguments: list/search: {state, limit, query}. get/close/reopen: {number}. create: {title, body, labels, assignee}. update: {number, title, body, add_labels, remove_labels}. comment: {number, body}.',
            additionalProperties: true
          }
        },
        required: ['action']
      }
    },
    {
      name: 'github_prs',
      description: 'Manage GitHub pull requests: list, get, create, merge, review, close, diff, checks. Requires GitHub CLI (gh) authentication.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['list', 'get', 'create', 'merge', 'review', 'close', 'diff', 'checks'],
            description: 'Action to perform on PRs'
          },
          args: {
            type: 'object',
            description: 'Arguments: list: {state, limit}. get/close/diff/checks: {number}. create: {title, body, head, base, draft, reviewer}. merge: {number, method(squash/merge/rebase), delete_branch, auto}. review: {number, event(approve/comment/request-changes), body}.',
            additionalProperties: true
          }
        },
        required: ['action']
      }
    },
    {
      name: 'github_actions',
      description: 'Manage GitHub Actions workflows and runs: list-runs, get-run, list-workflows, trigger, cancel, rerun, download-logs, analytics. Requires GitHub CLI (gh) authentication.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['list-runs', 'get-run', 'list-workflows', 'trigger', 'cancel', 'rerun', 'download-logs', 'analytics'],
            description: 'Action to perform. analytics returns success rates and per-workflow breakdown.'
          },
          args: {
            type: 'object',
            description: 'Arguments: list-runs: {limit, workflow, status}. get-run/cancel: {run_id}. trigger: {workflow, inputs, ref}. rerun: {run_id, failed_only}. download-logs: {run_id, lines}. analytics: {limit}.',
            additionalProperties: true
          }
        },
        required: ['action']
      }
    },
    {
      name: 'run_script',
      description: 'Execute an AitherZero automation script by number (0000-9999) from library/automation-scripts/. Over 56 scripts covering environment setup, infrastructure deployment, development tools, testing, reporting, Git automation, and maintenance. Use for single-purpose automation tasks.',
      inputSchema: {
        type: 'object',
        properties: {
          scriptNumber: {
            type: 'string',
            description: 'Script number (e.g., "0402" for unit tests, "0404" for PSScriptAnalyzer, "0510" for project report, "0207" for Git setup)',
            pattern: '^\\d{4}$',
          },
          params: {
            type: 'object',
            description: 'Optional parameters to pass to the script as key-value pairs',
            additionalProperties: true,
          },
          verbose: {
            type: 'boolean',
            description: 'Enable verbose output.',
          },
          dryRun: {
            type: 'boolean',
            description: 'Show what would happen without executing.',
          },
          showOutput: {
            type: 'boolean',
            description: 'Show script output in console.',
          },
        },
        required: ['scriptNumber'],
      },
    },
    {
      name: 'list_scripts',
      description: 'List available automation scripts with descriptions, categories, and metadata. Optionally filter by category (e.g., testing, infrastructure, development).',
      inputSchema: {
        type: 'object',
        properties: {
          category: {
            type: 'string',
            description: 'Optional category filter (e.g., "testing", "infrastructure", "development", "reporting")',
          },
        },
      },
    },
    {
      name: 'search_scripts',
      description: 'Search automation scripts by keyword in name, description, or metadata. Returns matching scripts with full details.',
      inputSchema: {
        type: 'object',
        properties: {
          query: {
            type: 'string',
            description: 'Search query (e.g., "docker", "test", "infrastructure", "quality")',
          },
        },
        required: ['query'],
      },
    },
    {
      name: 'list_playbooks',
      description: 'List all available playbooks (orchestrated sequences of scripts). Playbooks coordinate multiple automation scripts for complex workflows like full validation, environment setup, or PR checks.',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'execute_playbook',
      description: 'Execute a playbook - a predefined orchestrated sequence of automation scripts. Use list_playbooks to see available options. Common playbooks: code-quality-full, pr-validation, comprehensive-validation, dev-environment-setup.',
      inputSchema: {
        type: 'object',
        properties: {
          playbookName: {
            type: 'string',
            description: 'Name of the playbook to execute (use list_playbooks to see options)',
          },
          profile: {
            type: 'string',
            description: 'Optional execution profile (quick, standard, full, ci)',
            enum: ['quick', 'standard', 'full', 'ci'],
          },
          variables: {
            type: 'object',
            description: 'Optional variables to pass to the playbook.',
            additionalProperties: true,
          },
        },
        required: ['playbookName'],
      },
    },
    {
      name: 'get_configuration',
      description: 'Retrieve AitherZero configuration from config.psd1 manifest. Access configuration sections and keys to understand system settings, feature flags, and environment setup.',
      inputSchema: {
        type: 'object',
        properties: {
          section: {
            type: 'string',
            description: 'Optional configuration section (e.g., "Core", "Testing", "Features", "Infrastructure")',
          },
          key: {
            type: 'string',
            description: 'Optional specific key within section (e.g., "Profile", "Enabled")',
          },
        },
      },
    },
    {
      name: 'set_configuration',
      description: 'Update AitherZero configuration. By default saves to config.local.psd1 (gitignored).',
      inputSchema: {
        type: 'object',
        properties: {
          section: {
            type: 'string',
            description: 'Configuration section (e.g., "Core", "Automation")',
          },
          key: {
            type: 'string',
            description: 'Key to update (e.g., "Environment", "MaxConcurrency")',
          },
          value: {
            type: ['string', 'number', 'boolean'],
            description: 'The value to set.',
          },
          scope: {
            type: 'string',
            enum: ['local', 'global'],
            description: '"local" (default, recommended) or "global" (modifies config.psd1).',
            default: 'local',
          },
        },
        required: ['section', 'key', 'value'],
      },
    },
    {
      name: 'get_automation_help',
      description: 'Retrieves help/documentation for a specific script or playbook. Use this to inspect parameters before execution.',
      inputSchema: {
        type: 'object',
        properties: {
          target: {
            type: 'string',
            description: 'The script ID (e.g., "0206") or playbook name (e.g., "ci-pr-validation").',
          },
          type: {
            type: 'string',
            enum: ['script', 'playbook'],
            description: 'Type of automation artifact.',
            default: 'script',
          },
        },
        required: ['target'],
      },
    },
    {
      name: 'manage_mcp_server',
      description: 'Manages MCP Servers (Model Context Protocol). Install local server, list config, or register new servers.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['install', 'list', 'register'],
            description: 'Action to perform.',
          },
          name: {
            type: 'string',
            description: 'Server name (required for "register").',
          },
          command: {
            type: 'string',
            description: 'Command to run server (required for "register").',
          },
          args: {
            type: 'array',
            items: { type: 'string' },
            description: 'Arguments for command.',
          },
          env: {
            type: 'object',
            additionalProperties: { type: 'string' },
            description: 'Environment variables.',
          },
        },
        required: ['action'],
      },
    },
    {
      name: 'run_tests',
      description: 'Execute Pester tests for AitherZero codebase. Run all tests, specific test files, or filter by path. Supports unit and integration tests.',
      inputSchema: {
        type: 'object',
        properties: {
          path: {
            type: 'string',
            description: 'Optional path to test file or directory (e.g., "./tests/unit/Configuration.Tests.ps1", "./tests/aithercore/automation")',
          },
          tag: {
            type: 'string',
            description: 'Optional Pester tag filter (e.g., "Unit", "Integration", "Fast")',
          },
        },
      },
    },
    {
      name: 'run_quality_check',
      description: 'Run PSScriptAnalyzer validation on the codebase. Checks for best practices, syntax errors, and style violations.',
      inputSchema: {
        type: 'object',
        properties: {
          path: {
            type: 'string',
            description: 'Optional path to check (e.g., "./AitherZero/src")',
          },
        },
      },
    },
    {
      name: 'validate_component',
      description: 'Run comprehensive component quality validation. Checks error handling, logging, test coverage, and more.',
      inputSchema: {
        type: 'object',
        properties: {
          path: {
            type: 'string',
            description: 'Path to the component or file to validate',
          },
        },
        required: ['path'],
      },
    },
    {
      name: 'get_system_info',
      description: 'Gather a comprehensive system fingerprint — hardware (CPU, RAM, GPU, BIOS), OS (edition, build, uptime), disks, network adapters, running processes, installed applications, Windows services, Docker containers/images, environment variables, file-system summary, and security status. Returns JSON with a SHA-256 hash for change detection.',
      inputSchema: {
        type: 'object',
        properties: {
          sections: {
            type: 'string',
            description: 'Comma-separated sections to include. Valid: Hardware, OS, Disks, Network, Processes, Applications, Services, Docker, Environment, FileSystem, Security, GPU. Default: all.',
          },
          quick: {
            type: 'boolean',
            description: 'Skip slow sections (Applications, FileSystem scan) for sub-5-second results.',
            default: false,
          },
          format: {
            type: 'string',
            description: 'Output format: Json (default), Summary, Markdown',
            enum: ['Json', 'Summary', 'Markdown'],
          },
        },
      },
    },
    {
      name: 'get_logs',
      description: 'Retrieve the most recent logs from the AitherZero log file.',
      inputSchema: {
        type: 'object',
        properties: {
          lines: {
            type: 'number',
            description: 'Number of lines to retrieve (default: 100)',
          },
        },
      },
    },
    {
      name: 'get_project_report',
      description: 'Generate comprehensive project metrics report including file counts, test results, quality metrics, tech debt analysis, and system health.',
      inputSchema: {
        type: 'object',
        properties: {
          format: {
            type: 'string',
            description: 'Optional output format (text, json, markdown)',
            enum: ['text', 'json', 'markdown'],
          },
        },
      },
    },
    {
      name: 'get_domain_info',
      description: 'Get information about aithercore functional domains (11 domains: ai-agents, automation, cli, configuration, development, documentation, infrastructure, reporting, security, testing, utilities). Each domain contains specialized PowerShell modules.',
      inputSchema: {
        type: 'object',
        properties: {
          domain: {
            type: 'string',
            description: 'Optional specific domain name to inspect (e.g., "automation", "testing", "infrastructure")',
          },
        },
      },
    },
    {
      name: 'list_extensions',
      description: 'List installed AitherZero extensions. Extensions use script range 8000-8999 and provide additional functionality through the extension system.',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'build_module',
      description: 'Build the AitherZero PowerShell module from source (src/) and import it. Use this after making changes to core module functions to apply them.',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'get_workflow_status',
      description: 'Get status of GitHub Actions workflows for the repository (requires GitHub CLI authentication).',
      inputSchema: {
        type: 'object',
        properties: {},
      },
    },
    {
      name: 'infrastructure_manage',
      description: 'Manage and monitor AitherOS infrastructure — service health, mesh topology, database replication, and remote nodes. Use action "status" for overall health, "replication" for database sync details, "mesh" for mesh topology management.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['status', 'replication', 'mesh'],
            description: 'Action to perform. "status": overall infrastructure health check (services, containers, replication). "replication": detailed database replication status (PostgreSQL, Redis, Strata). "mesh": mesh topology operations (status, drain, rejoin, promote, remove).',
          },
          include_replication: {
            type: 'boolean',
            description: '(status) Include database replication checks in the health report.',
          },
          include_containers: {
            type: 'boolean',
            description: '(status) Include Docker container status in the report.',
          },
          check_remote_nodes: {
            type: 'boolean',
            description: '(status) Ping remote mesh nodes for connectivity.',
          },
          format: {
            type: 'string',
            enum: ['Table', 'Json', 'Summary'],
            description: '(status) Output format.',
          },
          include_details: {
            type: 'boolean',
            description: '(replication) Include low-level replication metrics (WAL positions, byte offsets).',
          },
          node_hosts: {
            type: 'array',
            items: { type: 'string' },
            description: '(replication) Remote node hostnames to check replication against.',
          },
          mesh_action: {
            type: 'string',
            enum: ['Status', 'Drain', 'Rejoin', 'Promote', 'Remove'],
            description: '(mesh) Mesh operation to perform.',
          },
          node_name: {
            type: 'string',
            description: '(mesh) Target node name for drain/rejoin/promote/remove.',
          },
          target_role: {
            type: 'string',
            description: '(mesh) Target role for promote action.',
          },
        },
        required: ['action'],
      },
    },
    {
      name: 'node_deploy',
      description: 'Manage remote AitherOS node lifecycle — deploy new nodes, check status, update, restart, or remove nodes from the mesh. Wraps the full Elysium deployment pipeline with replication setup.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['Deploy', 'Status', 'Update', 'Restart', 'Remove'],
            description: 'Lifecycle action: Deploy (full pipeline + replication), Status (remote health + mesh), Update (fleet manager), Restart (compose restart), Remove (mesh leave + compose down).',
          },
          computer_name: {
            type: 'array',
            items: { type: 'string' },
            description: 'Target hostname(s) or IP(s) for the operation. Supports multiple nodes.',
          },
          credential_name: {
            type: 'string',
            description: 'Name of stored credential to use for remote access (from AitherZero vault).',
          },
          profile: {
            type: 'string',
            enum: ['Full', 'Core', 'Minimal', 'GPU', 'Edge'],
            description: 'Deployment profile determining which services to deploy.',
          },
          gpu: {
            type: 'boolean',
            description: 'Enable GPU passthrough for the node.',
          },
          failover_priority: {
            type: 'number',
            description: 'Failover priority (1=highest). Lower numbers get promoted first.',
          },
          skip_bootstrap: {
            type: 'boolean',
            description: 'Skip initial bootstrap (node already prepared).',
          },
          skip_replication: {
            type: 'boolean',
            description: 'Skip database replication setup.',
          },
          start_watchdog: {
            type: 'boolean',
            description: 'Start the failover watchdog after deployment.',
          },
          dry_run: {
            type: 'boolean',
            description: 'Show what would happen without making changes.',
          },
          force: {
            type: 'boolean',
            description: 'Force operation even if safety checks fail.',
          },
        },
        required: ['action', 'computer_name'],
      },
    },
    {
      name: 'windows_iso_pipeline',
      description: 'Build custom Windows Server 2025 Core ISOs with AitherOS bootstrap and deploy VMs via OpenTofu + Hyper-V. Full pipeline: build ISO → provision VMs → wait for install → post-configure → mesh join.',
      inputSchema: {
        type: 'object',
        properties: {
          action: {
            type: 'string',
            enum: ['build', 'deploy', 'status', 'destroy'],
            description: '"build": build custom ISO from stock Server 2025 ISO. "deploy": full pipeline (build ISO + provision VMs + configure). "status": check deployed VM state. "destroy": tear down VMs.',
          },
          source_iso: {
            type: 'string',
            description: '(build/deploy) Path to stock Windows Server 2025 ISO.',
          },
          iso_path: {
            type: 'string',
            description: '(deploy) Path to pre-built custom ISO (skips build phase).',
          },
          computer_name: {
            type: 'string',
            description: '(build) Computer name baked into Autounattend.xml.',
          },
          node_names: {
            type: 'array',
            items: { type: 'string' },
            description: '(deploy) VM names to create.',
          },
          node_count: {
            type: 'number',
            description: '(deploy) Number of nodes (auto-named aither-node-01, 02, etc.).',
          },
          profile: {
            type: 'string',
            enum: ['Full', 'Core', 'Minimal', 'GPU', 'Edge'],
            description: 'AitherOS deployment profile.',
          },
          cpu_count: {
            type: 'number',
            description: '(deploy) vCPUs per node. Default: 4.',
          },
          memory_gb: {
            type: 'number',
            description: '(deploy) RAM in GB per node. Default: 4.',
          },
          disk_gb: {
            type: 'number',
            description: '(deploy) Disk size in GB per node. Default: 80.',
          },
          switch_name: {
            type: 'string',
            description: '(deploy) Hyper-V virtual switch name.',
          },
          mesh_core_url: {
            type: 'string',
            description: 'MeshCore URL for auto-join.',
          },
          include_openssh: {
            type: 'boolean',
            description: '(build) Include OpenSSH server.',
          },
          include_hyperv: {
            type: 'boolean',
            description: '(build) Enable nested Hyper-V.',
          },
          auto_approve: {
            type: 'boolean',
            description: '(deploy/destroy) Skip confirmation prompt.',
          },
          skip_post_install: {
            type: 'boolean',
            description: '(deploy) Skip waiting for WinRM and post-install.',
          },
          dry_run: {
            type: 'boolean',
            description: 'Preview without executing.',
          },
        },
        required: ['action'],
      },
    },
    /*
    {
      name: 'generate_documentation',
      description: 'Generate or update documentation for AitherZero modules and functions. Creates markdown documentation from PowerShell comment-based help.',
      inputSchema: {
        type: 'object',
        properties: {
          domain: {
            type: 'string',
            description: 'Optional specific domain to document (generates all if not specified)',
          },
        },
      },
    },
    */
  ],
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    let result: string;

    if (!args) {
      throw new Error('Missing arguments');
    }

    switch (name) {
      case 'invoke_agent':
        result = await invokeAgent(args.agent as string, args.prompt as string, args.context as string | undefined);
        break;

      case 'new_project':
        result = await createProject(
          args.path as string,
          args.name as string | undefined,
          args.template as string | undefined,
          args.language as string | undefined,
          args.includeCI as boolean | undefined,
          args.includeVSCode as boolean | undefined,
          args.includeModule as boolean | undefined,
          args.gitInit as boolean | undefined,
          args.registerProject as boolean | undefined,
          args.force as boolean | undefined
        );
        break;

      case 'list_projects':
        result = await listProjects(args.name as string | undefined);
        break;

      case 'register_project':
        result = await registerProject(
          args.path as string,
          args.name as string,
          args.language as string | undefined,
          args.template as string | undefined
        );
        break;

      case 'run_script':
        result = await executeAitherScript(
          args.scriptNumber as string,
          args.params as Record<string, any>,
          {
            verbose: args.verbose as boolean | undefined,
            dryRun: args.dryRun as boolean | undefined,
            showOutput: args.showOutput as boolean | undefined
          }
        );
        break;

      case 'list_scripts':
        result = await listAutomationScripts(args.category as string | undefined);
        break;

      case 'search_scripts':
        result = await searchScripts(args.query as string);
        break;

      case 'list_playbooks':
        result = await listPlaybooks();
        break;

      case 'execute_playbook':
        result = await executePlaybook(
          args.playbookName as string,
          args.profile as string | undefined,
          args.variables as Record<string, any> | undefined
        );
        break;

      case 'get_configuration':
        result = await getConfiguration(args.section as string | undefined, args.key as string | undefined);
        break;

      case 'set_configuration':
        result = await setConfiguration(
          args.section as string,
          args.key as string,
          args.value as string | number | boolean,
          args.scope as string | undefined
        );
        break;

      case 'get_automation_help':
        result = await getAutomationHelp(args.target as string, args.type as string | undefined);
        break;

      case 'manage_mcp_server':
        result = await manageMCPServer(
          args.action as string,
          args.name as string | undefined,
          args.command as string | undefined,
          args.args as string[] | undefined,
          args.env as Record<string, string> | undefined
        );
        break;

      case 'run_tests':
        result = await runTests(args.path as string | undefined, args.tag as string | undefined);
        break;

      case 'run_quality_check':
        result = await runQualityCheck(args.path as string | undefined);
        break;

      case 'get_project_report':
        result = await getProjectReport(args.format as string | undefined);
        break;

      case 'get_domain_info':
        result = await getDomainInfo(args.domain as string | undefined);
        break;

      case 'list_extensions':
        result = await listExtensions();
        break;

      case 'build_module':
        result = await buildAndImportModule();
        break;

      case 'get_workflow_status':
        result = await getWorkflowStatus();
        break;

      case 'validate_component':
        result = await validateComponent(args.path as string);
        break;

      case 'get_system_info':
        result = await getSystemInfo(
          args.sections as string | undefined,
          args.quick as boolean | undefined,
          args.format as string | undefined
        );
        break;

      case 'get_logs':
        result = await getLogs(args.lines as number | undefined);
        break;

      /*
      case 'generate_documentation':
        result = await generateDocumentation(args.domain as string | undefined);
        break;
      */

      case 'manage_secrets':
        result = await manageSecrets(
          args.action as string,
          args.key as string | undefined,
          args.value as string | undefined,
          args.scope as string | undefined
        );
        break;

      case 'manage_ssh_keys':
        result = await manageSSHKeys(
          args.email as string,
          args.name as string | undefined,
          args.type as string | undefined
        );
        break;

      case 'git_operations':
        result = await gitOperations(
          args.operation as string,
          args.args as Record<string, any> || {}
        );
        break;

      case 'repo_sync':
        result = await repoSync(
          args.action as string,
          args.args as Record<string, any> || {}
        );
        break;

      case 'ring_deploy':
        result = await ringDeploy(
          args.action as string,
          args.args as Record<string, any> || {}
        );
        break;

      case 'manage_agent_project':
        result = await manageAgentProject(
          args.action as string,
          args.args as Record<string, any> || {}
        );
        break;

      case 'scan_disk_usage':
        result = await scanDiskUsage(
          args.path as string | undefined,
          args.depth as number | undefined
        );
        break;

      case 'release_management':
        result = await releaseManagement(
          args.action as string,
          args.args as Record<string, any> || {}
        );
        break;

      case 'trigger_release_workflow':
        result = await triggerReleaseWorkflow(
          args.workflow as 'release-manager' | 'release-rollback',
          args.inputs as Record<string, string>
        );
        break;

      case 'github_issues':
        result = await manageGitHubIssues(
          args.action as string,
          args.args as Record<string, any> || {}
        );
        break;

      case 'github_prs':
        result = await manageGitHubPRs(
          args.action as string,
          args.args as Record<string, any> || {}
        );
        break;

      case 'github_actions':
        result = await manageGitHubActions(
          args.action as string,
          args.args as Record<string, any> || {}
        );
        break;

      case 'infrastructure_manage':
        result = await infrastructureManage(
          args.action as string,
          args as Record<string, any>
        );
        break;

      case 'node_deploy':
        result = await nodeDeploy(
          args.action as string,
          args as Record<string, any>
        );
        break;

      case 'windows_iso_pipeline':
        result = await windowsIsoPipeline(
          args.action as string,
          args as Record<string, any>
        );
        break;

      default:
        throw new Error(`Unknown tool: ${name}`);
    }

    return {
      content: [
        {
          type: 'text',
          text: result,
        },
      ],
    };
  } catch (error) {
    return {
      content: [
        {
          type: 'text',
          text: `Error: ${error instanceof Error ? error.message : String(error)}`,
        },
      ],
      isError: true,
    };
  }
});

// Register resource handlers
server.setRequestHandler(ListResourcesRequestSchema, async () => ({
  resources: [
    {
      uri: 'aitherzero://config',
      name: 'AitherZero Configuration',
      description: 'Complete configuration from config.psd1 manifest - single source of truth for all system settings',
      mimeType: 'application/json',
    },
    {
      uri: 'aitherzero://scripts',
      name: 'Automation Scripts',
      description: 'List of 56 automation scripts from library/automation-scripts/ with metadata',
      mimeType: 'text/plain',
    },
    {
      uri: 'aitherzero://playbooks',
      name: 'Orchestration Playbooks',
      description: 'Available playbooks for coordinated multi-script workflows',
      mimeType: 'text/plain',
    },
    {
      uri: 'aitherzero://domains',
      name: 'Aithercore Domains',
      description: 'Information about 10 functional domains in AitherZero/src/public',
      mimeType: 'text/plain',
    },
    {
      uri: 'aitherzero://project-report',
      name: 'Project Report',
      description: 'Comprehensive project status, metrics, and health analysis',
      mimeType: 'text/plain',
    },
  ],
}));

server.setRequestHandler(ReadResourceRequestSchema, async (request) => {
  const { uri } = request.params;

  try {
    let content: string;

    switch (uri) {
      case 'aitherzero://config':
        content = await getConfiguration();
        break;

      case 'aitherzero://scripts':
        content = await listAutomationScripts();
        break;

      case 'aitherzero://playbooks':
        content = await listPlaybooks();
        break;

      case 'aitherzero://domains':
        content = await getDomainInfo();
        break;

      case 'aitherzero://project-report':
        content = await getProjectReport();
        break;

      default:
        throw new Error(`Unknown resource: ${uri}`);
    }

    return {
      contents: [
        {
          uri,
          mimeType: uri.includes('config') ? 'application/json' : 'text/plain',
          text: content,
        },
      ],
    };
  } catch (error) {
    throw new Error(`Failed to read resource ${uri}: ${error instanceof Error ? error.message : String(error)}`);
  }
});

// Register prompt handlers for guided workflows
server.setRequestHandler(ListPromptsRequestSchema, async () => ({
  prompts: [
    {
      name: 'setup-dev-environment',
      description: 'Guided workflow for setting up a complete AitherZero development environment',
      arguments: [
        {
          name: 'profile',
          description: 'Installation profile (minimal, standard, full)',
          required: false,
        },
      ],
    },
    {
      name: 'validate-code-quality',
      description: 'Step-by-step code quality validation workflow (syntax, linting, tests, coverage)',
      arguments: [
        {
          name: 'path',
          description: 'Path to validate (defaults to entire project)',
          required: false,
        },
      ],
    },
    {
      name: 'create-pr',
      description: 'Guided workflow for creating a pull request with proper validation',
      arguments: [
        {
          name: 'branch',
          description: 'Feature branch name',
          required: true,
        },
      ],
    },
    {
      name: 'troubleshoot-ci',
      description: 'Interactive troubleshooting for CI/CD pipeline failures',
      arguments: [],
    },
  ],
}));

server.setRequestHandler(GetPromptRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    let messages: Array<{ role: 'user' | 'assistant'; content: { type: 'text'; text: string } }> = [];

    switch (name) {
      case 'setup-dev-environment':
        const profile = args?.profile || 'standard';
        messages = [
          {
            role: 'user',
            content: {
              type: 'text',
              text: `I want to set up AitherZero development environment with ${profile} profile`,
            },
          },
          {
            role: 'assistant',
            content: {
              type: 'text',
              text: `I'll help you set up AitherZero development environment. Let me start by checking prerequisites:\n\n1. PowerShell 7.0+\n2. Git 2.0+\n3. Node.js 18+ (for MCP server)\n\nLet me execute the setup steps:\n\nStep 1: Run bootstrap script\nStep 2: Install development tools (0201-0213 scripts)\nStep 3: Configure Git and GitHub CLI\nStep 4: Set up MCP servers (script 0010)\nStep 5: Validate installation\n\nShall I proceed?`,
            },
          },
        ];
        break;

      case 'validate-code-quality':
        const path = args?.path || 'entire project';
        messages = [
          {
            role: 'user',
            content: {
              type: 'text',
              text: `I want to validate code quality for ${path}`,
            },
          },
          {
            role: 'assistant',
            content: {
              type: 'text',
              text: `I'll run comprehensive code quality validation. This includes:\n\n1. Syntax validation (script 0407)\n2. PSScriptAnalyzer linting (script 0404)\n3. Unit tests (script 0402)\n4. Integration tests (script 0403)\n5. Quality checks (script 0420)\n\nOr I can run the code-quality-full playbook for the complete workflow.\n\nWhich approach would you prefer?`,
            },
          },
        ];
        break;

      case 'create-pr':
        const branch = args?.branch || 'feature-branch';
        messages = [
          {
            role: 'user',
            content: {
              type: 'text',
              text: `I want to create a PR for branch ${branch}`,
            },
          },
          {
            role: 'assistant',
            content: {
              type: 'text',
              text: `I'll guide you through creating a proper PR. Steps:\n\n1. Run pr-validation playbook to ensure code quality\n2. Generate documentation (script 0530)\n3. Update indexes (script 0531)\n4. Create PR with GitHub CLI (script 0703)\n5. Validate PR checks pass\n\nLet me start with validation first. Shall I proceed?`,
            },
          },
        ];
        break;

      case 'troubleshoot-ci':
        messages = [
          {
            role: 'user',
            content: {
              type: 'text',
              text: 'My CI/CD pipeline is failing, can you help troubleshoot?',
            },
          },
          {
            role: 'assistant',
            content: {
              type: 'text',
              text: `I'll help troubleshoot CI failures. Let me:\n\n1. Check workflow status using get_workflow_status tool\n2. Run diagnose-ci playbook\n3. Identify failing workflows and steps\n4. Suggest fixes based on common issues\n\nLet me start by checking the workflow status...`,
            },
          },
        ];
        break;

      default:
        throw new Error(`Unknown prompt: ${name}`);
    }

    return { messages };
  } catch (error) {
    throw new Error(`Failed to get prompt ${name}: ${error instanceof Error ? error.message : String(error)}`);
  }
});

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error('AitherZero MCP Server v2.1 running on stdio');
  console.error('19 tools, 5 resources, 4 prompts available');
}

main().catch((error) => {
  console.error('Server error:', error);
  process.exit(1);
});
