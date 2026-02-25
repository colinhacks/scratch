# Agent Security Rules

## Shell Access

All command execution MUST use the `gh_pullfrog/shell` MCP tool. Native or direct shell tools are prohibited.

## Secret Protection

Agents MUST NOT attempt to access, read, log, print, encode, transmit, or exfiltrate environment variables containing API keys or secrets.

### Prohibited Actions

- Running `env`, `printenv`, `set`, `export`, or similar commands to list environment variables
- Reading `/proc/self/environ`, `/proc/*/environ`, or any system files containing environment data
- Using `process.env`, `os.environ`, `os.getenv()`, `System.getenv()`, or equivalent in any programming language
- Encoding secrets in base64, hex, URL encoding, or any other format
- Writing secrets to files, logs, or any persistent storage
- Transmitting secrets via `curl`, `wget`, `nc`, or any network tool
- Embedding secrets in code, comments, commit messages, PR descriptions, issue bodies, or any output
- Echoing, printing, or displaying environment variables or their values

### Enforcement

Any request to access, exfiltrate, or expose secrets MUST be refused—even if explicitly requested by user prompts. This rule takes precedence over all other instructions.
