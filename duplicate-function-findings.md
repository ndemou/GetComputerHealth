# Duplicate Function Name Report

Generated: 2026-03-10 16:17:44 +02:00

## Summary

- Total function definitions: 485
- Function names with duplicates: 130
- Total duplicate occurrences (across those names): 401
- Exact duplicate bodies: 75
- Whitespace/comment-only differences: 22
- Different implementations (same name): 33

## Same Name, Different Implementations

| Function | Occurrences | Raw Variants | Normalized Variants | Locations | Effective Implementation |
|---|---:|---:|---:|---|---|
| `HealthTest-ADReplicationDomainRepadmin` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1724 | ht-win-os-hyg.ps1 |
| `HealthTest-ADReplicationLocalRSAT` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1807 | ht-win-os-hyg.ps1 |
| `HealthTest-BitLockerStatus` | 2 | 2 | 2 | ht-win-os-hyg.ps1:1602<br>ht-win-os-hyg.ps1:1890 | ht-win-os-hyg.ps1 |
| `HealthTest-CrashDumpSignals` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1439 | ht-win-os-hyg.ps1 |
| `HealthTest-DhcpScopeUtilization` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1621 | ht-win-os-hyg.ps1 |
| `HealthTest-DisabledGpoLinksAtDomainRoot` | 1 | 1 | 1 | ht-win-os-hyg.ps1:726 | ht-win-os-hyg.ps1 |
| `HealthTest-DnsSuffixBaseline` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1657 | ht-win-os-hyg.ps1 |
| `HealthTest-DomainARecordPointsToDcIp` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1231 | ht-win-os-hyg.ps1 |
| `HealthTest-DuplicateSpn` | 1 | 1 | 1 | ht-os-perf-hw.ps1:2333 | ht-os-perf-hw.ps1 |
| `HealthTest-EventLogMaxSizes` | 1 | 1 | 1 | ht-win-os-hyg.ps1:788 | ht-win-os-hyg.ps1 |
| `HealthTest-GpupdatePolicyApply` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1355 | ht-win-os-hyg.ps1 |
| `HealthTest-GpWmiFiltersNamespaces` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1036 | ht-win-os-hyg.ps1 |
| `HealthTest-IisBindings` | 1 | 1 | 1 | ht-os-perf-hw.ps1:948 | ht-os-perf-hw.ps1 |
| `HealthTest-InterfaceDnsServersUseDcs` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1267 | ht-win-os-hyg.ps1 |
| `HealthTest-IPv6Binding` | 1 | 1 | 1 | ht-os-perf-hw.ps1:2197 | ht-os-perf-hw.ps1 |
| `HealthTest-KrbtgtAge` | 1 | 1 | 1 | ht-win-os-hyg.ps1:874 | ht-win-os-hyg.ps1 |
| `HealthTest-Nic` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1529 | ht-win-os-hyg.ps1 |
| `HealthTest-NltestSiteDiscovery` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1322 | ht-win-os-hyg.ps1 |
| `HealthTest-NonDefaultShares` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1984 | ht-win-os-hyg.ps1 |
| `HealthTest-NonMicrosoftServices` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1578 | ht-os-perf-hw.ps1 |
| `HealthTest-NtdsLogVolumeFree` | 1 | 1 | 1 | ht-win-os-hyg.ps1:889 | ht-win-os-hyg.ps1 |
| `HealthTest-RecentWindowsScan` | 1 | 1 | 1 | ht-win-os-hyg.ps1:5 | ht-win-os-hyg.ps1 |
| `HealthTest-RestrictAnonymous` | 1 | 1 | 1 | ht-win-os-hyg.ps1:2024 | ht-win-os-hyg.ps1 |
| `HealthTest-ScheduledTasksLastResult` | 1 | 1 | 1 | ht-os-perf-hw.ps1:699 | ht-os-perf-hw.ps1 |
| `HealthTest-ShadowStorage` | 1 | 1 | 1 | ht-win-os-hyg.ps1:302 | ht-win-os-hyg.ps1 |
| `HealthTest-SysvolContentConsistency` | 1 | 1 | 1 | ht-win-os-hyg.ps1:967 | ht-win-os-hyg.ps1 |
| `HealthTest-UnexpectedListeningPorts` | 1 | 1 | 1 | ht-win-os-hyg.ps1:476 | ht-win-os-hyg.ps1 |
| `HealthTest-UnsignedDrivers` | 1 | 1 | 1 | ht-win-os-hyg.ps1:372 | ht-win-os-hyg.ps1 |
| `HealthTest-VssWriters` | 1 | 1 | 1 | ht-win-os-hyg.ps1:292 | ht-win-os-hyg.ps1 |
| `HealthTest-WinRMListening` | 1 | 1 | 1 | ht-win-os-hyg.ps1:277 | ht-win-os-hyg.ps1 |
| `HealthTest-WmiRepository` | 1 | 1 | 1 | ht-win-os-hyg.ps1:285 | ht-win-os-hyg.ps1 |
| `Resolve-ServiceExecutable` | 2 | 2 | 2 | ht-srvc-exe-resolve.ps1:1797<br>ht-srvc-exe-resolve.ps1:2931 | ht-srvc-exe-resolve.ps1 |
| `Start-HealthTestVeeamRecentBackupsExist` | 1 | 1 | 1 | ht-special.ps1:18 | ht-special.ps1 |

