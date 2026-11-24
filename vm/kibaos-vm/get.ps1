# Get kibaos-vm on Windows and start it.
#
#   irm https://raw.githubusercontent.com/KibaLabsLLC/KibaDE/main/vm/kibaos-vm/get.ps1 | iex
#
# It downloads the kibaos-vm program for this PC, checks it against the
# SHA-256 written into this script for that version, and runs it. A file
# PowerShell downloads is not marked as coming from the internet the way a
# browser download is, so Windows does not stop to ask about it; the check
# against the hash below is what makes that safe. A file that does not match
# is deleted and never run.
#
# Settings, all optional, as environment variables:
#   KIBAOS_VM_ARGS      options for kibaos-vm, for example "--release v1.1.2"
#   KIBAOS_VM_BIN_DIR   where the program is kept (default %LOCALAPPDATA%\KibaOS\bin)
#   KIBAOS_VM_BASE_URL  where to download from (for testing a build)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# >>> pins (written by build.sh; do not edit by hand)
$Version = '1.0.0'
$Pins = @{
  'windows-amd64' = 'd06b7fa01b63078e3dcaedf4fbcbf254e4a30f69f9d26d5c09d1e1fa5c0a8b8b'
  'windows-arm64' = 'bfac517c70a09cb226fd74dbbbae65827da3e58afd4b65342b647027801d6c37'
}
# <<< pins

function Say($text) { Write-Host "kibaos-vm: $text" }
function Fail($text) { Write-Host "kibaos-vm: $text" -ForegroundColor Red; throw "kibaos-vm: $text" }

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

$arch = switch ($env:PROCESSOR_ARCHITECTURE) {
  'AMD64' { 'amd64' }
  'ARM64' { 'arm64' }
  default { Fail "this PC is $($env:PROCESSOR_ARCHITECTURE); kibaos-vm runs on 64-bit Windows" }
}
$target = "windows-$arch"
$want = $Pins[$target]
if (-not $want) { Fail "no kibaos-vm build is published for $target yet" }

$binDir = if ($env:KIBAOS_VM_BIN_DIR) { $env:KIBAOS_VM_BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'KibaOS\bin' }
$exe = Join-Path $binDir 'kibaos-vm.exe'
$name = "kibaos-vm-$Version-$target.exe"
$base = if ($env:KIBAOS_VM_BASE_URL) { $env:KIBAOS_VM_BASE_URL.TrimEnd('/') } else { "https://github.com/KibaLabsLLC/KibaDE/releases/download/kibaos-vm-v$Version" }

function HashOf($path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant() }

if ((Test-Path -LiteralPath $exe) -and ((HashOf $exe) -eq $want)) {
  Say "kibaos-vm $Version is already here"
} else {
  New-Item -ItemType Directory -Force -Path $binDir | Out-Null
  Remove-Item -Force -ErrorAction SilentlyContinue -LiteralPath $exe
  $part = "$exe.part"
  Say "downloading kibaos-vm $Version"
  Invoke-WebRequest -UseBasicParsing -Uri "$base/$name" -OutFile $part
  $got = HashOf $part
  if ($got -ne $want) {
    Remove-Item -Force -LiteralPath $part
    Fail "the download does not match the SHA-256 this script expects, so it was deleted. Expected $want, got $got."
  }
  Move-Item -Force -LiteralPath $part -Destination $exe
  Say "checked: SHA-256 $want"
}

$argv = @()
if ($env:KIBAOS_VM_ARGS) { $argv = @($env:KIBAOS_VM_ARGS -split '\s+' | Where-Object { $_ }) }
# An array after a native command is passed as separate arguments.
& $exe $argv
