# Contributing

- Keep changes small and focused. Run `./scripts/test.sh` before opening a pull request.
- Never commit signing identities, Team IDs, provisioning profiles, message data or database files. Build settings come from environment variables.
- Security-sensitive areas (`Sources/Bridge`) need a test for any behavior change.
- Do not add network access, persistent approvals, or any sending path that skips the confirmation window.
