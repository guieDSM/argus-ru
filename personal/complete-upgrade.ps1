[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'Argus-RU.exe')) { $PSScriptRoot } else { Join-Path $root 'target\delivery-ru-2\unpacked' }
$helper = Join-Path $PSScriptRoot 'upgrade-installed.ps1'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$stateDirectory = Join-Path $env:LOCALAPPDATA 'Programs\Argus-RU'
New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
$statusPath = Join-Path $stateDirectory 'upgrade-status.json'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($statusPath, (@{stage='awaiting-windows-approval'; timeUtc=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json), $utf8)
$quotedHelper = '"' + $helper + '"'
$quotedSource = '"' + $source + '"'
try {
    $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -Verb RunAs -WindowStyle Hidden -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$quotedHelper,'-SourceDirectory',$quotedSource,'-ExpectedUserSid',$sid) -PassThru
    $process.WaitForExit()
    if ($process.ExitCode -ne 0) { throw "The approved upgrade exited with code $($process.ExitCode). See $statusPath" }
    Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8
} catch {
    if ((Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json).stage -eq 'awaiting-windows-approval') {
        [IO.File]::WriteAllText($statusPath, (@{stage='windows-approval-not-granted'; error=$_.Exception.Message; timeUtc=[DateTimeOffset]::UtcNow.ToString('o')} | ConvertTo-Json), $utf8)
    }
    throw
}
