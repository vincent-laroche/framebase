# Framebase MCP (source-only)

This local stdio server is a thin wrapper over the private Framebase agent-operation HTTP contract. It exposes only three proposal-first tools: create a tag proposal, inspect an operation, and apply a matching owner-approved proposal.

It has no direct database, R2, original-file, UI-automation, purge, credential-creation, or model capability. It requires `FRAMEBASE_API_URL` and a previously delegated `FRAMEBASE_AGENT_CREDENTIAL` at launch; neither is logged. The package is not hosted or deployed.
