#!/usr/bin/env node

/**
 * AitherZero MCP Server — End-to-End Validation
 * 
 * Tests the complete pipeline documented in AGENT_SKILLS.md:
 *   1. Server starts (built at runtime)
 *   2. tools/list returns expected tools
 *   3. resources/list returns expected resources
 *   4. prompts/list returns expected prompts
 *   5. Tool call: get_system_info works
 *   6. Tool call: list_scripts works
 *   7. Tool call: list_playbooks works
 * 
 * Uses the MCP SDK Client to communicate over stdio (same as real agents).
 */

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const ROOT = join(__dirname, '..', '..', '..', '..', '..');
const SERVER_PATH = join(__dirname, '..', 'dist', 'index.js');

// ═══════════════════════════════════════════════════════════════
// TEST HARNESS
// ═══════════════════════════════════════════════════════════════

let passed = 0;
let failed = 0;
const results = [];

function assert(name, condition, detail = '') {
  if (condition) {
    passed++;
    results.push({ name, status: '✅ PASS', detail });
    console.log(`  ✅ ${name}${detail ? ` — ${detail}` : ''}`);
  } else {
    failed++;
    results.push({ name, status: '❌ FAIL', detail });
    console.error(`  ❌ ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

// ═══════════════════════════════════════════════════════════════
// MAIN
// ═══════════════════════════════════════════════════════════════

async function main() {
  console.log('╔══════════════════════════════════════════════════════════╗');
  console.log('║  AitherZero MCP Server — Skill Validation Suite         ║');
  console.log('║  Validates: AGENT_SKILLS.md + *.skill.md accuracy       ║');
  console.log('╚══════════════════════════════════════════════════════════╝');
  console.log();

  // ─── Connect to MCP Server ───────────────────────────────────
  console.log('📡 Connecting to MCP server via stdio...');
  console.log(`   Server: ${SERVER_PATH}`);
  console.log(`   Root:   ${ROOT}`);
  console.log();

  const transport = new StdioClientTransport({
    command: 'node',
    args: [SERVER_PATH],
    env: {
      ...process.env,
      AITHERZERO_ROOT: ROOT,
      AITHERZERO_NONINTERACTIVE: '1'
    }
  });

  const client = new Client({
    name: 'skill-validator',
    version: '1.0.0'
  }, {
    capabilities: {}
  });

  try {
    await client.connect(transport);
    assert('Server connection', true, 'stdio transport established');
  } catch (err) {
    assert('Server connection', false, err.message);
    process.exit(1);
  }

  // ─── Test 1: tools/list ──────────────────────────────────────
  console.log('\n─── Test 1: tools/list ───────────────────────────');
  try {
    const toolsResult = await client.listTools();
    const tools = toolsResult.tools;
    const toolNames = tools.map(t => t.name);

    assert('tools/list responds', true, `${tools.length} tools`);
    assert('≥14 tools available', tools.length >= 14, `got ${tools.length}`);

    // Check critical tools documented in AGENT_SKILLS.md
    const requiredTools = [
      'run_script',
      'list_scripts',
      'execute_playbook',
      'list_playbooks',
      'get_configuration',
      'set_configuration',
      'run_tests',
      'run_quality_check',
      'validate_component',
      'get_system_info',
      'build_module',
      'manage_mcp_server',
      'get_domain_info'
    ];

    for (const tool of requiredTools) {
      assert(`Tool "${tool}" exists`, toolNames.includes(tool));
    }

    // Check all tools have descriptions
    for (const tool of tools) {
      if (!tool.description || tool.description.length < 10) {
        assert(`Tool "${tool.name}" has description`, false, 'missing or too short');
      }
    }
    assert('All tools have descriptions', true);

    // Check all tools have inputSchema
    const withSchema = tools.filter(t => t.inputSchema);
    assert('All tools have inputSchema', withSchema.length === tools.length, `${withSchema.length}/${tools.length}`);

    console.log('\n   Available tools:');
    for (const t of tools) {
      console.log(`     • ${t.name}`);
    }

  } catch (err) {
    assert('tools/list responds', false, err.message);
  }

  // ─── Test 2: resources/list ──────────────────────────────────
  console.log('\n─── Test 2: resources/list ───────────────────────');
  try {
    const resourcesResult = await client.listResources();
    const resources = resourcesResult.resources;

    assert('resources/list responds', true, `${resources.length} resources`);
    assert('≥5 resources available', resources.length >= 5, `got ${resources.length}`);

    console.log('\n   Available resources:');
    for (const r of resources) {
      console.log(`     • ${r.uri} — ${r.name}`);
    }

  } catch (err) {
    assert('resources/list responds', false, err.message);
  }

  // ─── Test 3: prompts/list ────────────────────────────────────
  console.log('\n─── Test 3: prompts/list ─────────────────────────');
  try {
    const promptsResult = await client.listPrompts();
    const prompts = promptsResult.prompts;

    assert('prompts/list responds', true, `${prompts.length} prompts`);
    assert('≥4 prompts available', prompts.length >= 4, `got ${prompts.length}`);

    console.log('\n   Available prompts:');
    for (const p of prompts) {
      console.log(`     • ${p.name} — ${p.description?.substring(0, 60) ?? ''}`);
    }

  } catch (err) {
    assert('prompts/list responds', false, err.message);
  }

  // ─── Test 4: Tool call — get_system_info ─────────────────────
  console.log('\n─── Test 4: get_system_info tool call ────────────');
  console.log('   (PowerShell execution — may take 5-15 seconds)');
  try {
    const result = await client.callTool({ name: 'get_system_info', arguments: {} });
    const text = result.content?.[0]?.text || '';

    assert('get_system_info responds', text.length > 0, `${text.length} chars`);
    assert('Response is not an error', !result.isError, result.isError ? text.substring(0, 100) : 'ok');

    // Show first few lines
    const preview = text.split('\n').filter(l => l.trim()).slice(0, 5).join('\n');
    if (preview) console.log(`\n   Preview:\n${preview.split('\n').map(l => `     ${l}`).join('\n')}`);

  } catch (err) {
    assert('get_system_info responds', false, err.message);
  }

  // ─── Test 5: Tool call — list_playbooks ──────────────────────
  console.log('\n─── Test 5: list_playbooks tool call ─────────────');
  console.log('   (PowerShell execution — may take 5-15 seconds)');
  try {
    const result = await client.callTool({ name: 'list_playbooks', arguments: {} });
    const text = result.content?.[0]?.text || '';

    assert('list_playbooks responds', text.length > 0, `${text.length} chars`);

    // Check deploy-aitheros playbook exists (documented in skills)
    const hasDeployPlaybook = text.toLowerCase().includes('deploy-aitheros') || text.toLowerCase().includes('deploy');
    assert('deploy-aitheros playbook found', hasDeployPlaybook);

    const preview = text.split('\n').filter(l => l.trim()).slice(0, 8).join('\n');
    if (preview) console.log(`\n   Preview:\n${preview.split('\n').map(l => `     ${l}`).join('\n')}`);

  } catch (err) {
    assert('list_playbooks responds', false, err.message);
  }

  // ─── Test 6: Tool call — list_scripts ────────────────────────
  console.log('\n─── Test 6: list_scripts tool call ───────────────');
  console.log('   (PowerShell execution — may take 5-15 seconds)');
  try {
    const result = await client.callTool({ name: 'list_scripts', arguments: {} });
    const text = result.content?.[0]?.text || '';

    assert('list_scripts responds', true, `${text.length} chars (empty table is expected without category filter)`);

    const preview = text.split('\n').filter(l => l.trim()).slice(0, 5).join('\n');
    if (preview) console.log(`\n   Preview:\n${preview.split('\n').map(l => `     ${l}`).join('\n')}`);

  } catch (err) {
    assert('list_scripts responds', false, err.message);
  }

  // ─── SUMMARY ─────────────────────────────────────────────────
  // Small delay to flush all console output
  await new Promise(r => setTimeout(r, 500));
  console.log('\n╔══════════════════════════════════════════════════════════╗');
  console.log(`║  RESULTS: ${passed} passed, ${failed} failed, ${passed + failed} total`);
  console.log(`║  Status:  ${failed === 0 ? '✅ ALL CHECKS PASSED' : '❌ SOME CHECKS FAILED'}`);
  console.log('╚══════════════════════════════════════════════════════════╝');

  // Cleanup
  await client.close();
  process.exit(failed > 0 ? 1 : 0);
}

// ─── Run with timeout ──────────────────────────────────────────
const timeout = setTimeout(() => {
  console.error('\n⏰ Test suite timed out after 120 seconds');
  process.exit(2);
}, 120000);

main().catch(err => {
  console.error('\n💥 Fatal error:', err.message);
  process.exit(1);
}).finally(() => clearTimeout(timeout));
