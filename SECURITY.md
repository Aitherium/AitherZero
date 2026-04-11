# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 3.x     | ✅ Active support  |
| < 3.0   | ❌ No support      |

## Reporting a Vulnerability

**Please do NOT report security vulnerabilities through public GitHub issues.**

Instead, please report them via email to **security@aitherium.com**.

You should receive a response within 48 hours. If for some reason you do not, please follow up via email to ensure we received your original report.

Please include the following information:

- Type of issue (e.g., credential exposure, command injection, privilege escalation)
- Full paths of source file(s) related to the issue
- Location of the affected source code (tag/branch/commit or direct URL)
- Any special configuration required to reproduce the issue
- Step-by-step instructions to reproduce the issue
- Proof-of-concept or exploit code (if possible)
- Impact of the issue, including how an attacker might exploit it

## What to Expect

- **Acknowledgment**: Within 48 hours
- **Assessment**: Within 1 week
- **Fix timeline**: Critical issues within 72 hours, others within 30 days
- **Credit**: We will credit reporters in the security advisory (unless you prefer anonymity)

## Scope

The following are in scope:

- AitherZero PowerShell module (`src/`, `library/`)
- MCP server integration (`library/integrations/mcp-server/`)
- Configuration system (`config/`)
- OpenTofu/Terraform modules (`library/infrastructure/`)
- Automation scripts (`library/automation-scripts/`)
- Plugin system (`plugins/`)

The following are out of scope:

- Third-party dependencies (report to the relevant project)
- Issues in user-created plugins (report to the plugin author)
- Social engineering attacks

## Security Best Practices for Contributors

- Never commit secrets, API keys, or credentials
- Use `Get-AitherSecret` for secret management, never hardcode
- Use parameterized paths, never hardcode absolute paths
- Validate all user input in scripts and functions
- Use `$ErrorActionPreference = 'Stop'` to fail fast on errors
- Review OpenTofu plans before applying infrastructure changes
