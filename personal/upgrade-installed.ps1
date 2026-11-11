[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceDirectory,
    [Parameter(Mandatory=$true)][string]$ExpectedUserSid,
    [switch]$Plan
)

$ErrorActionPreference = 'Stop'
$expectedHash = 'C3A663100EDC7B7823D6A9CC808BF559987586490CA386FF6777879A2DBFE968'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if ($identity.User.Value -ne $ExpectedUserSid) { throw 'The upgrade must run as the existing desktop account.' }
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
$elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$source = Join-Path $SourceDirectory 'Argus-RU.exe'
if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $expectedHash) { throw 'The CI application hash does not match the pinned build.' }
$installDirectory = Join-Path $env:ProgramFiles 'Argus'
$installed = Join-Path $installDirectory 'argus.exe'
if (-not (Test-Path -LiteralPath $installed)) { throw 'The existing Argus installation was not found.' }
$settingsDirectory = Join-Path $env:APPDATA 'dev.argus.taskmanager'
$stateDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Argus-RU'
$statusPath = Join-Path $stateDirectory 'upgrade-status.json'
if ($Plan) {
    [pscustomobject]@{ source=$source; target=$installed; sha256=$expectedHash; settings=$settingsDirectory; language='ru-RU'; preserveOtherSettings=$true; officialUpdater=$true; needsWindowsApproval=(-not $elevated) } | ConvertTo-Json
    return
}
if (-not $elevated) { throw 'Windows administrator approval is required for the existing installation.' }
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$backup = Join-Path $stateDirectory ('backups\installed-upgrade-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup | Out-Null
$utf8 = New-Object System.Text.UTF8Encoding($false)
function Set-UpgradeStatus([string]$stage, [string]$message) {
    $state = [pscustomobject]@{ stage=$stage; message=$message; timeUtc=[DateTimeOffset]::UtcNow.ToString('o'); backup=$backup; installed=$installed }
    [IO.File]::WriteAllText($statusPath, ($state | ConvertTo-Json -Depth 5), $utf8)
}
try {
    Set-UpgradeStatus 'backing-up' 'Saving the current application, settings and history.'
    Copy-Item -LiteralPath $installed -Destination (Join-Path $backup 'argus-0.4.0-original.exe')
    foreach ($name in @('settings.json','preferences.json')) {
        $path = Join-Path $settingsDirectory $name
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $backup }
    }
    $history = Join-Path $env:LOCALAPPDATA 'dev.argus.taskmanager\history'
    if (Test-Path -LiteralPath $history) { Copy-Item -LiteralPath $history -Destination $backup -Recurse }
    Get-ScheduledTask -TaskName 'Argus.dev.argus.taskmanager.*' -ErrorAction SilentlyContinue | ForEach-Object {
        $_ | Export-ScheduledTask | Set-Content -LiteralPath (Join-Path $backup 'administrator-task.xml') -Encoding UTF8
    }

    Set-UpgradeStatus 'installing' 'Closing only verified Argus application instances.'
    $runtimePrefix = (Join-Path $env:ProgramFiles 'Argus Runtime\dev.argus.taskmanager\')
    foreach ($process in (Get-CimInstance Win32_Process -Filter "Name LIKE 'argus%'")) {
        $path = [string]$process.ExecutablePath
        if ($path -and ($path.Equals($installed, [StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($runtimePrefix, [StringComparison]::OrdinalIgnoreCase))) {
            Stop-Process -Id $process.ProcessId -Force
        }
    }
    Copy-Item -LiteralPath $source -Destination $installed -Force
    if ((Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ne $expectedHash) { throw 'Installed application hash mismatch.' }

    $settingsPath = Join-Path $settingsDirectory 'settings.json'
    $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $settings | Add-Member -NotePropertyName language -NotePropertyValue 'ru-RU' -Force
    $settings | Add-Member -NotePropertyName updateCheck -NotePropertyValue $true -Force
    [IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 50), $utf8)

    # Refresh existing grants with Argus's own maintenance command. This does
    # not enable a service, a kernel driver or Task Manager replacement.
    Set-UpgradeStatus 'refreshing-administrator-startup' 'Refreshing the already authorized Argus administrator copy.'
    $refresh = Start-Process -FilePath $installed -ArgumentList '--argus-admin-refresh' -WindowStyle Hidden -Wait -PassThru
    if ($refresh.ExitCode -ne 0) { throw "Argus administrator-copy refresh failed: $($refresh.ExitCode)" }
    $updateKind = Start-Process -FilePath $installed -ArgumentList '--argus-updater-check' -WindowStyle Hidden -Wait -PassThru
    if ($updateKind.ExitCode -ne 0) { throw 'The installed application did not recognize native updater support.' }

    $shell = New-Object -ComObject WScript.Shell
    $shortcutName = 'Argus (' + ([string]::Concat([char[]](0x420,0x443,0x441,0x441,0x43A,0x438,0x439))) + ').lnk'
    foreach ($directory in @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))) {
        $shortcut = $shell.CreateShortcut((Join-Path $directory $shortcutName))
        $shortcut.TargetPath = $installed
        $shortcut.WorkingDirectory = $installDirectory
        $shortcut.IconLocation = "$installed,0"
        $shortcut.Save()
    }
    Set-UpgradeStatus 'complete' 'Russian Argus installed; original preferences and native updates retained.'
    Start-Process -FilePath $installed
} catch {
    Set-UpgradeStatus 'failed' $_.Exception.Message
    throw
}
