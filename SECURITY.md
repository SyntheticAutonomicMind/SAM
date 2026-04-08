# Security Policy

## Reporting a Vulnerability

If you discover a security vulnerability in SAM, please report it responsibly:

1. **Do not** open a public GitHub issue
2. Email the maintainer directly at the security contact listed on the [GitHub repository](https://github.com/SyntheticAutonomicMind/SAM)
3. Include a detailed description of the vulnerability
4. Include steps to reproduce the issue
5. Allow reasonable time for a fix before public disclosure

## Response Timeline

- **Acknowledgment:** Within 48 hours
- **Initial assessment:** Within 1 week
- **Fix for critical issues:** As soon as possible, targeting same-week release
- **Fix for non-critical issues:** Included in the next scheduled release

## Supported Versions

Only the latest release is supported with security updates. We recommend always running the most recent version.

| Version | Supported |
|---------|-----------|
| Latest release | Yes |
| Previous releases | No |
| Development builds | Best effort |

## Scope

The following are in scope for security reports:

- Authentication bypass in the API server
- Unauthorized file access through the tool system
- API key exposure or insecure storage
- Remote code execution vulnerabilities
- Privilege escalation

The following are out of scope:

- Issues requiring physical access to the Mac
- Social engineering attacks
- Vulnerabilities in third-party AI providers (report to the provider directly)
- Issues in development/debug builds only

## Security Model

For details about SAM's security design, see [docs/SECURITY.md](docs/SECURITY.md).
