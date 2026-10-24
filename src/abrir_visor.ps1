<#
.SYNOPSIS
  Abre el visor web paso a paso de una sesion de fotogrametria.
.EXAMPLE
  .\src\abrir_visor.ps1 -Sesion sceaux
#>
param(
  [Parameter(Mandatory = $true)] [string]$Sesion,
  [int]$Puerto = 8765,
  # Regenera manifest y miniaturas aunque ya existan.
  [switch]$Regenerar
)
$ErrorActionPreference = "Stop"
$RepoRoot = Split-Path -Parent $PSScriptRoot
$Python = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$Manifest = Join-Path $RepoRoot "outputs\$Sesion\visor\manifest.json"

if ($Regenerar -or -not (Test-Path $Manifest)) {
  & $Python (Join-Path $RepoRoot "src\preparar_visor.py") $Sesion
  if ($LASTEXITCODE -ne 0) { throw "No se pudo preparar el visor." }
}

# Servidor local (solo escucha en localhost). Reutiliza uno existente solo si sirve este repo;
# si el puerto lo ocupa otro programa, busca el siguiente libre.
function Test-SirveRepo($p) {
  try { return (Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$p/outputs/$Sesion/visor/manifest.json").StatusCode -eq 200 } catch { return $false }
}
$Elegido = $null
for ($p = $Puerto; $p -lt ($Puerto + 20); $p++) {
  $enUso = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue
  if (-not $enUso) {
    Start-Process -FilePath $Python -ArgumentList "-m", "http.server", "$p", "--bind", "127.0.0.1", "--directory", "`"$RepoRoot`"" -WindowStyle Hidden
    Start-Sleep -Seconds 1
    $Elegido = $p; break
  } elseif (Test-SirveRepo $p) { $Elegido = $p; break }
}
if (-not $Elegido) { throw "No se encontro un puerto libre entre $Puerto y $($Puerto + 19)." }
$Puerto = $Elegido

$Url = "http://127.0.0.1:$Puerto/src/visor/index.html?sesion=$Sesion"
Write-Host "Visor: $Url"
Start-Process $Url
