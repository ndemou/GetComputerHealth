# GetComputerHealth

Stop wondering if your disks have free space, if Windows is up to date, if critical services are running, or if your DCs are replicating. This extensible, **open-source** toolkit automates over a hundred daily health checks you know you should be doing but don't have time for. It’s a **free**, set-and-forget health monitor that gives you **near enterprise-grade visibility** without the usual complexity, overhead, or cost.

Designed as a **lightweight** alternative to heavy monitoring suites, the framework uses native PowerShell Remoting to perform deep analysis on your infrastructure without installing a single agent. It’s perfect for a single workstation or server, but also works great for domains with a few dozen servers that you already manage via PowerShell (`Enter-PSSession`/`Invoke-Command`). It generates clean terminal output, concise Excel reports, and actionable email alerts that highlight risks before they become disasters.

Installation is extremely easy. Once you spend a few minutes getting familiar with it, you'll rarely need more than two minutes per server. If you have even a little bit of PowerShell fluency, you can easily add your own custom health tests to the mix.

# 0. Prerequisites

**For a single server or workstation:** A mail server that permits unauthenticated delivery (this is only to allow you to receive emails with results/alerts; you can always run the script manually).

**For a domain:** 1. The ability to administer servers via PowerShell Remoting (`Enter-PSSession`/`Invoke-Command`).
2. A mail server that permits unauthenticated delivery.

# 1. Architecture Overview

The toolkit operates on a **Controller-Agent** model (though agentless via PowerShell Remoting). You run the orchestration script on your management machine (the Controller), which executes tests on your servers/workstations (the Targets), then aggregates the results into Excel reports and emails them.

## Relationship Diagram

```mermaid
---
config:
  look: neo
  theme: redux
---
flowchart BT
 subgraph Controller["Controller"]
        Orchestrator["Invoke-GetComputerHealth.ps1"]
        Entry["Invoke-GetHealthDomainComputers.ps1"]
        Target["Target Servers"]
        Report["Excel files"]
        Mailer["Send-Message.ps1"]
  end
 subgraph Target["Target Computer"]
        LocalRunner["Get-ComputerHealth.ps1"]
        Updater["Update-GetHealthCode.ps1"]
        Tests["lib-health-tests.ps1"]
        Config["Suppression File"]
  end
    Entry --> Orchestrator
    Orchestrator -- "1. Connects via WinRM" --> Target
    Orchestrator -- "4. Aggregates results" --> Report
    Report -- "5. emails results using" --> Mailer
    Updater -- "2. Updates Scripts" --> LocalRunner
    LocalRunner -- "3. Executes" --> Tests
    Config -.-> LocalRunner

     Report:::Rose
     Config:::Rose
    classDef Rose stroke-width:1px, stroke-dasharray:none, stroke:#FF5978, fill:#FFDFE5, color:#8E2236
    style Target fill:#FFF9C4
```

---

# 2. Script Components Breakdown

This section explains the role of each file in your `C:\it\bin` directory.

## A. The Orchestrators (Run these)

These are the scripts you actually execute.

* **`Invoke-GetHealthDomainComputers.ps1`**
* **Role:** The "Easy Button" wrapper for testing all domain servers.
* **Function:** By default, it scans all computers running a Windows Server OS, but you are encouraged to edit it to add extra hosts or exclude others.
* **Usage:** Run this manually or schedule it to run daily (e.g., via the SYSTEM account) to check the entire domain.


