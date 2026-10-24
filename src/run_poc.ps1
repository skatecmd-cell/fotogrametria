<#
.SYNOPSIS
  Pipeline POC de fotogrametria: fotos -> COLMAP (SfM) -> OpenMVS (MVS) -> malla con textura.

.DESCRIPTION
  Ejecuta de forma reproducible:
    1. COLMAP feature_extractor   (SIFT en GPU)
    2. COLMAP exhaustive_matcher  (GPU)
    3. COLMAP mapper              (poses + nube dispersa)
    4. COLMAP image_undistorter   (imagenes rectificadas para MVS)
    5. OpenMVS InterfaceCOLMAP    (conversion a .mvs)
    6. OpenMVS DensifyPointCloud  (nube densa)
    7. OpenMVS ReconstructMesh    (malla)
    8. OpenMVS RefineMesh         (refinado, opcional)
    9. OpenMVS TextureMesh        (textura, exporta .obj)
  Guarda intermedios en data/processed/<Nombre>, resultados en outputs/<Nombre>
  y escribe outputs/<Nombre>/reporte.md con versiones, parametros, tiempos y metricas.

.EXAMPLE
  .\src\run_poc.ps1 -ImagePath .\data\raw\sesion_01
  .\src\run_poc.ps1 -ImagePath .\data\raw\sesion_01 -Calidad rapida -SinRefinado
  .\src\run_poc.ps1 -ImagePath .\data\raw\sesion_01 -Limpiar -RegistrarExperimento
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, HelpMessage = "Carpeta con las fotografias (jpg/png)")]
  [string]$ImagePath,

  # Nombre de la sesion. Por defecto, el nombre de la carpeta de fotos.
  [string]$Nombre,

  # rapida: prueba de humo. media: POC. alta: maxima resolucion (lento).
  [ValidateSet("rapida", "media", "alta")]
  [string]$Calidad = "media",

  # Omite RefineMesh (la etapa mas lenta).
  [switch]$SinRefinado,

  # Borra data/processed/<Nombre> antes de empezar.
  [switch]$Limpiar,

  # Agrega una entrada al final de docs/experimentos.md.
  [switch]$RegistrarExperimento,

  [string]$ColmapExe = "C:\Riesgo\tools\colmap\bin\colmap.exe",
  [string]$OpenMvsDir = "C:\Riesgo\tools\openmvs"
)

Set-StrictMode -Version 2
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Rutas
# ---------------------------------------------------------------------------
$RepoRoot = Split-Path -Parent $PSScriptRoot
$ImagePath = (Resolve-Path $ImagePath).Path
if (-not $Nombre) { $Nombre = Split-Path -Leaf $ImagePath }

$Work   = Join-Path $RepoRoot "data\processed\$Nombre"
$Out    = Join-Path $RepoRoot "outputs\$Nombre"
$Logs   = Join-Path $Work "logs"
$Db     = Join-Path $Work "database.db"
$Sparse = Join-Path $Work "sparse"
$Dense  = Join-Path $Work "dense"

foreach ($exe in @($ColmapExe, (Join-Path $OpenMvsDir "InterfaceCOLMAP.exe"))) {
  if (-not (Test-Path $exe)) { throw "No se encuentra el ejecutable: $exe" }
}

$Imagenes = @(Get-ChildItem $ImagePath -File | Where-Object { $_.Extension -match '^\.(jpe?g|png|tiff?)$' })
if ($Imagenes.Count -lt 3) { throw "Se necesitan al menos 3 imagenes en $ImagePath (hay $($Imagenes.Count))." }

# ---------------------------------------------------------------------------
# Presets de calidad
# ---------------------------------------------------------------------------
switch ($Calidad) {
  "rapida" { $MaxImg = 1600; $DenseLevel = 2; $DenseMaxRes = 1600; $RefineLevel = 2; $TexLevel = 1 }
  "media"  { $MaxImg = 3200; $DenseLevel = 1; $DenseMaxRes = 2560; $RefineLevel = 1; $TexLevel = 0 }
  "alta"   { $MaxImg = -1;   $DenseLevel = 0; $DenseMaxRes = 4096; $RefineLevel = 0; $TexLevel = 0 }
}