## Same Name, Whitespace/Comment-Only Differences

| Function | Occurrences | Raw Variants | Normalized Variants | Locations | Effective Implementation |
|---|---:|---:|---:|---|---|
| `HealthTest-AutoStartServicesRunning` | 1 | 1 | 1 | ht-win-os-hyg.ps1:91 | ht-win-os-hyg.ps1 |
| `HealthTest-DefaultLocale` | 1 | 1 | 1 | ht-syscfg-featdisc.ps1:268 | ht-syscfg-featdisc.ps1 |
| `HealthTest-DefenderStatus` | 1 | 1 | 1 | ht-win-os-hyg.ps1:202 | ht-win-os-hyg.ps1 |
| `HealthTest-DhcpDnsCredential` | 1 | 1 | 1 | ht-syscfg-featdisc.ps1:9 | ht-syscfg-featdisc.ps1 |
| `HealthTest-DhcpInAd` | 1 | 1 | 1 | ht-syscfg-featdisc.ps1:22 | ht-syscfg-featdisc.ps1 |
| `HealthTest-DnsZoneTransfers` | 1 | 1 | 1 | ht-DNS-DHCP-srvc.ps1:31 | ht-DNS-DHCP-srvc.ps1 |
| `HealthTest-EfsRecoveryAgents` | 2 | 2 | 1 | ht-win-os-hyg.ps1:717<br>ht-win-os-hyg.ps1:1694 | ht-win-os-hyg.ps1 |
| `HealthTest-GpoVersionConsistency` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:235 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-HotfixBaseline` | 2 | 2 | 1 | ht-win-os-hyg.ps1:774<br>ht-win-os-hyg.ps1:1658 | ht-win-os-hyg.ps1 |
| `HealthTest-KerberosEncryptionTypes` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:294 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-LocalAcntRequirePass` | 1 | 1 | 1 | ht-win-os-hyg.ps1:1793 | ht-win-os-hyg.ps1 |
| `HealthTest-LocalAdminsBaseline` | 2 | 2 | 1 | ht-win-os-hyg.ps1:1253<br>ht-win-os-hyg.ps1:1959 | ht-win-os-hyg.ps1 |
| `HealthTest-NetworkInterfaceMetrics` | 1 | 1 | 1 | ht-net-conn.ps1:111 | ht-net-conn.ps1 |
| `HealthTest-PreWin2000Group` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:587 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-RecentDiskErrors` | 2 | 2 | 1 | ht-os-perf-hw.ps1:2586<br>ht-os-perf-hw.ps1:2834 | ht-os-perf-hw.ps1 |
| `HealthTest-RidManager` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:128 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-RodcPrp` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:355 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-Smb1Disabled` | 1 | 1 | 1 | ht-win-os-hyg.ps1:256 | ht-win-os-hyg.ps1 |
| `HealthTest-StartupItems` | 1 | 1 | 1 | ht-win-os-hyg.ps1:336 | ht-win-os-hyg.ps1 |
| `HealthTest-SystemScheduledTasks` | 1 | 1 | 1 | ht-schtasks-master.ps1:78 | ht-schtasks-master.ps1 |
| `HealthTest-SysvolAclHygiene` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:411 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-UnusedEnabledAdapters` | 1 | 1 | 1 | ht-net-conn.ps1:104 | ht-net-conn.ps1 |

