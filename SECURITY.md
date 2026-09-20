# Security Policy

## Supported Versions

The following table lists the release branches and versions that currently receive security updates:

| Version | Supported          |
| ------- | ------------------ |
| 2.0.x   | :white_check_mark: |
| 1.0.x   | :x:                |
| < 1.0   | :x:                |

The 1.0.x line was published as `luneth90.keycade` and is not maintained here. A vulnerability that only affects it belongs to the upstream project; one that also affects 2.0.x is in scope and should be reported as below.

## Reporting a Vulnerability

The Keycade LazyVim team takes security vulnerabilities seriously. We appreciate your efforts to responsibly disclose findings.

### Private Reporting Channels

Please do **not** report security vulnerabilities through public GitHub issues. Instead:

1. **GitHub Private Vulnerability Reporting**: Go to the [Security tab](https://github.com/GerritWanderer/keycade-lazyvim/security/advisories/new) of this repository and click **"Report a vulnerability"**. This creates an encrypted private advisory draft visible only to project maintainers.
2. **Email Disclosure**: If private vulnerability reporting is unavailable, email security concerns directly to this repository's maintainer at `gerrit.wanderer@gmail.com` with the subject line `[SECURITY] Keycade LazyVim Vulnerability Report`. A finding that concerns the upstream Keycade project rather than this fork can instead reach its author at `luneth90@icloud.com`.

### What to Include in a Report

To help us triage and verify the report efficiently, please include:
- A clear description of the vulnerability and its potential impact.
- Exact steps to reproduce, proof-of-concept scripts, or minimal test cases.
- Any affected components (e.g. the helpers `bin/app-config-json`, `bin/state-store`, `bin/keybinds-json` and `bin/bounded-relay`, the QML consumers that bound their output, or the Wayland input path in `lib/InputGuard.qml`).
- Proposed mitigations or fixes, if any.

### Response Timeline

- **Initial Acknowledgment**: Within 48 hours of receiving your disclosure.
- **Triage & Assessment**: Within 5 business days, confirming whether the report is reproducible and assessing severity.
- **Remediation & Patch**: A fix will be developed and tested against security review invariants.
- **Public Disclosure**: Coordinated advisory and release notes published once a patched version is available.
