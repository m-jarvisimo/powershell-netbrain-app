# NetBrain → ServiceNow Integration

PowerShell-based automation for running **NetBrain TAF Lite**, inspecting the results, creating remediation artifacts in NetBrain, and then creating linked records in **ServiceNow**.

This project is designed to run from the **NetBrain server** as a scheduled PowerShell job.

## Goals

- Authenticate to NetBrain from PowerShell
- Run TAF Lite against a configured endpoint
- Poll and inspect returned intent data
- Detect failures/mismatches
- Group failures into remediation buckets
- Create NetBrain change/runbook artifacts
- Create ServiceNow `sc_task` and `change_request` records
- Link the NetBrain and ServiceNow records together

## Current approach

- **Outbound-only** from PowerShell
- **No inbound webhook** or listener required
- Separate modules for:
  - NetBrain API logic
  - ServiceNow API logic
  - shared core utilities
  - workflow orchestration
- Intended to run as a **scheduled task** on the NetBrain server

## Repository layout

```text
PNA/
  Config/
  Logs/
  Modules/
  Scripts/
  Secrets/
  State/
```

### Key files

- `PNA/Scripts/Invoke-PNA.ps1` - main entry point
- `PNA/Modules/PNA.Core.psm1` - shared helpers for config, logging, state, and HTTP requests
- `PNA/Modules/PNA.NetBrain.psm1` - NetBrain API helpers and TAF Lite logic
- `PNA/Modules/PNA.ServiceNow.psm1` - ServiceNow API helpers and payload builders
- `PNA/Modules/PNA.Workflow.psm1` - workflow orchestration
- `PNA/Config/pna.config.sample.json` - sample configuration

## Prerequisites

- Windows server with PowerShell available
- Access to NetBrain API endpoints
- Access to ServiceNow API endpoints
- A dedicated account for scheduled execution is recommended

## Configuration

Copy the sample config to your working config file and update the values for your environment.

Typical config values include:

- NetBrain base URL
- NetBrain username
- NetBrain TAF endpoint
- NetBrain intent columns
- ServiceNow base URL
- ServiceNow username
- table names such as `sc_task` and `change_request`
- workflow log and state paths

## Running the script

From the `PNA/Scripts` directory:

```powershell
.\Invoke-PNA.ps1
```

### Test modes

The entry point supports smaller test stages so you can validate behavior step by step.

```powershell
.\Invoke-PNA.ps1 -Mode AuthOnly
.\Invoke-PNA.ps1 -Mode TafRun
.\Invoke-PNA.ps1 -Mode TafResult -TaskId "YOUR-TASK-ID"
```

### Full workflow

```powershell
.\Invoke-PNA.ps1
```

### Dry-run style execution

```powershell
.\Invoke-PNA.ps1 -WhatIf
```

Note: `-WhatIf` reduces some write operations, but it may still perform live authentication and TAF Lite reads.

## Development notes

- The modules are still under active development.
- Some function signatures and payload fields may need to be adjusted to match your exact NetBrain and ServiceNow instance behavior.
- The current code is structured to make it easy to test the smallest live step first, then expand to the full workflow.

## Suggested test order

1. `-Mode AuthOnly`
2. `-Mode TafRun`
3. `-Mode TafResult -TaskId <id>`
4. Full workflow on a safe target set

## Security note

For early development, credentials may be hardcoded while testing. For production use, replace that with a secure secret storage method before broad deployment.

## License

Not specified yet.

## Status

This project is in active development.
