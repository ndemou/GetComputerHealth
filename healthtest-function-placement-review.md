# HealthTest Function Placement Review

Generated from current `ht-*.ps1` files.

| Function | File | One-sentence synopsis | Placement opinion |
|---|---|---|---|
| `HealthTest-AdminSDHolderCoverage` | `ht-AD-GPO-mgmt.ps1` | Checks AdminSDHolder applied to protected groups reasonably. OnlyForDomainServers. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-ADReplicationDomainRepadmin` | `ht-AD-GPO-mgmt.ps1` | HealthTest-ADReplicationDomainRepadmin: Domain-wide AD replication health using repadmin.exe (replsum + showreps). DC-only; fails if repadmin or AD DS prerequisites are missing. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-ADReplicationLocalRSAT` | `ht-AD-GPO-mgmt.ps1` | HealthTest-ADReplicationLocalRSAT: Local DC AD replication partner health using RSAT AD cmdlets (Get-ADReplicationPartnerMetadata). DC-only; fails if AD module/ADWS prerequisites are missing. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-ADViewConsistency` | `ht-AD-GPO-mgmt.ps1` | Active Directory & GPO Management. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-AutoStartServicesRunning` | `ht-srvc-exe-resolve.ps1` | Checks auto start services running health expectations. | Keep in `ht-srvc-exe-resolve.ps1`; moved per placement review recommendation. |
| `HealthTest-BitLockerStatus` | `ht-win-os-hyg.ps1` | Checks bit locker status health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-CertExpiry` | `ht-os-perf-hw.ps1` | Alerts on soon-to-expire or expired machine certificates (LocalMachine\My). | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-ConnectivityToDCs` | `ht-net-conn.ps1` | Network & Connectivity. | Keep in `ht-net-conn.ps1`; this aligns with the `Network Connectivity` scope. |
| `HealthTest-CrashDumpSignals` | `ht-win-os-hyg.ps1` | <# .SYNOPSIS Looks for crash dumps and bugcheck events as indicators of recent system crashes. #>. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-Dcdiag` | `ht-AD-GPO-mgmt.ps1` | Checks dcdiag health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-DcDnsARecords` | `ht-DNS-DHCP-srvc.ps1` | Checks for stale/mismatched DC DNS A records vs. AD DC IPs. OnlyForDCs. | Keep in `ht-DNS-DHCP-srvc.ps1`; moved per placement review recommendation. |
| `HealthTest-DcDnsRegistration` | `ht-DNS-DHCP-srvc.ps1` | Checks dc dns registration health expectations. | Keep in `ht-DNS-DHCP-srvc.ps1`; moved per placement review recommendation. |
| `HealthTest-DcDnsServerForwarder` | `ht-DNS-DHCP-srvc.ps1` | Checks dc dns server forwarder health expectations. | Keep in `ht-DNS-DHCP-srvc.ps1`; this aligns with the `DNS & DHCP Services` scope. |
| `HealthTest-DefaultLocale` | `ht-win-os-hyg.ps1` | Checks if the system default locale (ACP/OEMCP) matches expected values. | Keep in `ht-win-os-hyg.ps1`; moved per placement review recommendation. |
| `HealthTest-DefenderStatus` | `ht-win-os-hyg.ps1` | Checks defender status health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-DfsDiagTestDCs` | `ht-AD-GPO-mgmt.ps1` | Checks dfs diag test dcs health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-DfsNamespaceEnumerate` | `ht-AD-GPO-mgmt.ps1` | Checks dfs namespace enumerate health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-DfsrBacklog` | `ht-AD-GPO-mgmt.ps1` | Checks dfsr backlog health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-DfsrBacklogSysvol` | `ht-AD-GPO-mgmt.ps1` | Checks dfsr backlog sysvol health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-DfsReplicationState` | `ht-AD-GPO-mgmt.ps1` | Checks dfs replication state health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-DhcpDnsCredential` | `ht-DNS-DHCP-srvc.ps1` | System Configuration & Feature Discovery. | Keep in `ht-DNS-DHCP-srvc.ps1`; moved per placement review recommendation. |
| `HealthTest-DhcpInAd` | `ht-AD-GPO-mgmt.ps1` | Checks dhcp in ad health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-DhcpScopeUtilization` | `ht-DNS-DHCP-srvc.ps1` | <# .SYNOPSIS Detects DHCP scopes whose utilization is close to exhaustion. #>. | Keep in `ht-DNS-DHCP-srvc.ps1`; moved per placement review recommendation. |
| `HealthTest-DisabledGpoLinksAtDomainRoot` | `ht-AD-GPO-mgmt.ps1` | Detects disabled GPO links at domain root (policy choice). OnlyForDCs. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-DisksHaveFreeSpace` | `ht-os-perf-hw.ps1` | Checks if any fixed, removable, or network drives are low on free space. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-DnsClientService` | `ht-DNS-DHCP-srvc.ps1` | Checks dns client service health expectations. | Keep in `ht-DNS-DHCP-srvc.ps1`; this aligns with the `DNS & DHCP Services` scope. |
| `HealthTest-DnsForwarders` | `ht-DNS-DHCP-srvc.ps1` | Checks dns forwarders health expectations. | Keep in `ht-DNS-DHCP-srvc.ps1`; this aligns with the `DNS & DHCP Services` scope. |
| `HealthTest-DnsRecursionConfig` | `ht-DNS-DHCP-srvc.ps1` | Checks dns recursion config health expectations. | Keep in `ht-DNS-DHCP-srvc.ps1`; this aligns with the `DNS & DHCP Services` scope. |
| `HealthTest-DnsScavenging` | `ht-DNS-DHCP-srvc.ps1` | DNS & DHCP Services. | Keep in `ht-DNS-DHCP-srvc.ps1`; this aligns with the `DNS & DHCP Services` scope. |
| `HealthTest-DnsSuffixBaseline` | `ht-DNS-DHCP-srvc.ps1` | Verifies key DNS suffix/devolution/registration settings for a small, single-domain AD. | Keep in `ht-DNS-DHCP-srvc.ps1`; moved per placement review recommendation. |
| `HealthTest-DnsSuffixMatchesDomain` | `ht-DNS-DHCP-srvc.ps1` | Checks dns suffix matches domain health expectations. | Keep in `ht-DNS-DHCP-srvc.ps1`; this aligns with the `DNS & DHCP Services` scope. |
| `HealthTest-DnsZoneReplicationScope` | `ht-DNS-DHCP-srvc.ps1` | Checks dns zone replication scope health expectations. | Keep in `ht-DNS-DHCP-srvc.ps1`; this aligns with the `DNS & DHCP Services` scope. |
| `HealthTest-DnsZoneTransfers` | `ht-DNS-DHCP-srvc.ps1` | Checks dns zone transfers health expectations. | Keep in `ht-DNS-DHCP-srvc.ps1`; this aligns with the `DNS & DHCP Services` scope. |
| `HealthTest-DomainARecordPointsToDcIp` | `ht-win-os-hyg.ps1` | Checks that the domain DNS name A record points to at least one DC IP. OnlyForDomain,NotForDCs IMPORTANT: Invoke-GetHealthDomainComputers.ps1 must pass all DC IPs via `-IpsOfAllDcs`. E.g: @("192.168.0.1","192.168.0.2"). | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-Dummy` | `ht-special.ps1` | Special. | Keep in `ht-special.ps1`; this aligns with the `Special` scope. |
| `HealthTest-DuplicateSpn` | `ht-os-perf-hw.ps1` | Detects duplicate SPNs by querying AD directly (no setspn parsing). | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-EfsRecoveryAgents` | `ht-win-os-hyg.ps1` | Checks efs recovery agents health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-EventLogMaxSizes` | `ht-os-perf-hw.ps1` | Ensures event log max sizes meet baseline without reading events. OnlyForDomainServers. | Keep in `ht-os-perf-hw.ps1`; moved per placement review recommendation. |
| `HealthTest-ExploitProtectionBaseline` | `ht-syscfg-featdisc.ps1` | Baseline check for key Windows Exploit Protection (system) mitigations. | Keep in `ht-syscfg-featdisc.ps1`; moved per placement review recommendation. |
| `HealthTest-FirewallEnabled` | `ht-win-os-hyg.ps1` | Checks firewall enabled health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-GcPlacement` | `ht-os-perf-hw.ps1` | Checks GC placement (at least one per site or per-domain policy). OnlyForDCs. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-GpoVersionConsistency` | `ht-AD-GPO-mgmt.ps1` | Checks gpo version consistency health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-GpupdatePolicyApply` | `ht-win-os-hyg.ps1` | Runs gpupdate and validates computer and user policy application. OnlyForDomain,NotForDCs. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-GpWmiFiltersNamespaces` | `ht-win-os-hyg.ps1` | Validates GP WMI filters use namespaces that exist on this host. OnlyForDomainServers. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-HotfixBaseline` | `ht-win-os-hyg.ps1` | Checks hotfix baseline health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-HyperVRunningVMs` | `ht-hyperv-mgmt.ps1` | Checks hyper vrunning vms health expectations. | Keep in `ht-hyperv-mgmt.ps1`; this aligns with the `Hyper-V Management` scope. |
| `HealthTest-HyperVVMProperties` | `ht-hyperv-mgmt.ps1` | Hyper-V Management. | Keep in `ht-hyperv-mgmt.ps1`; this aligns with the `Hyper-V Management` scope. |
| `HealthTest-IisBindings` | `ht-os-perf-hw.ps1` | Sanity-check IIS site bindings for common misconfigurations. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-InstalledRolesFeatures` | `ht-syscfg-featdisc.ps1` | Checks installed roles features health expectations. | Keep in `ht-syscfg-featdisc.ps1`; this aligns with the `System Configuration & Feature Discovery` scope. |
| `HealthTest-InterfaceDnsServersUseDcs` | `ht-DNS-DHCP-srvc.ps1` | Ensures each interface DNS server list contains only DC IPs. OnlyForDomain,NotForDCs IMPORTANT: Invoke-GetHealthDomainComputers.ps1 must pass all DC IPs via `-IpsOfAllDcs`. E.g: @("192.168.0.1","192.168.0.2"). | Keep in `ht-DNS-DHCP-srvc.ps1`; moved per placement review recommendation. |
| `HealthTest-IPv6Binding` | `ht-net-conn.ps1` | Verifies IPv6 binding state per policy (PS5.1-safe). | Keep in `ht-net-conn.ps1`; moved per placement review recommendation. |
| `HealthTest-IsTPMActivated` | `ht-os-perf-hw.ps1` | Checks if TPM is activated. OnlyForMobile. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-KccConnectivity` | `ht-AD-GPO-mgmt.ps1` | Checks kcc connectivity health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-KerberosEncryptionTypes` | `ht-AD-GPO-mgmt.ps1` | Checks kerberos encryption types health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-KrbtgtAge` | `ht-AD-GPO-mgmt.ps1` | Flags stale krbtgt (pwdLastSet age above threshold). OnlyForDomainServers. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-LargeDirectories` | `ht-file-dir-anlz.ps1` | File & Directory Analysis. | Keep in `ht-file-dir-anlz.ps1`; this aligns with the `File & Directory Analysis` scope. |
| `HealthTest-LdapSigningChannelBinding` | `ht-os-perf-hw.ps1` | Ensures LDAP signing and channel binding settings are enforced. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-LocalAcntRequirePass` | `ht-win-os-hyg.ps1` | Checks local acnt require pass health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-LocalAdminsBaseline` | `ht-AD-GPO-mgmt.ps1` | Checks local admins baseline health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-MalwareProtectionFeatures` | `ht-syscfg-featdisc.ps1` | Checks if all Microsoft Defender (Malware Protection) features are enabled. | Keep in `ht-syscfg-featdisc.ps1`; this aligns with the `System Configuration & Feature Discovery` scope. |
| `HealthTest-NetworkInterfaceMetrics` | `ht-net-conn.ps1` | Checks network interface metrics health expectations. | Keep in `ht-net-conn.ps1`; this aligns with the `Network Connectivity` scope. |
| `HealthTest-Nic` | `ht-net-conn.ps1` | <# .SYNOPSIS Checks physical NICs for link problems and significant error rates. #>. | Keep in `ht-net-conn.ps1`; moved per placement review recommendation. |
| `HealthTest-NltestSiteDiscovery` | `ht-win-os-hyg.ps1` | Verifies NLTEST /dsgetsite can determine the client AD site. OnlyForDomain,NotForDCs. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-NonDefaultShares` | `ht-win-os-hyg.ps1` | Checks non default shares health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-NonMicrosoftServices` | `ht-srvc-exe-resolve.ps1` | Reports a warning for any non Microsoft service it finds. | Keep in `ht-srvc-exe-resolve.ps1`; moved per placement review recommendation. |
| `HealthTest-NtdsLogVolumeFree` | `ht-win-os-hyg.ps1` | Ensures NTDS log volume free space above threshold. OnlyForDCs. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-NtdsPathsLocation` | `ht-os-perf-hw.ps1` | Verifies NTDS.dit and log paths are on intended volumes. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-NtfsDirtyBit` | `ht-os-perf-hw.ps1` | Checks ntfs dirty bit health expectations. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-NtlmHardening` | `ht-win-os-hyg.ps1` | Checks ntlm hardening health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-PagefileSanity` | `ht-os-perf-hw.ps1` | Checks pagefile sanity health expectations. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-PendingReboot` | `ht-win-os-hyg.ps1` | Detects whether a reboot is pending on this host. | Keep in `ht-win-os-hyg.ps1`; moved per placement review recommendation. |
| `HealthTest-PreWin2000Group` | `ht-AD-GPO-mgmt.ps1` | Checks pre win2000group health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-RamPressure` | `ht-os-perf-hw.ps1` | Snapshot test for low free RAM. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-RdpHardening` | `ht-win-os-hyg.ps1` | Checks rdp hardening health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-RecentDiskErrors` | `ht-os-perf-hw.ps1` | Checks recent disk errors health expectations. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-RecentWindowsScan` | `ht-win-os-hyg.ps1` | Windows OS Hygiene. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-RecycleBinEnabled` | `ht-os-perf-hw.ps1` | Confirms AD Recycle Bin is enabled. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-ReplicationLatency` | `ht-os-perf-hw.ps1` | Checks replication latency on schema/config partitions. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-RequiredSrvRecords` | `ht-os-perf-hw.ps1` | Confirms some important SRV records exist: _ldap._tcp.dc._msdcs.<domain> = where are the Domain Controllers (LDAP over TCP)? _kerberos._tcp.<domain> = where are Kerberos KDCs over TCP? _kerberos._udp.<domain> = where are Kerberos KDCs over UDP?. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-RestrictAnonymous` | `ht-win-os-hyg.ps1` | Checks restrict anonymous health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-ReverseZonesPresent` | `ht-DNS-DHCP-srvc.ps1` | Checks reverse zones present health expectations. | Keep in `ht-DNS-DHCP-srvc.ps1`; this aligns with the `DNS & DHCP Services` scope. |
| `HealthTest-RidManager` | `ht-AD-GPO-mgmt.ps1` | Checks rid manager health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-RodcPrp` | `ht-AD-GPO-mgmt.ps1` | Checks rodc prp health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-SchanelBaseline` | `ht-win-os-hyg.ps1` | Checks schanel baseline health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-ScheduledTasks` | `ht-schtasks-master.ps1` | Scheduled Task Master Cluster. | Keep in `ht-schtasks-master.ps1`; this aligns with the `Scheduled Tasks` scope. |
| `HealthTest-ScheduledTasksLastResult` | `ht-schtasks-master.ps1` | Evaluates scheduled task "Last Result" codes on the local host, suppressing informational values, and reports only meaningful warnings and failures. | Keep in `ht-schtasks-master.ps1`; moved per placement review recommendation. |
| `HealthTest-SchemaVersionConsistency` | `ht-os-perf-hw.ps1` | Ensures AD schema objectVersion matches across all DCs. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-ServiceAccountsPwdNeverExpires` | `ht-srvc-exe-resolve.ps1` | Flags service accounts with PasswordNeverExpires. | Keep in `ht-srvc-exe-resolve.ps1`; moved per placement review recommendation. |
| `HealthTest-ShadowStorage` | `ht-AD-GPO-mgmt.ps1` | Checks shadow storage health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-ShareReasonableness` | `ht-os-perf-hw.ps1` | Audits SMB shares for broad access and hygiene issues. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-SingleDefaultGateway` | `ht-net-conn.ps1` | Checks single default gateway health expectations. | Keep in `ht-net-conn.ps1`; this aligns with the `Network Connectivity` scope. |
| `HealthTest-Smb1Disabled` | `ht-win-os-hyg.ps1` | Checks smb1disabled health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-SmbSigningRequired` | `ht-win-os-hyg.ps1` | Requires SMB signing on the server. | Keep in `ht-win-os-hyg.ps1`; moved per placement review recommendation. |
| `HealthTest-SoftwareLicensing` | `ht-os-perf-hw.ps1` | Verifies Windows are Licensed. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-StartupItems` | `ht-syscfg-featdisc.ps1` | Checks startup items health expectations. | Keep in `ht-syscfg-featdisc.ps1`; moved per placement review recommendation. |
| `HealthTest-Storage` | `ht-os-perf-hw.ps1` | Checks storage health expectations. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-SystemScheduledTasks` | `ht-schtasks-master.ps1` | Checks system scheduled tasks health expectations. | Keep in `ht-schtasks-master.ps1`; this aligns with the `Scheduled Tasks` scope. |
| `HealthTest-SysvolAclHygiene` | `ht-AD-GPO-mgmt.ps1` | Checks sysvol acl hygiene health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-SysvolContentConsistency` | `ht-AD-GPO-mgmt.ps1` | Compares SYSVOL policy tree manifest across DCs (count+hash). OnlyForDCs. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-SysvolNetlogonAccessible` | `ht-AD-GPO-mgmt.ps1` | Tests SYSVOL/NETLOGON accessibility across DCs. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-TimeSyncAccuracy` | `ht-os-perf-hw.ps1` | HealthTest-ADReplicationLocalRSAT: Local DC AD replication partner health using RSAT AD cmdlets (Get-ADReplicationPartnerMetadata). DC-only; fails if AD module/ADWS prerequisites are missing. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-TimeSyncPolicy` | `ht-os-perf-hw.ps1` | OS Performance & Hardware. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-TombstoneLifetime` | `ht-os-perf-hw.ps1` | Checks tombstoneLifetime and links interval sanity. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-TrustsVerify` | `ht-AD-GPO-mgmt.ps1` | Checks trusts verify health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; this aligns with the `Active Directory & GPO Management` scope. |
| `HealthTest-UnconstrainedDelegationAccounts` | `ht-os-perf-hw.ps1` | Finds accounts with unconstrained delegation (excludes DCs by default). | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-UnexpectedListeningPorts` | `ht-AD-GPO-mgmt.ps1` | Flags unexpected listening TCP ports; ignores 49152-65535 and notes optional baseline ports (3389, 47001, 593). OnlyForDomainServers. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-UnsignedDrivers` | `ht-win-os-hyg.ps1` | Checks unsigned drivers health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-UnusedEnabledAdapters` | `ht-AD-GPO-mgmt.ps1` | Checks unused enabled adapters health expectations. | Keep in `ht-AD-GPO-mgmt.ps1`; moved per placement review recommendation. |
| `HealthTest-UpdateAge` | `ht-os-perf-hw.ps1` | Flags stale Windows Update posture based on last successful install date. | Keep in `ht-os-perf-hw.ps1`; this aligns with the `OS, Performance & Hardware` scope. |
| `HealthTest-VssWriters` | `ht-win-os-hyg.ps1` | Checks vss writers health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
| `HealthTest-WinRMListening` | `ht-net-conn.ps1` | Checks win rmlistening health expectations. | Keep in `ht-net-conn.ps1`; moved per placement review recommendation. |
| `HealthTest-WmiRepository` | `ht-win-os-hyg.ps1` | Checks wmi repository health expectations. | Keep in `ht-win-os-hyg.ps1`; this aligns with the `Windows OS Hygiene` scope. |
