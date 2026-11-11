[CmdletBinding()]
param(
    [switch]$Approved,
    [switch]$Plan,
    [string]$ExpectedUserSid
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$sid = $identity.User.Value
if ($ExpectedUserSid -and $ExpectedUserSid -ne $sid) { throw 'Use the existing Argus desktop account.' }
$elevated = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$app = Join-Path $env:ProgramFiles 'Argus\argus.exe'
$serviceDirectory = Join-Path $env:ProgramFiles 'Argus Privileged'
$registryPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\taskmgr.exe'
$expectedDebugger = '"' + (Join-Path $serviceDirectory 'argus-taskmgr-launcher.exe') + '" --task-manager'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Argus-RU'
$statusPath = Join-Path $stateDirectory 'taskmgr-status.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Set-TaskManagerStatus([string]$stage, [string]$message) {
    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    [IO.File]::WriteAllText($statusPath, (@{stage=$stage; message=$message; timeUtc=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json), $utf8)
}
if (-not (Test-Path -LiteralPath $app)) { throw 'Installed Argus was not found.' }
$currentDebugger = if (Test-Path -LiteralPath $registryPath) { (Get-Item -LiteralPath $registryPath).GetValue('Debugger') } else { $null }
if ($null -ne $currentDebugger -and $currentDebugger -ne $expectedDebugger) { throw 'Another Task Manager replacement is configured. It will not be overwritten.' }
if ($Plan) {
    [pscustomobject]@{ application=$app; installRequiredService=($null -eq (Get-Service -Name ArgusPrivileged -ErrorAction SilentlyContinue)); debugger=$expectedDebugger; nativeHelper='--argus-taskmgr-manage'; driverRequired=$false; needsWindowsApproval=(-not $elevated) } | ConvertTo-Json
    return
}
if (-not $elevated) {
    if ($Approved) { throw 'Windows administrator approval was not granted.' }
    Set-TaskManagerStatus 'awaiting-windows-approval' 'Waiting for Windows approval to enable the native Argus replacement.'
    $quotedScript = '"' + $PSCommandPath + '"'
    $helper = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$quotedScript,'-Approved','-ExpectedUserSid',$sid) -PassThru
    $helper.WaitForExit()
    if ($helper.ExitCode -ne 0) { throw "Native Argus replacement setup failed: $($helper.ExitCode). See $statusPath" }
    Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8
    return
}

function Invoke-ArgusMaintenance([string[]]$Arguments) {
    $process = Start-Process -FilePath $app -ArgumentList $Arguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Argus maintenance failed: $($Arguments[0]); exit $($process.ExitCode)" }
}
$createdService = $false
$enabledHere = $false
try {
    $backup = Join-Path $stateDirectory ('backups\task-manager-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    @{keyExisted=(Test-Path -LiteralPath $registryPath); debugger=$currentDebugger; owner=$sid} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'before.json') -Encoding UTF8
    Set-TaskManagerStatus 'installing-service' 'Installing the fixed native service required by Argus.'
    $service = Get-Service -Name ArgusPrivileged -ErrorAction SilentlyContinue
    if (-not $service) {
        Invoke-ArgusMaintenance @('--argus-service-manage','install',$sid)
        $createdService = $true
    } elseif ($service.Status -ne 'Running') {
        Invoke-ArgusMaintenance @('--argus-service-manage','start',$sid)
    }
    if ((Get-Service -Name ArgusPrivileged).Status -ne 'Running') { throw 'The required Argus service did not start.' }
    if ((Get-Content -LiteralPath (Join-Path $serviceDirectory 'owner.sid') -Raw).Trim() -ne $sid) { throw 'The Argus service belongs to another account.' }

    $session = (Get-Process -Id $PID).SessionId
    $runtimePrefix = Join-Path $env:ProgramFiles "Argus Runtime\dev.argus.taskmanager\$sid\"
    $callerInfo = Get-CimInstance Win32_Process -Filter "Name LIKE 'argus%'" | Where-Object {
        $_.SessionId -eq $session -and $_.ExecutablePath -and
        ($_.ExecutablePath.Equals($app,[StringComparison]::OrdinalIgnoreCase) -or $_.ExecutablePath.StartsWith($runtimePrefix,[StringComparison]::OrdinalIgnoreCase))
    } | Select-Object -First 1
    if (-not $callerInfo) { throw 'Open the installed Argus before enabling its Task Manager replacement.' }
    $caller = Get-Process -Id $callerInfo.ProcessId
    $created = $caller.StartTime.ToFileTimeUtc().ToString([Globalization.CultureInfo]::InvariantCulture)
    Set-TaskManagerStatus 'enabling' 'Running native Argus launcher and interface self-checks, then enabling the replacement.'
    if ($currentDebugger -ne $expectedDebugger) {
        Invoke-ArgusMaintenance @('--argus-taskmgr-manage','enable',$sid,[string]$caller.Id,$created)
        $enabledHere = $true
    }
    $actual = (Get-Item -LiteralPath $registryPath).GetValue('Debugger')
    if ($actual -ne $expectedDebugger) { throw 'The native Task Manager redirect was not enabled.' }
    $journal = Get-Content -LiteralPath (Join-Path $serviceDirectory 'taskmgr-recovery.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($journal.phase -ne 'active') { throw 'The native Argus recovery record is not active.' }
    foreach ($name in @('argus-taskmgr-launcher.exe','argus-taskmgr-recover.exe','taskmgr-recovery.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $serviceDirectory $name))) { throw "Native replacement file missing: $name" }
    }
    Set-TaskManagerStatus 'verifying' 'Opening the Windows Task Manager entry to verify the redirect.'
    $beforeNative = @(Get-CimInstance Win32_Process -Filter "Name = 'Taskmgr.exe'" | Where-Object SessionId -eq $session | Select-Object -ExpandProperty ProcessId)
    $entry = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\taskmgr.exe') -PassThru
    if (-not $entry.WaitForExit(20000)) { throw 'The Task Manager launcher did not finish its interface handshake.' }
    if ($entry.ExitCode -ne 0) { throw "Task Manager entry failed: $($entry.ExitCode)" }
    $newNative = @(Get-CimInstance Win32_Process -Filter "Name = 'Taskmgr.exe'" | Where-Object { $_.SessionId -eq $session -and $_.ProcessId -notin $beforeNative })
    if ($newNative.Count -gt 0) { throw 'The entry fell back to Windows Task Manager.' }
    Set-TaskManagerStatus 'complete' 'Argus is the Task Manager replacement; service running; native entry verified; built-in recovery available.'
    Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8
} catch {
    $failure = $_.Exception.Message
    $nativeError = Join-Path $serviceDirectory 'taskmgr-error.json'
    if (Test-Path -LiteralPath $nativeError) { Copy-Item -LiteralPath $nativeError -Destination (Join-Path $stateDirectory 'taskmgr-error.json') -Force }
    if ($enabledHere) { try { Invoke-ArgusMaintenance @('--argus-taskmgr-manage','restore',$sid) } catch {} }
    if ($createdService -and -not $enabledHere) { try { Invoke-ArgusMaintenance @('--argus-service-manage','uninstall',$sid) } catch {} }
    Set-TaskManagerStatus 'failed' $failure
    throw
}
