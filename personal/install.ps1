[CmdletBinding()]
param(
    [string]$SourceDirectory = $PSScriptRoot,
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\Argus-RU')
)

$ErrorActionPreference = 'Stop'
$sourceExecutable = Join-Path $SourceDirectory 'Argus-RU.exe'
$checksumFile = Join-Path $SourceDirectory 'SHA256SUMS.txt'
if (-not (Test-Path -LiteralPath $sourceExecutable)) { throw 'Argus-RU.exe is missing.' }
if (-not (Test-Path -LiteralPath $checksumFile)) { throw 'SHA256SUMS.txt is missing.' }
$expectedHash = ((Get-Content -LiteralPath $checksumFile -Raw).Trim() -split '\s+')[0]
$actualHash = (Get-FileHash -LiteralPath $sourceExecutable -Algorithm SHA256).Hash
if ($expectedHash -notmatch '^[0-9a-fA-F]{64}$' -or $actualHash -ne $expectedHash) {
    throw 'The application checksum does not match SHA256SUMS.txt.'
}

# Never overwrite settings while an Argus process can save its old copy.
$running = @(Get-Process -Name argus,Argus-RU -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) { throw 'Close Argus before installing this build.' }

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$settingsDirectory = Join-Path $env:APPDATA 'dev.argus.taskmanager'
$backupDirectory = Join-Path $InstallDirectory "backups\$timestamp"
New-Item -ItemType Directory -Path $InstallDirectory,$settingsDirectory,$backupDirectory -Force | Out-Null
foreach ($name in @('settings.json','preferences.json')) {
    $existing = Join-Path $settingsDirectory $name
    if (Test-Path -LiteralPath $existing) { Copy-Item -LiteralPath $existing -Destination $backupDirectory }
}
$destinationExecutable = Join-Path $InstallDirectory 'argus.exe'
if (Test-Path -LiteralPath $destinationExecutable) {
    Copy-Item -LiteralPath $destinationExecutable -Destination (Join-Path $backupDirectory 'argus.exe')
}
Copy-Item -LiteralPath $sourceExecutable -Destination $destinationExecutable -Force
foreach ($name in @('build-info.json','LICENSE','README.ru.md','SHA256SUMS.txt')) {
    $source = Join-Path $SourceDirectory $name
    if (Test-Path -LiteralPath $source) { Copy-Item -LiteralPath $source -Destination $InstallDirectory -Force }
}

$settingsPath = Join-Path $settingsDirectory 'settings.json'
$settings = if (Test-Path -LiteralPath $settingsPath) {
    Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
} else { [pscustomobject]@{} }
$settings | Add-Member -NotePropertyName language -NotePropertyValue 'ru-RU' -Force
$settings | Add-Member -NotePropertyName updateCheck -NotePropertyValue $false -Force
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Depth 50), $utf8)

$shell = New-Object -ComObject WScript.Shell
# Use Unicode code points so Windows PowerShell 5.1 can also read this UTF-8 file.
$shortcutName = 'Argus (' + ([string]::Concat([char[]](0x420,0x443,0x441,0x441,0x43A,0x438,0x439))) + ').lnk'
$shortcutDirectories = @(
    [Environment]::GetFolderPath('Desktop'),
    (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs')
)
foreach ($directory in $shortcutDirectories) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $shortcut = $shell.CreateShortcut((Join-Path $directory $shortcutName))
    $shortcut.TargetPath = $destinationExecutable
    $shortcut.WorkingDirectory = $InstallDirectory
    $shortcut.IconLocation = "$destinationExecutable,0"
    $shortcut.Description = 'Argus - Russian interface'
    $shortcut.Save()
}
Write-Output "Installed: $destinationExecutable"
Write-Output 'Language: ru-RU'
Write-Output "Backup: $backupDirectory"