if ($Limpiar -and (Test-Path $Work)) { Remove-Item $Work -Recurse -Force }
foreach ($d in @($Work, $Logs, $Sparse, $Out)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------
$Tiempos = New-Object System.Collections.ArrayList
$Inicio = Get-Date

function Invoke-Paso {
  param([string]$Paso, [string]$Exe, [string[]]$Argumentos, [string]$Cwd)
  Write-Host ""
  Write-Host ("=" * 78) -ForegroundColor Cyan
  Write-Host "[$Paso]" -ForegroundColor Cyan
  Write-Host ("  " + (Split-Path -Leaf $Exe) + " " + ($Argumentos -join " ")) -ForegroundColor DarkGray
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  if ($Cwd) { Push-Location $Cwd }
  # COLMAP escribe su log por stderr; PowerShell 5.1 lo convertiria en error con "Stop".
  $eapPrevio = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    & $Exe @Argumentos
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $eapPrevio
    if ($Cwd) { Pop-Location }
  }
  $sw.Stop()
  [void]$Tiempos.Add([pscustomobject]@{ Paso = $Paso; Segundos = [math]::Round($sw.Elapsed.TotalSeconds, 1); Codigo = $code })
  if ($code -ne 0) { throw "El paso '$Paso' fallo con codigo $code. Revisa los logs en $Logs" }
  Write-Host ("  OK en {0:N1} s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
}

function Get-ColmapStats {
  param([string]$ModelPath)
  $txt = & $ColmapExe model_analyzer --path $ModelPath --log_target stdout | Out-String
  $stats = [ordered]@{}
  foreach ($linea in ($txt -split "`r?`n")) {
    if ($linea -match '(Cameras|Images|Registered images|Points|Observations|Mean track length|Mean observations per image|Mean reprojection error):\s*([\d\.]+)') {
      $stats[$matches[1]] = [double]$matches[2]
    }
  }
  return $stats
}

$ColmapArgsComunes = @("--log_target", "stderr_and_file", "--log_path", $Logs)

# ---------------------------------------------------------------------------
# 1-3. COLMAP: SfM
# ---------------------------------------------------------------------------
Write-Host "Sesion: $Nombre | Imagenes: $($Imagenes.Count) | Calidad: $Calidad" -ForegroundColor Yellow

Invoke-Paso "1. COLMAP feature_extractor" $ColmapExe (@(
  "feature_extractor",
  "--database_path", $Db,
  "--image_path", $ImagePath,
  "--ImageReader.single_camera", "1",
  "--ImageReader.camera_model", "OPENCV",
  "--FeatureExtraction.use_gpu", "1",
  "--FeatureExtraction.max_image_size", "$MaxImg",
  "--SiftExtraction.max_num_features", "8192"
) + $ColmapArgsComunes)

Invoke-Paso "2. COLMAP exhaustive_matcher" $ColmapExe (@(
  "exhaustive_matcher",
  "--database_path", $Db,
  "--FeatureMatching.use_gpu", "1",
  "--FeatureMatching.guided_matching", "1"
) + $ColmapArgsComunes)

Invoke-Paso "3. COLMAP mapper" $ColmapExe (@(
  "mapper",
  "--database_path", $Db,
  "--image_path", $ImagePath,
  "--output_path", $Sparse
) + $ColmapArgsComunes)

# Elegir el modelo con mas imagenes registradas (COLMAP puede producir varios).
$Modelos = @(Get-ChildItem $Sparse -Directory)
if ($Modelos.Count -eq 0) { throw "COLMAP no produjo ningun modelo. Las fotos no tienen suficiente solapamiento o textura." }
$Mejor = $null; $MejorStats = $null; $MejorReg = -1
foreach ($m in $Modelos) {
  $s = Get-ColmapStats $m.FullName
  $reg = 0; if ($s.Contains("Registered images")) { $reg = $s["Registered images"] }
  Write-Host ("  modelo {0}: {1} imagenes registradas" -f $m.Name, $reg)
  if ($reg -gt $MejorReg) { $Mejor = $m.FullName; $MejorStats = $s; $MejorReg = $reg }
}
$Registradas = $MejorReg
$PctReg = [math]::Round(100.0 * $Registradas / $Imagenes.Count, 1)
Write-Host ("Modelo elegido: {0} ({1}/{2} imagenes, {3}%)" -f (Split-Path -Leaf $Mejor), $Registradas, $Imagenes.Count, $PctReg) -ForegroundColor Yellow
if ($Modelos.Count -gt 1) { Write-Warning "COLMAP genero $($Modelos.Count) modelos separados. Faltan fotos de enlace entre zonas." }

& $ColmapExe model_converter --input_path $Mejor --output_path (Join-Path $Out "nube_dispersa.ply") --output_type PLY --log_target file --log_path $Logs

# ---------------------------------------------------------------------------
# 4. COLMAP: imagenes sin distorsion
# ---------------------------------------------------------------------------
if (Test-Path $Dense) { Remove-Item $Dense -Recurse -Force }
Invoke-Paso "4. COLMAP image_undistorter" $ColmapExe (@(
  "image_undistorter",
  "--image_path", $ImagePath,
  "--input_path", $Mejor,
  "--output_path", $Dense,
  "--output_type", "COLMAP",
  "--max_image_size", "$MaxImg"
) + $ColmapArgsComunes)

# ---------------------------------------------------------------------------
# 5-9. OpenMVS
# ---------------------------------------------------------------------------
$MvsArgs = @("-w", $Dense, "--process-priority", "0", "-v", "2")

Invoke-Paso "5. OpenMVS InterfaceCOLMAP" (Join-Path $OpenMvsDir "InterfaceCOLMAP.exe") (@(
  "-i", $Dense, "-o", "scene.mvs", "--image-folder", "images"
) + $MvsArgs) $Dense

Invoke-Paso "6. OpenMVS DensifyPointCloud" (Join-Path $OpenMvsDir "DensifyPointCloud.exe") (@(
  "scene.mvs", "-o", "scene_dense.mvs",
  "--resolution-level", "$DenseLevel", "--max-resolution", "$DenseMaxRes",
  "--number-views-fuse", "3", "--remove-dmaps", "1"
) + $MvsArgs) $Dense

Invoke-Paso "7. OpenMVS ReconstructMesh" (Join-Path $OpenMvsDir "ReconstructMesh.exe") (@(
  "scene_dense.mvs", "-o", "scene_mesh.mvs"
) + $MvsArgs) $Dense

$MallaParaTextura = "scene_mesh.ply"
if (-not $SinRefinado) {
  Invoke-Paso "8. OpenMVS RefineMesh" (Join-Path $OpenMvsDir "RefineMesh.exe") (@(
    "scene_dense.mvs", "-m", "scene_mesh.ply", "-o", "scene_mesh_refinada.mvs",
    "--resolution-level", "$RefineLevel", "--max-face-area", "16"
  ) + $MvsArgs) $Dense
  $MallaParaTextura = "scene_mesh_refinada.ply"
} else {
  [void]$Tiempos.Add([pscustomobject]@{ Paso = "8. OpenMVS RefineMesh"; Segundos = 0; Codigo = "omitido" })
}

# La nivelacion de costuras (global y local) del build Windows 2.4.0 de OpenMVS deja manchas
# negras en el atlas de textura (verificado 24-oct-2026 con el dataset Sceaux). Se desactiva.
Invoke-Paso "9. OpenMVS TextureMesh" (Join-Path $OpenMvsDir "TextureMesh.exe") (@(
  "scene_dense.mvs", "-m", $MallaParaTextura, "-o", "modelo_texturizado.mvs",
  "--resolution-level", "$TexLevel", "--export-type", "obj",
  "--global-seam-leveling", "0", "--local-seam-leveling", "0"
) + $MvsArgs) $Dense

# ---------------------------------------------------------------------------
# Resultados
# ---------------------------------------------------------------------------
$Copiar = @("scene_dense.ply", "scene_mesh.ply", "scene_mesh_refinada.ply", "modelo_texturizado.obj", "modelo_texturizado.mtl")
foreach ($f in $Copiar) { $p = Join-Path $Dense $f; if (Test-Path $p) { Copy-Item $p $Out -Force } }
Get-ChildItem $Dense -File -Filter "modelo_texturizado*" | Where-Object { $_.Extension -match '^\.(jpe?g|png)$' } | Copy-Item -Destination $Out -Force
Get-ChildItem $Dense -File -Filter "*.log" | Move-Item -Destination $Logs -Force

$Total = [math]::Round(((Get-Date) - $Inicio).TotalMinutes, 1)
$ColmapVer = (& $ColmapExe help | Select-Object -First 1 | Out-String).Trim()
$Nvidia = ""; try { $Nvidia = (nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | Out-String).Trim() } catch {}
$ErrRep = -1; if ($MejorStats.Contains("Mean reprojection error")) { $ErrRep = $MejorStats["Mean reprojection error"] }

$Reporte = @()
$Reporte += "# Reporte POC: $Nombre"
$Reporte += ""
$Reporte += "- Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$Reporte += "- Fotos de entrada: $($Imagenes.Count) en ``$ImagePath``"
$Reporte += "- Calidad: $Calidad (max_image_size=$MaxImg, dense level=$DenseLevel, refinado=$(-not $SinRefinado))"
$Reporte += "- COLMAP: $ColmapVer"
$Reporte += "- OpenMVS: v2.4.0 (CPU) en ``$OpenMvsDir``"
$Reporte += "- GPU: $Nvidia"
$Reporte += "- Tiempo total: $Total min"
$Reporte += ""
$Reporte += "## Metricas de SfM (COLMAP)"
$Reporte += ""
$Reporte += "| Metrica | Valor |"
$Reporte += "|---|---|"
$Reporte += "| Imagenes registradas | $Registradas / $($Imagenes.Count) ($PctReg %) |"
foreach ($k in $MejorStats.Keys) { if ($k -ne "Registered images" -and $k -ne "Images") { $Reporte += "| $k | $($MejorStats[$k]) |" } }
$Reporte += "| Modelos separados | $($Modelos.Count) |"
$Reporte += ""
$Reporte += "## Tiempos por etapa"
$Reporte += ""
$Reporte += "| Etapa | Segundos |"
$Reporte += "|---|---|"
foreach ($t in $Tiempos) { $Reporte += "| $($t.Paso) | $($t.Segundos) |" }
$Reporte += ""
$Reporte += "## Archivos generados"
$Reporte += ""
foreach ($f in (Get-ChildItem $Out -File | Sort-Object Name)) { $Reporte += ("- ``{0}`` ({1:N1} MB)" -f $f.Name, ($f.Length / 1MB)) }
$Reporte += ""
$Reporte += "## Criterios de exito"
$Reporte += ""
$okReg = " "; if ($PctReg -ge 90) { $okReg = "x" }
$okErr = " "; if ($ErrRep -ge 0 -and $ErrRep -lt 1) { $okErr = "x" }
$okTot = " "; if ($Total -lt 30) { $okTot = "x" }
$Reporte += "- [$okReg] >= 90 % de fotos registradas (actual: $PctReg %)"
$Reporte += "- [$okErr] Error medio de reproyeccion < 1 px (actual: $ErrRep)"
$Reporte += "- [$okTot] Pipeline completo < 30 min (actual: $Total min)"
$Reporte += "- [ ] Malla sin huecos grandes (revisar en MeshLab)"
$Reporte += "- [ ] Textura legible y alineada (revisar en MeshLab)"
$Reporte += ""
$Reporte += "Abrir en MeshLab: ``& 'C:\Program Files\VCG\MeshLab\meshlab.exe' '$Out\modelo_texturizado.obj'``"

$ReportePath = Join-Path $Out "reporte.md"
$Reporte | Out-File -FilePath $ReportePath -Encoding utf8
Write-Host ""
Write-Host ("Listo en {0} min. Reporte: {1}" -f $Total, $ReportePath) -ForegroundColor Green

if ($RegistrarExperimento) {
  $Exp = Join-Path $RepoRoot "docs\experimentos.md"
  $flag = ""; if ($SinRefinado) { $flag = " -SinRefinado" }
  $Entrada = @(
    "", "## Experimento: $Nombre", "",
    "- Fecha: $(Get-Date -Format 'yyyy-MM-dd')",
    "- Objetivo y objeto o escena: ",
    "- Camara, lente y configuracion de captura: ",
    "- Cantidad de fotografias y ubicacion de los originales: $($Imagenes.Count) en ``$ImagePath``",
    "- Condiciones de iluminacion y estrategia de captura: ",
    "- Sistema operativo y hardware: Windows 10, $Nvidia, i9-14900K, 64 GB RAM",
    "- Herramienta y version: $ColmapVer + OpenMVS v2.4.0",
    "- Comandos y parametros: ``src\run_poc.ps1 -ImagePath $ImagePath -Calidad $Calidad$flag``",
    "- Tiempo de procesamiento: $Total min",
    "- Ubicacion de los resultados: ``$Out`` (ver reporte.md)",
    "- Escala, unidades y metodo de referencia: ",
    "- Evaluacion de calidad y errores observados: $Registradas/$($Imagenes.Count) registradas, error reproyeccion $ErrRep px",
    "- Proximo ajuste: "
  )
  Add-Content -Path $Exp -Value $Entrada -Encoding UTF8
  Write-Host "Entrada agregada a docs/experimentos.md"
}
