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

This section explains the role of each file in your `C:\IT\bin` directory.

## A. The Orchestrators (Run these)

These are the scripts you actually execute.

### `Invoke-GetHealthDomainComputers.ps1` (for multiple computers; e.g. all domain Servers) 
* **Role:** The "Easy Button" wrapper for testing all domain servers.
* **Function:** By default, it scans all computers running a Windows Server OS, but you are encouraged to edit it to add extra hosts or exclude others.
* **Usage:** Run this manually or schedule it to run daily (e.g., via the SYSTEM account) to check the entire domain.


### `Invoke-GetComputerHealth.ps1` (for one computer) 
* **Role:** The Engine/Orchestrator. It tests the local host by default or the computers you specify.
* **Function:** It manages the workflow:
1. Connects to the local host or one or more remote computers.
2. Triggers the self-update on the remote target.
3. Runs the health checks remotely.
4. Collects output, saves it in Excel format (`C:\IT\temp\`), and emails "Notable" (non-success) messages.


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
* **Function:** Ensures the local `C:\IT\bin` folder has the latest version of all scripts by downloading them from a central repository. It runs automatically before tests begin.



## C. Utilities

* **`Send-Message.ps1`**: A utility wrapper for sending SMTP emails (configured via `C:\IT\config\Send-Message.conf`).

---

# 3. Admin Guide: Installation

Replace the *PLACEHOLDERS* at the top with your actual configuration, then run:

```powershell
#--------- CHANGE THIS PART ---------
$mailServer="SMTP_SERVER.CONTOSO.COM"
$mailServer="SMTP_SERVER.CONTOSO.COM"
$fromAddress="SENDER@CONTOSO.COM"
$toAddress="RECIPIENT@CONTOSO.COM"
#------------------------------------

# Create C:\IT\bin and download installer/updater script
if (-not (Test-Path "C:\IT\bin")) { New-Item -Path "C:\IT\bin" -ItemType Directory -Force }
Invoke-WebRequest -useb "https://raw.githubusercontent.com/ndemou/GetComputerHealth/refs/heads/main/Update-GetHealthCode.ps1" -OutFile "C:\IT\bin\Update-GetHealthCode.ps1"

# Download all other scripts & install required modules
C:\IT\bin\Update-GetHealthCode.ps1 

# Setup email delivery
@"
{"Server":  "$mailServer",
"From":  "$($env:COMPUTERNAME)+$fromAddress",
"To":  "$toAddress",
"Port":  25,
"UseSsl":  false}
"@ | Out-File "C:\IT\config\Send-Message.conf" -Encoding utf8 -Force

# Test email delivery
C:\IT\bin\Send-Message.ps1 -Subject "First test from $($env:COMPUTERNAME)" -ConfigFile "C:\IT\config\Send-Message.conf" -Verbose

# Perform your first health test manually
C:\IT\bin\Invoke-GetComputerHealth.ps1

# Schedule the check to run automatically every day
. C:\IT\bin\helpers-processes.ps1 # Imports the New-ScheduledTaskForPSScript command
New-ScheduledTaskForPSScript -ScriptPath "C:\IT\bin\Invoke-GetComputerHealth.ps1" -ScheduleType Daily -Time 07:12

```

# 4. Admin Guide: Common Tasks

## How to Run a Health Check for one computer

Open PowerShell as Administrator and run:

```powershell
C:\IT\bin\Invoke-GetComputerHealth.ps1

```

* **Result:** This scans the local machine, saves an Excel report to `C:\IT\temp\`, and emails you any "Notable" issues (Notices/Warnings/Failures).

## How to Run a Full Domain Health Check

Open PowerShell as Administrator and run:

```powershell
C:\IT\bin\Invoke-GetHealthDomainComputers.ps1

```

* **Tip:** Edit the script to add non-Server OS computers or to exclude specific servers.

## How to Suppress a False Positive (Whitelisting)

By default, the health tests will flag any deviation from a pristine Windows installation (e.g., a custom service, an extra member in the Administrators group, or an additional listening TCP port). If this is expected, you should whitelist it.

1. **Identify the whitelisting command:** Open the generated Excel report. Every message includes a column containing the exact command needed to whitelist that entry.
2. **Apply Whitelist:** Run that command on the **target machine** (or via a remote shell).

* **Under the hood:** This adds the unique signature to `C:\IT\config\Get-ComputerHealth.sigs-to-suppress.txt`. Future runs will mark this specific issue as "Suppressed" and will not consider it "Notable."

## How to Check a Single Server Interactively

To debug a specific server locally:

```powershell
C:\IT\bin\Get-ComputerHealth.ps1 -OutputConsoleMessages -OutputObjects -Hide DIP

```

* **Tip:** `-Hide DIP` hides **D**ebug, **I**nfo, and **P**ass messages, showing only Notices, Warnings, and Failures.

## How to Add Custom Tests

You do not need to modify the core library.

1. Create the folder `C:\IT\config\Custom-HealthTests\` on the target.
2. Add a `.ps1` file containing functions named `CustomHealthTest-SomethingDescriptive`.
3. Use `Log-Pass`, `Log-Notice`, `Log-Warning`, or `Log-Failure` to report results.
* **Note:** If you include variable text (like the current date) in the main message, the signature will change, and whitelisting will break. Use the `-Comment` parameter for variable data instead.


4. The runner automatically detects and executes any function starting with `CustomHealthTest-`.

---

# 5. Directory Structure Reference

| Path | Purpose |
| --- | --- |
| `C:\IT\bin\` | Contains all script files (`.ps1`). |
| `C:\IT\config\` | Contains configuration files (`Send-Message.conf`) and the suppression list (`Get-ComputerHealth.sigs-to-suppress.txt`). |
| `C:\IT\temp\` | Staging area for downloads and location of generated Excel reports. |
| `C:\IT\log\` | Stores transcript logs of script execution. |

# 6. List of Available Tests

This is a list of tests as of version 1.3.0. Run `Get-ComputerHealth.ps1 -ListAllBuiltInTests` to get an up-to-date list.

  1. **HealthTest-AdminSDHolderCoverage**: Checks AdminSDHolder applied to protected groups reasonably. (only for DCs)
  1. **HealthTest-ADReplication**: Quick AD replication check for this DC using RSAT cmdlets.
  1. **HealthTest-ADViewConsistency**: Cross-checks AD "view" consistency across DCs (DC list and all FSMO holders).
  1. **HealthTest-AutoStartServicesRunning**: Checks for services set to start automatically but are not currently running.
  1. **HealthTest-BitLockerStatus**
  1. **HealthTest-CertExpiry**: Alerts on soon-to-expire or expired machine certificates (LocalMachine\My).
  1. **HealthTest-ConnectivityToDCs**: Connectivity health check for all Domain Controllers.
  1. **HealthTest-CrashDumpSignals**
  1. **HealthTest-Dcdiag**: Runs DCDIAG (/c /v) and reports any failing tests; classifies basic vs extra tests.
  1. **HealthTest-DcDnsARecords**: Checks for stale/mismatched DC DNS A records vs. AD DC IPs. OnlyForDCs
  1. **HealthTest-DcDnsServerForwarder**: Checks that this domain controller is not using public DNS forwarders.
  1. **HealthTest-DefaultLocale**: Checks if the system default locale (ACP/OEMCP) matches expected values.
  1. **HealthTest-DefenderStatus**: Checks Microsoft Defender signature freshness and reports status.
  1. **HealthTest-DfsDiagTestDCs**: Smoke-tests DFSDIAG /TestDCs output for unexpected lines.
  1. **HealthTest-DfsNamespaceEnumerate**: Verifies DFS Namespace (domain-based) objects enumerate without error. (only for DCs)
  1. **HealthTest-DfsrBacklog**: Flag high DFS-R backlog for a replication group.
  1. **HealthTest-DfsrBacklogSysvol**
  1. **HealthTest-DfsReplicationState**: Validates DFS Replication (DFSR) state across replicated folders.
  1. **HealthTest-DhcpDnsCredential**: Validates DHCP DNS update credential account health. (only for DCs)
  1. **HealthTest-DhcpInAd**: Ensures DHCP server presence/authorization sane if role installed. (only for DCs)
  1. **HealthTest-DhcpScopeUtilization**
  1. **HealthTest-DisabledGpoLinksAtDomainRoot**: Detects disabled GPO links at domain root (policy choice). (only for DCs)
  1. **HealthTest-DisksHaveFreeSpace**: Checks if any fixed, removable, or network drives are low on free space.
  1. **HealthTest-DnsClientService**: Verifies DNS Client service is running.
  1. **HealthTest-DnsForwarders**: Validates DNS forwarders reachability and forbids loopback.
  1. **HealthTest-DnsRecursionConfig**: Validates DNS recursion configuration (enabled/forwarders/EDNS). OnlyForDCs
  1. **HealthTest-DnsScavenging**: Checks DNS scavenging/aging configuration (server + per-zone).
  1. **HealthTest-DnsSuffixBaseline**: Verifies key DNS suffix/devolution/registration settings for a small, single-domain AD.
  1. **HealthTest-DnsSuffixMatchesDomain**: Checks DNS suffix for the AD domain. OnlyForDomain,NotForDCs
  1. **HealthTest-DnsZoneReplicationScope**: Validates DNS zone replication scope for AD-integrated zones.
  1. **HealthTest-DnsZoneTransfers**: Verifies DNS zone transfers are restricted. OnlyForDCs
  1. **HealthTest-DomainARecordPointsToDcIp**: Checks that the domain DNS name A record points to at least one DC IP. OnlyForDomain,NotForDCs
  1. **HealthTest-DuplicateSpn**: Detects duplicate SPNs by querying AD directly (no setspn parsing).
  1. **HealthTest-EfsRecoveryAgents**: Checks presence of EFS Data Recovery Agents policy/certs. (only for DCs)
  1. **HealthTest-EventLogMaxSizes**: Ensures event log max sizes meet baseline without reading events. (only for DCs)
  1. **HealthTest-ExploitProtectionBaseline**: Baseline check for key Windows Exploit Protection (system) mitigations.
  1. **HealthTest-FirewallEnabled**: Checks if the firewall service is running and enabled for all profiles.
  1. **HealthTest-GcPlacement**: Checks GC placement (at least one per site or per-domain policy). OnlyForDCs
  1. **HealthTest-GpoVersionConsistency**: Validates GPT vs GPC version numbers for GPO consistency. (only for DCs)
  1. **HealthTest-GpupdatePolicyApply**: Runs gpupdate and validates computer and user policy application. OnlyForDomain,NotForDCs
  1. **HealthTest-GpWmiFiltersNamespaces**: Validates GP WMI filters use namespaces that exist on this host. (only for DCs)
  1. **HealthTest-HotfixBaseline**: Verifies required hotfix baseline is present. (only for DCs)
  1. **HealthTest-HyperVRunningVMs**: Checks if any Hyper-V VMs that should auto-start are not currently running.
  1. **HealthTest-HyperVVMProperties**: Checks running Hyper-V VMs for unexpected property values.
  1. **HealthTest-IisBindings**: Sanity-check IIS site bindings for common misconfigurations.
  1. **HealthTest-InstalledRolesFeatures**: Reviews installed roles/features against policy.
  1. **HealthTest-InterfaceDnsServersUseDcs**: Ensures each interface DNS server list contains only DC IPs. OnlyForDomain,NotForDCs
  1. **HealthTest-IPv6Binding**: Verifies IPv6 binding state per policy (PS5.1-safe).
  1. **HealthTest-IsTPMActivated**: Checks if TPM is activated. OnlyForMobile
  1. **HealthTest-KccConnectivity**: Ensures KCC created inbound connections for every DC. OnlyForDCs
  1. **HealthTest-KerberosEncryptionTypes**: Reports accounts permitting RC4 via msDS-SupportedEncryptionTypes. (only for DCs)
  1. **HealthTest-KrbtgtAge**: Flags stale krbtgt (pwdLastSet age above threshold). (only for DCs)
  1. **HealthTest-LdapSigningChannelBinding**: Ensures LDAP signing and channel binding settings are enforced.
  1. **HealthTest-LocalAcntRequirePass**: Checks if any local user accounts have PasswordRequired set to False.
  1. **HealthTest-LocalAdminsBaseline**
  1. **HealthTest-MalwareProtectionFeatures**: Checks if all Microsoft Defender (Malware Protection) features are enabled.
  1. **HealthTest-NetworkInterfaceMetrics**: Checks active interface metrics for sane binding preference. (only for DCs)
  1. **HealthTest-Nic**
  1. **HealthTest-NltestSiteDiscovery**: Verifies NLTEST /dsgetsite can determine the client AD site. OnlyForDomain,NotForDCs
  1. **HealthTest-NonDefaultShares**: Checks if there are any non-default file or print shares on this machine.
  1. **HealthTest-NonMicrosoftServices**: Reports a warning for any non Microsoft service it finds
  1. **HealthTest-NtdsLogVolumeFree**: Ensures NTDS log volume free space above threshold. OnlyForDCs
  1. **HealthTest-NtdsPathsLocation**: Verifies NTDS.dit and log paths are on intended volumes.
  1. **HealthTest-NtfsDirtyBit**: Check NTFS volumes for the "dirty" bit.
  1. **HealthTest-NtlmHardening**: Checks NTLM hardening and emits an advisory when the default (3) is in effect.
  1. **HealthTest-PagefileSanity**: Checks that a pagefile exists and meets a minimum size.
  1. **HealthTest-PendingReboot**: Detects whether a reboot is pending on this host.
  1. **HealthTest-PreWin2000Group**: Reports members of 'Pre-Windows 2000 Compatible Access' (should be empty). (only for DCs)
  1. **HealthTest-RamPressure**: Snapshot test for low free RAM.
  1. **HealthTest-RdpHardening**: Checks RDP hardening (NLA enabled and cert bound). (only for DCs)
  1. **HealthTest-RecentDiskErrors**
  1. **HealthTest-RecentWindowsScan**: Checks if Windows Defender performed a quick scan recently
  1. **HealthTest-RecycleBinEnabled**: Confirms AD Recycle Bin is enabled.
  1. **HealthTest-ReplicationLatency**: Checks replication latency on schema/config partitions.
  1. **HealthTest-RequiredSrvRecords**: Confirms required SRV records exist in _msdcs.
  1. **HealthTest-RestrictAnonymous**: Checks anonymous access hardening against modern baselines.
  1. **HealthTest-ReverseZonesPresent**: Confirms reverse lookup zones exist for known subnets. OnlyForDCs
  1. **HealthTest-RidManager**: Runs DCDIAG RIDManager and checks for failures or low pool signals. OnlyForDCs
  1. **HealthTest-RodcPrp**: Reviews RODC PRP (allow/deny) presence where RODCs exist. (only for DCs)
  1. **HealthTest-SchanelBaseline**: Basic Schannel hardening: SSL3/TLS1.0 disabled, TLS1.2 enabled. (only for DCs)
  1. **HealthTest-ScheduledTasks**
  1. **HealthTest-ScheduledTasksLastResult**: Evaluates scheduled task "Last Result" codes on the local host, suppressing informational values, and reports only meaningful warnings and failures.
  1. **HealthTest-SchemaVersionConsistency**: Ensures AD schema objectVersion matches across all DCs.
  1. **HealthTest-ServiceAccountsPwdNeverExpires**: Flags service accounts with PasswordNeverExpires.
  1. **HealthTest-ShadowStorage**: Checks shadow storage presence and size info.
  1. **HealthTest-ShareReasonableness**: Audits SMB shares for broad access and hygiene issues.
  1. **HealthTest-SingleDefaultGateway**: Ensures the host does not have multiple default gateways.
  1. **HealthTest-Smb1Disabled**
  1. **HealthTest-SmbSigningRequired**: Requires SMB signing on the server.
  1. **HealthTest-SoftwareLicensing**: Verifies Windows are Licensed.
  1. **HealthTest-StartupItems**: Scrapes common auto-start locations for rogues.
  1. **HealthTest-Storage**: Performs a comprehensive health check of all local physical disks using Windows Storage APIs.
  1. **HealthTest-SystemScheduledTasks**: Lists SYSTEM-scheduled tasks that are disabled, stale, or failing.
  1. **HealthTest-SysvolAclHygiene**: Checks SYSVOL NTFS ACLs do not grant write to broad principals. OnlyForDCs
  1. **HealthTest-SysvolContentConsistency**: Compares SYSVOL policy tree manifest across DCs (count+hash). OnlyForDCs
  1. **HealthTest-SysvolNetlogonAccessible**: Tests SYSVOL/NETLOGON accessibility across DCs.
  1. **HealthTest-TimeSyncAccuracy**: Measures time offset vs. a time source and compares against thresholds.
  1. **HealthTest-TimeSyncPolicy**: Validates that the host's time sync topology matches AD/NTP best practices.
  1. **HealthTest-TombstoneLifetime**: Checks tombstoneLifetime and links interval sanity.
  1. **HealthTest-TrustsVerify**: Verifies domain trusts and performs netdom /verify.
  1. **HealthTest-UnconstrainedDelegationAccounts**: Finds accounts with unconstrained delegation (excludes DCs by default).
  1. **HealthTest-UnexpectedListeningPorts**: Flags unexpected listening TCP ports; ignores 49152-65535 and notes optional baseline ports (3389, 47001, 593). (only for DCs)
  1. **HealthTest-UnsignedDrivers**: Flags unsigned PnP drivers, ignoring common false positives from core system components. (only for DCs)
  1. **HealthTest-UnusedEnabledAdapters**: Flags enabled NICs that are disconnected (cleanup). (only for DCs)
  1. **HealthTest-UpdateAge**: Flags stale Windows Update posture based on last successful install date.
  1. **HealthTest-VssWriters**: Lists VSS writers and flags non-stable states.
  1. **HealthTest-WinRMListening**: Confirms WinRM is running and responsive.
  1. **HealthTest-WmiRepository**: Verifies WMI repository consistency.
