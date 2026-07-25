# HostRequirement: DC

function HealthTest-DfsDiagTestDCs {
<#
Description: Runs DFSDIAG /TestDCs and reports unexpected DFS diagnostics output.
AppliesTo: DC
Scope: Computer
Category: Configuration Hygiene & Best Practices
Impact: High(Time)
Uses: dfsdiag.exe.
#>

    write-progress "Runing 'DFSDIAG /TestDCs'"
    $out=(DFSDIAG /TestDCs | sls -NotMatch '^$|^(Information|[A-Za-z]+ing|Success)[ :]|^Finished TestDcs[.] *$')
    if ($out) {
        Write-Warning "[FAILURE] 'DFSDIAG /TestDCs' output does not seem clean`nIf the following lines I was not expecting indicate problems, run DFSDIAG /TestDCs to view the whole output:`n$out"
        return
    }
    Write-Warning "[PASS] 'DFSDIAG /TestDCs' returned expected output"
}

if ($MyInvocation.InvocationName -ne '.') {
  HealthTest-DfsDiagTestDCs
}
