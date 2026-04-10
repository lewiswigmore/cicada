# Security Policy

## Supported Versions

Only the latest version series is supported with security updates:

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | ✅ Supported       |
| < 0.1   | ❌ Not supported   |

## Reporting a Vulnerability

We take security vulnerabilities seriously. If you discover a security vulnerability in Cicada, please **do not** create a public issue. Instead:

1. **Use GitHub's Private Vulnerability Reporting**: Visit [https://github.com/lewiswigmore/cicada/security/advisories/new](https://github.com/lewiswigmore/cicada/security/advisories/new)
2. Provide details about the vulnerability including:
   - Description of the vulnerability
   - Steps to reproduce (if applicable)
   - Affected component(s)
   - Potential impact
   - Any known mitigation strategies

This allows us to address the issue before public disclosure.

## Response Timeline

We aim to:
- **Acknowledge** your report within 48 hours
- **Triage** and assess the vulnerability within 1 week
- Provide updates as work progresses

## Scope

### In Scope
Vulnerabilities in the following components are within scope:

- **PowerShell Module** (`src/CicadaModule/`) — command execution, parameter handling, security context
- **Python MCP Server** (`src/cicada_mcp_server/`) — agent orchestration, input validation, data handling
- **Installer** (`src/installer/`) — installation process and privilege handling
- **Core orchestration logic** — inter-agent communication, message handling

### Out of Scope
The following are considered out of scope and should be reported to the respective projects:

- **Third-party dependencies** — please report security issues to the upstream projects
  - Report Python package vulnerabilities to PyPI maintainers
  - Report PowerShell module vulnerabilities to the module authors
  - Report Copilot CLI issues to GitHub
- **GitHub Copilot CLI security** — Copilot has its own security model; report issues at [https://github.com/github/copilot-cli](https://github.com/github/copilot-cli)
- **Platform/OS-level vulnerabilities** — report to your OS vendor

## Security Best Practices

Cicada is a multi-agent orchestrator that runs GitHub Copilot CLI. Users should understand:

1. **Copilot CLI Security Model**: Cicada inherits the security properties of GitHub Copilot CLI. Review Copilot's security documentation for details on authentication, data handling, and privacy.

2. **Agent Execution Context**: Agents run with the privileges of the user executing Cicada. Be cautious when running untrusted agents or with elevated permissions.

3. **Input Validation**: Always validate inputs to agents, especially when accepting user-provided code or commands.

4. **Dependency Updates**: Keep your PowerShell, Python, and Copilot CLI installations up to date with security patches.

## Questions?

If you have questions about security practices or need clarification, feel free to contact the maintainers directly (without disclosing vulnerability details in public channels).