* **`Invoke-GetComputerHealth.ps1`**
* **Role:** The Engine/Orchestrator. It tests the local host by default or the computers you specify.
* **Function:** It manages the workflow:
1. Connects to the local host or one or more remote computers.
2. Triggers the self-update on the remote target.
3. Runs the health checks remotely.
4. Collects output, saves it in Excel format (`C:\it\temp\`), and emails "Notable" (non-success) messages.


* **Key Parameters:** `-Computers` (list of targets), `-ExcludeServers`, `-Hide` (filters output levels).



## B. The Worker (Runs on Targets)

These scripts run locally on the servers being checked.

* **`Get-ComputerHealth.ps1`**
* **Role:** The Local Runner.
* **Function:** It loads the test library and executes the tests. It handles the logic for **Whitelisting** (suppressing known failures) and generates clean, colorized console output.
* **Usage:** Can be run interactively on a specific server for troubleshooting (e.g., `.\Get-ComputerHealth.ps1 -OutputConsoleMessages`).


* **`lib-health-tests.ps1`**
* **Role:** The Logic Library.
* **Function:** Contains the actual code for checks like `HealthTest-DiskSpace` and `HealthTest-TimeSyncPolicy`. It is a library and does not run on its own; it is loaded by the Runner.


* **`Update-GetHealthCode.ps1`**
* **Role:** The Updater.
* **Function:** Ensures the local `C:\it\bin` folder has the latest version of all scripts by downloading them from a central repository. It runs automatically before tests begin.



## C. Utilities

* **`Send-Message.ps1`**: A utility wrapper for sending SMTP emails (configured via `C:\IT\config\Send-Message.conf`).

---

# 3. Admin Guide: Installation

Replace the **PLACEHOLDERS** at the top with your actual details, then run:

```powershell
# Setup email delivery
$text = @'
{"Server":  "MAIL.SERVER.COM",
"From":  "__pc_name__+FROM@DOMAIN.COM",
"To":  "TO@DOMAIN.COM", "Port":  25, "UseSsl":  false}
'@
($text -replace '__pc_name__',$env:COMPUTERNAME) | Out-File "C:\it\config\Send-Message.conf" -Encoding utf8 -Force

# Create C:\IT\bin and download installer/updater script
if (-not (Test-Path "C:\it\bin")) { New-Item -Path "C:\it\bin" -ItemType Directory -Force }
Invoke-WebRequest -useb "https://raw.githubusercontent.com/ndemou/GetComputerHealth/refs/heads/main/Update-GetHealthCode.ps1" -OutFile "C:\it\bin\Update-GetHealthCode.ps1"

# Download all other scripts & install required modules
C:\it\bin\Update-GetHealthCode.ps1 

# Test email delivery
C:\it\bin\Send-Message.ps1 -Subject "First test from $($env:COMPUTERNAME)" -ConfigFile "C:\it\config\Send-Message.conf" -Verbose

# Perform your first health test manually
C:\it\bin\Invoke-GetComputerHealth.ps1

# Schedule the check to run automatically every day
. C:\it\bin\helpers-processes.ps1 # Imports the New-ScheduledTaskForPSScript command
New-ScheduledTaskForPSScript -ScriptPath "C:\it\bin\Invoke-GetComputerHealth.ps1" -ScheduleType Daily -Time 07:12

```

# 4. Admin Guide: Common Tasks

## How to Run a Health Check for one computer

Open PowerShell as Administrator and run:

```powershell
C:\it\bin\Invoke-GetComputerHealth.ps1

```

* **Result:** This scans the local machine, saves an Excel report to `C:\it\temp\`, and emails you any "Notable" issues (Notices/Warnings/Failures).

## How to Run a Full Domain Health Check

Open PowerShell as Administrator and run:

```powershell
C:\it\bin\Invoke-GetHealthDomainComputers.ps1

```

* **Tip:** Edit the script to add non-Server OS computers or to exclude specific servers.

## How to Suppress a False Positive (Whitelisting)

By default, the health tests will flag any deviation from a pristine Windows installation (e.g., a custom service, an extra member in the Administrators group, or an additional listening TCP port). If this is expected, you should whitelist it.

1. **Identify the whitelisting command:** Open the generated Excel report. Every message includes a column containing the exact command needed to whitelist that entry.
2. **Apply Whitelist:** Run that command on the **target machine** (or via a remote shell).

* **Under the hood:** This adds the unique signature to `C:\it\config\Get-ComputerHealth.sigs-to-suppress.txt`. Future runs will mark this specific issue as "Suppressed" and will not consider it "Notable."

## How to Check a Single Server Interactively

To debug a specific server locally:

```powershell
C:\it\bin\Get-ComputerHealth.ps1 -OutputConsoleMessages -OutputObjects -Hide DIP

```

* **Tip:** `-Hide DIP` hides **D**ebug, **I**nfo, and **P**ass messages, showing only Notices, Warnings, and Failures.

## How to Add Custom Tests

You do not need to modify the core library.

1. Create the folder `C:\it\config\Custom-HealthTests\` on the target.
2. Add a `.ps1` file containing functions named `CustomHealthTest-SomethingDescriptive`.
3. Use `Log-Pass`, `Log-Notice`, `Log-Warning`, or `Log-Failure` to report results.
* **Note:** If you include variable text (like the current date) in the main message, the signature will change, and whitelisting will break. Use the `-Comment` parameter for variable data instead.


4. The runner automatically detects and executes any function starting with `CustomHealthTest-`.

---

# 5. Directory Structure Reference

| Path | Purpose |
| --- | --- |
| `C:\it\bin\` | Contains all script files (`.ps1`). |
| `C:\it\config\` | Contains configuration files (`Send-Message.conf`) and the suppression list (`Get-ComputerHealth.sigs-to-suppress.txt`). |
| `C:\it\temp\` | Staging area for downloads and location of generated Excel reports. |
| `C:\it\log\` | Stores transcript logs of script execution. |

# 6. List of Available Tests

*Below is a sample of available tests. Run `Get-ComputerHealth.ps1 -ListAllBuiltInTests` for the most up-to-date list.*

1. **HealthTest-ADReplication**: Quick AD replication check for the local DC.
2. **HealthTest-AutoStartServicesRunning**: Checks for "Automatic" services that are stopped.
3. **HealthTest-DisksHaveFreeSpace**: Alerts if drives are low on space.
4. **HealthTest-PendingReboot**: Detects if a restart is required.
5. **HealthTest-TimeSyncAccuracy**: Measures time offset against a reliable source.
