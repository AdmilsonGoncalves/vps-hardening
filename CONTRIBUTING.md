# Contributing to VPS Hardening Suite

Thank you for your interest in contributing to **VPS Hardening Suite**! We welcome bug fixes, documentation improvements, new auditing rules, and architectural enhancements.

---

## 1. Core Engineering Principles

Before submitting code, please ensure your contributions adhere to our foundational SRE principles:

1. **Declarative Configuration**: Never hardcode user names, IP addresses, or ports inside bash scripts. All configurable parameters must be read from [`scripts/vps.env`](file:///home/admilson/IdeaProjects/vps-hardening/scripts/vps.env) (or fall back to strict validation placeholders).
2. **Safety Interlocks**: Scripts must perform pre-flight checks (e.g., verifying user existence and sudo privileges) before altering SSH or firewall rules to prevent operator lock-out.
3. **Idempotency**: All execution stages must be safely re-runnable without duplicating config entries, appending duplicate lines, or throwing fatal errors on existing rules.
4. **Minimal Dependencies**: Rely on POSIX standard tools or robust system utilities available in standard Debian/Ubuntu repositories (`awk`, `sed`, `grep`, `jq`, `ufw`).

---

## 2. Development Workflow

### Setting up Locally
1. Fork the repository and clone your fork:
   ```bash
   git clone https://github.com/<your-username>/vps-hardening.git
   cd vps-hardening
   ```
2. Create a clean feature or bugfix branch:
   ```bash
   git checkout -b feature/improved-audit-checks
   ```

### Code Validation & Linting
Before submitting a pull request, verify that all modified scripts pass syntax checks and standard linting:

```bash
# Check syntax for all shell scripts
for script in scripts/*.sh; do bash -n "$script"; done

# Run ShellCheck if installed locally
shellcheck scripts/*.sh
```

---

## 3. Pull Request Guidelines

1. **Clear Commit History**: Ensure your commits are descriptive. We recommend squashing small iterative changes before submitting.
2. **Update Documentation**: If you add new configuration variables to `vps.env` or modify script arguments, update [`README.md`](file:///home/admilson/IdeaProjects/vps-hardening/README.md) and [`scripts/OPERATIONAL_MANUAL.md`](file:///home/admilson/IdeaProjects/vps-hardening/scripts/OPERATIONAL_MANUAL.md) accordingly.
3. **Automated & AI Reviews**: Be prepared to address automated code review comments (e.g., from CodeRabbit or CI checks) constructively.

Thank you for making Linux servers safer and more resilient!