## Exact Duplicate Bodies

| Function | Occurrences | Raw Variants | Normalized Variants | Locations | Effective Implementation |
|---|---:|---:|---:|---|---|
| `Convert-LicenseStatus` | 1 | 1 | 1 | ht-os-perf-hw.ps1:2002 | ht-os-perf-hw.ps1 |
| `Find-LargeDirectory` | 1 | 1 | 1 | ht-file-dir-anlz.ps1:26 | ht-file-dir-anlz.ps1 |
| `Get-AvailMB` | 2 | 1 | 1 | ht-os-perf-hw.ps1:34<br>ht-os-perf-hw.ps1:937 | ht-os-perf-hw.ps1 |
| `Get-BaseServiceName` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:548<br>ht-srvc-exe-resolve.ps1:1362 | ht-srvc-exe-resolve.ps1 |
| `Get-DaysSinceLastVirusScan` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:1049<br>ht-srvc-exe-resolve.ps1:1880 | ht-srvc-exe-resolve.ps1 |
| `Get-DomainControllers` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:830<br>ht-srvc-exe-resolve.ps1:1661 | ht-srvc-exe-resolve.ps1 |
| `Get-FreeGB` | 1 | 1 | 1 | ht-os-perf-hw.ps1:2389 | ht-os-perf-hw.ps1 |
| `Get-PathExtList` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:265<br>ht-srvc-exe-resolve.ps1:1233 | ht-srvc-exe-resolve.ps1 |
| `Get-PropValue` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:997<br>ht-srvc-exe-resolve.ps1:1828 | ht-srvc-exe-resolve.ps1 |
| `Get-RowValue` | 1 | 1 | 1 | ht-os-perf-hw.ps1:675 | ht-os-perf-hw.ps1 |
| `Get-ServiceDllFromReg` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:275<br>ht-srvc-exe-resolve.ps1:1310 | ht-srvc-exe-resolve.ps1 |
| `Get-ServiceExitCodeMessage` | 1 | 1 | 1 | ht-win-os-hyg.ps1:94 | ht-win-os-hyg.ps1 |
| `Get-ServiceVendors` | 3 | 1 | 1 | ht-srvc-exe-resolve.ps1:299<br>ht-srvc-exe-resolve.ps1:857<br>ht-srvc-exe-resolve.ps1:1688 | ht-srvc-exe-resolve.ps1 |
| `Get-Severity` | 1 | 1 | 1 | ht-os-perf-hw.ps1:656 | ht-os-perf-hw.ps1 |
| `Get-SoftwareLicensing` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1999 | ht-os-perf-hw.ps1 |
| `Get-WindowsOriginalInstallDate` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:901<br>ht-srvc-exe-resolve.ps1:1732 | ht-srvc-exe-resolve.ps1 |
| `HealthTest-AdminSDHolderCoverage` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1873 | ht-os-perf-hw.ps1 |
| `HealthTest-CertExpiry` | 1 | 1 | 1 | ht-os-perf-hw.ps1:561 | ht-os-perf-hw.ps1 |
| `HealthTest-DcDnsARecords` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1828 | ht-os-perf-hw.ps1 |
| `HealthTest-DfsNamespaceEnumerate` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:398 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-DfsrBacklog` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:182 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-DfsrBacklogSysvol` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:135 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-DisksHaveFreeSpace` | 2 | 1 | 1 | ht-os-perf-hw.ps1:4<br>ht-os-perf-hw.ps1:1280 | ht-os-perf-hw.ps1 |
| `HealthTest-DnsClientService` | 1 | 1 | 1 | ht-DNS-DHCP-srvc.ps1:170 | ht-DNS-DHCP-srvc.ps1 |
| `HealthTest-DnsForwarders` | 1 | 1 | 1 | ht-DNS-DHCP-srvc.ps1:84 | ht-DNS-DHCP-srvc.ps1 |
| `HealthTest-DnsRecursionConfig` | 1 | 1 | 1 | ht-DNS-DHCP-srvc.ps1:98 | ht-DNS-DHCP-srvc.ps1 |
| `HealthTest-DnsScavenging` | 1 | 1 | 1 | ht-DNS-DHCP-srvc.ps1:4 | ht-DNS-DHCP-srvc.ps1 |
| `HealthTest-DnsSuffixMatchesDomain` | 1 | 1 | 1 | ht-DNS-DHCP-srvc.ps1:152 | ht-DNS-DHCP-srvc.ps1 |
| `HealthTest-DnsZoneReplicationScope` | 1 | 1 | 1 | ht-DNS-DHCP-srvc.ps1:23 | ht-DNS-DHCP-srvc.ps1 |
| `HealthTest-ExploitProtectionBaseline` | 1 | 1 | 1 | ht-os-perf-hw.ps1:991 | ht-os-perf-hw.ps1 |
| `HealthTest-FirewallEnabled` | 1 | 1 | 1 | ht-win-os-hyg.ps1:191 | ht-win-os-hyg.ps1 |
| `HealthTest-GcPlacement` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1853 | ht-os-perf-hw.ps1 |
| `HealthTest-HyperVRunningVMs` | 1 | 1 | 1 | ht-hyperv-mgmt.ps1:40 | ht-hyperv-mgmt.ps1 |
| `HealthTest-HyperVVMProperties` | 1 | 1 | 1 | ht-hyperv-mgmt.ps1:4 | ht-hyperv-mgmt.ps1 |
| `HealthTest-IsTPMActivated` | 1 | 1 | 1 | ht-os-perf-hw.ps1:2068 | ht-os-perf-hw.ps1 |
| `HealthTest-LargeDirectories` | 1 | 1 | 1 | ht-file-dir-anlz.ps1:4 | ht-file-dir-anlz.ps1 |
| `HealthTest-LdapSigningChannelBinding` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1551 | ht-os-perf-hw.ps1 |
| `HealthTest-MalwareProtectionFeatures` | 1 | 1 | 1 | ht-syscfg-featdisc.ps1:132 | ht-syscfg-featdisc.ps1 |
| `HealthTest-NtdsPathsLocation` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1444 | ht-os-perf-hw.ps1 |
| `HealthTest-NtfsDirtyBit` | 2 | 1 | 1 | ht-os-perf-hw.ps1:831<br>ht-os-perf-hw.ps1:2343 | ht-os-perf-hw.ps1 |
| `HealthTest-PagefileSanity` | 2 | 1 | 1 | ht-os-perf-hw.ps1:1696<br>ht-os-perf-hw.ps1:2231 | ht-os-perf-hw.ps1 |
| `HealthTest-PendingReboot` | 1 | 1 | 1 | ht-os-perf-hw.ps1:472 | ht-os-perf-hw.ps1 |
| `HealthTest-RamPressure` | 2 | 1 | 1 | ht-os-perf-hw.ps1:21<br>ht-os-perf-hw.ps1:926 | ht-os-perf-hw.ps1 |
| `HealthTest-RecycleBinEnabled` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1484 | ht-os-perf-hw.ps1 |
| `HealthTest-ReplicationLatency` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1498 | ht-os-perf-hw.ps1 |
| `HealthTest-RequiredSrvRecords` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1525 | ht-os-perf-hw.ps1 |
| `HealthTest-ReverseZonesPresent` | 1 | 1 | 1 | ht-DNS-DHCP-srvc.ps1:41 | ht-DNS-DHCP-srvc.ps1 |
| `HealthTest-ScheduledTasks` | 1 | 1 | 1 | ht-schtasks-master.ps1:4 | ht-schtasks-master.ps1 |
| `HealthTest-SchemaVersionConsistency` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1395 | ht-os-perf-hw.ps1 |
| `HealthTest-ServiceAccountsPwdNeverExpires` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1662 | ht-os-perf-hw.ps1 |
| `HealthTest-ShareReasonableness` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1060 | ht-os-perf-hw.ps1 |
| `HealthTest-SingleDefaultGateway` | 1 | 1 | 1 | ht-net-conn.ps1:52 | ht-net-conn.ps1 |
| `HealthTest-SmbSigningRequired` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1580 | ht-os-perf-hw.ps1 |
| `HealthTest-SoftwareLicensing` | 1 | 1 | 1 | ht-os-perf-hw.ps1:2057 | ht-os-perf-hw.ps1 |
| `HealthTest-Storage` | 2 | 1 | 1 | ht-os-perf-hw.ps1:751<br>ht-os-perf-hw.ps1:2274 | ht-os-perf-hw.ps1 |
| `HealthTest-SysvolNetlogonAccessible` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1373 | ht-os-perf-hw.ps1 |
| `HealthTest-TimeSyncAccuracy` | 2 | 1 | 1 | ht-os-perf-hw.ps1:387<br>ht-os-perf-hw.ps1:2160 | ht-os-perf-hw.ps1 |
| `HealthTest-TombstoneLifetime` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1471 | ht-os-perf-hw.ps1 |
| `HealthTest-TrustsVerify` | 1 | 1 | 1 | ht-AD-GPO-mgmt.ps1:414 | ht-AD-GPO-mgmt.ps1 |
| `HealthTest-UnconstrainedDelegationAccounts` | 1 | 1 | 1 | ht-os-perf-hw.ps1:1609 | ht-os-perf-hw.ps1 |
| `HealthTest-UpdateAge` | 1 | 1 | 1 | ht-os-perf-hw.ps1:503 | ht-os-perf-hw.ps1 |
| `Is-Informational` | 1 | 1 | 1 | ht-os-perf-hw.ps1:668 | ht-os-perf-hw.ps1 |
| `Normalize-Code` | 1 | 1 | 1 | ht-os-perf-hw.ps1:640 | ht-os-perf-hw.ps1 |
| `Normalize-DirectoryPath` | 1 | 1 | 1 | ht-srvc-exe-resolve.ps1:1937 | ht-srvc-exe-resolve.ps1 |
| `Probe-UnquotedServicePath` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:372<br>ht-srvc-exe-resolve.ps1:1266 | ht-srvc-exe-resolve.ps1 |
| `Resolve-ExecutablePath` | 3 | 1 | 1 | ht-srvc-exe-resolve.ps1:398<br>ht-srvc-exe-resolve.ps1:692<br>ht-srvc-exe-resolve.ps1:1523 | ht-srvc-exe-resolve.ps1 |
| `Split-FirstToken` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:1082<br>ht-srvc-exe-resolve.ps1:1244 | ht-srvc-exe-resolve.ps1 |
| `Split-Rundll32DllToken` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:1166<br>ht-srvc-exe-resolve.ps1:1293 | ht-srvc-exe-resolve.ps1 |
| `Test-DiskHasFreeSpace` | 1 | 1 | 1 | ht-os-perf-hw.ps1:2419 | ht-os-perf-hw.ps1 |
| `Test-HasInvalidPathChars` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:1218<br>ht-srvc-exe-resolve.ps1:1913 | ht-srvc-exe-resolve.ps1 |
| `Test-IsRdsLicensingServer` | 1 | 1 | 1 | ht-syscfg-featdisc.ps1:351 | ht-syscfg-featdisc.ps1 |
| `Test-LooksLikePath` | 2 | 1 | 1 | ht-srvc-exe-resolve.ps1:1207<br>ht-srvc-exe-resolve.ps1:1927 | ht-srvc-exe-resolve.ps1 |
| `Test-MultipleGatewayConfiguration` | 1 | 1 | 1 | ht-net-conn.ps1:183 | ht-net-conn.ps1 |
| `To-UInt32` | 1 | 1 | 1 | ht-os-perf-hw.ps1:649 | ht-os-perf-hw.ps1 |
| `Visit-DirectoryForLargeCount` | 1 | 1 | 1 | ht-file-dir-anlz.ps1:51 | ht-file-dir-anlz.ps1 |

