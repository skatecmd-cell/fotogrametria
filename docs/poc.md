# POC de fotogrametría

Objetivo: obtener un modelo 3D con textura de **un objeto pequeño** a partir de fotos,
de forma reproducible por línea de comandos, y medir calidad y tiempos.

## 1. Entorno disponible (24-oct-2026)

| Recurso | Valor |
|---|---|
| SO | Windows 10 Pro 10.0.19045 |
| GPU | NVIDIA GeForce RTX 3090 Ti, 24 GB VRAM, driver 581.57 |
| CPU | Intel i9-14900K, 24 núcleos / 32 hilos |
| RAM | 64 GB |
| Disco libre | ~667 GB en C: |
| Software | Python 3.10, Docker Desktop, WSL, winget, chocolatey |

Conclusión: se puede usar el pipeline completo con aceleración CUDA, sin nube.

## 2. Pipeline de la POC

```
Fotos (JPG)
   │  1. Captura y curado          → data/raw/<sesion>/
   ▼
COLMAP  feature_extractor          (SIFT en GPU)
COLMAP  exhaustive_matcher         (emparejamiento en GPU)
COLMAP  mapper                     → Structure from Motion: poses de cámara + nube dispersa
COLMAP  image_undistorter          → imágenes rectificadas para MVS
   │                                data/processed/<sesion>/sparse, dense
   ▼
OpenMVS InterfaceCOLMAP            → convierte la escena al formato .mvs
OpenMVS DensifyPointCloud          → nube de puntos densa
OpenMVS ReconstructMesh            → malla
OpenMVS RefineMesh                 → refinado (opcional en POC)
OpenMVS TextureMesh                → malla con textura (.obj/.ply + .png)
   │                                outputs/<sesion>/
   ▼
MeshLab / CloudCompare             → inspección visual y métricas
```

Todo el flujo se encapsula en un script `src/run_poc.ps1` (o `.py`) que recibe
la carpeta de fotos y produce la carpeta de salida. Cada ejecución registra
versiones, parámetros y tiempos en `docs/experimentos.md`.

## 3. Herramientas

### Reconstrucción (núcleo)

| Herramienta | Rol | Por qué | Instalación en Windows |
|---|---|---|---|
| **COLMAP** (build CUDA) | SfM: calibración, poses, nube dispersa | Estándar de facto, CLI scriptable, usa la GPU | Binario `COLMAP-x.y-windows-cuda.zip` desde github.com/colmap/colmap/releases |
| **OpenMVS** | MVS: densificación, malla, textura | Se integra con COLMAP, CLI, buena calidad de textura | Binario Windows desde github.com/cdcseacave/openMVS/releases |

### Alternativa de comparación

| Herramienta | Rol | Nota |
|---|---|---|
| **Meshroom** (AliceVision) | Pipeline completo con GUI y CUDA | Útil para validar el resultado de COLMAP+OpenMVS con el mismo set de fotos. `winget install AliceVision.Meshroom` |

### Inspección y métricas

| Herramienta | Rol | Instalación |
|---|---|---|
| **MeshLab** | Ver malla y textura, limpiar, exportar | `winget install cnr-isti-vclab.MeshLab` |
| **CloudCompare** | Comparar nubes, medir distancias | `winget install CloudCompare.CloudCompare` |
| **Python**: `open3d`, `pycolmap`, `numpy`, `pillow` | Automatizar métricas y leer la salida de COLMAP | `pip install open3d pycolmap numpy pillow` en un venv |

### Opcional, fase 2

- **Nerfstudio / gsplat** (Gaussian Splatting) para visualización fotorrealista, reutilizando las poses de COLMAP.
- **Docker** con imagen `colmap/colmap:latest` si se quiere aislar versiones.

## 4. Sistemas y equipo de captura

| Elemento | Requisito mínimo para la POC |
|---|---|
| Cámara | Teléfono moderno o cámara réflex/mirrorless. Misma cámara y mismo zoom en toda la sesión. |
| Objeto | 20 a 40 cm, superficie **mate y con textura** (madera, piedra, cerámica sin brillo). Evitar vidrio, metal brillante, superficies lisas de un solo color. |
| Iluminación | Difusa y uniforme. Luz de día nublado o softboxes. Sin flash, sin sombras duras. |
| Fondo | Neutro y sin textura repetitiva. Opcional: base con patrón impreso para dar escala. |
| Cantidad de fotos | 80 a 150. Tres anillos de altura (bajo, medio, alto), 1 foto cada 10 a 15 grados, solapamiento mayor al 60 %. |
| Formato | JPG máxima calidad o RAW convertido a JPG. Sin recortes ni ediciones. ISO bajo, enfoque fijo, f/8 o cerrada. |
| Escala | Dos marcas con distancia conocida (regla o cinta) para escalar el modelo. |

## 5. Pasos de la POC

1. Instalar COLMAP (CUDA), OpenMVS, MeshLab y crear el venv de Python. Registrar versiones.
2. Capturar el objeto de prueba y guardarlo en `data/raw/sesion_01/`.
3. Ejecutar el pipeline con `src/run_poc.ps1 data/raw/sesion_01 outputs/sesion_01`.
4. Revisar en MeshLab: huecos, ruido, deformaciones, textura.
5. Registrar en `docs/experimentos.md`: fotos registradas vs totales, puntos dispersos y densos, caras de la malla, tiempo por etapa, error de reproyección.
6. Repetir con Meshroom sobre las mismas fotos y comparar.

## 6. Criterios de éxito

- COLMAP registra al menos el 90 % de las fotos en un único modelo.
- Error medio de reproyección menor a 1 px.
- Malla cerrada sin huecos grandes en la zona visible del objeto.
- Textura legible y alineada.
- Pipeline completo en menos de 30 min para 100 fotos con esta GPU.
- Todo el proceso se repite con un solo comando y queda documentado.

## 7. Riesgos conocidos

- Objetos brillantes o transparentes fallan en SfM. Solución: spray mate o elegir otro objeto.
- Fondo con textura puede "pegarse" al objeto. Solución: enmascarar o usar fondo liso.
- Fotos borrosas rompen el emparejamiento. Solución: trípode y descartar las desenfocadas antes de procesar.

## 8. Instalación realizada (24-oct-2026)

| Herramienta | Versión | Ubicación |
|---|---|---|
| COLMAP (CUDA) | 4.2.1 | `C:\Riesgo	ools\colmapin\colmap.exe` |
| OpenMVS (CPU) | 2.4.0 | `C:\Riesgo	ools\openmvs\*.exe` |
| MeshLab | 2025.07 | `C:\Program Files\VCG\MeshLab\meshlab.exe` |
| CloudCompare | 2.13.2 | `C:\Program Files\CloudCompare\CloudCompare.exe` |
| Python venv | 3.10 + open3d 0.20, pycolmap 4.2.1, numpy, pillow | `.venv\` en el repo |

Notas:
- Los binarios de COLMAP y OpenMVS se descargaron de sus releases oficiales en GitHub y
  quedaron fuera del repo, en `C:\Riesgo	ools\` (los zips originales en `tools\downloads\`).
- Se usa el build CPU de OpenMVS. El build CUDA viene en `.7z` y 7-Zip no se pudo instalar
  por un bloqueo de winget. Con 32 hilos la densificación es rápida; se puede cambiar después.
- Meshroom no se instaló todavía (es la alternativa de comparación, fase posterior).
- **Problema conocido**: la nivelación de costuras de TextureMesh (`--global-seam-leveling` y
  `--local-seam-leveling`) en este build deja manchas negras en el atlas de textura. El script
  las desactiva. Si se cambia de build de OpenMVS, volver a probar con ellas activas.

## 9. Cómo ejecutar el pipeline

```powershell
# POC estándar
.\src
un_poc.ps1 -ImagePath .\data
aw\sesion_01

# Prueba de humo rápida, sin refinado de malla
.\src
un_poc.ps1 -ImagePath .\data
aw\sesion_01 -Calidad rapida -SinRefinado

# Borrar intermedios anteriores y registrar en docs/experimentos.md
.\src
un_poc.ps1 -ImagePath .\data
aw\sesion_01 -Limpiar -RegistrarExperimento
```

Salidas en `outputs\<sesion>\`: `modelo_texturizado.obj` + `.mtl` + textura `.jpg`,
`scene_dense.ply`, `scene_mesh.ply`, `scene_mesh_refinada.ply`, `nube_dispersa.ply` y `reporte.md`.
Intermedios y logs en `data\processed\<sesion>\`.

Presets de `-Calidad`: `rapida` (imágenes a 1600 px, densificación a 1/4), `media` (3200 px, 1/2),
`alta` (resolución original).

## 10. Prueba de validación

Dataset público Sceaux Castle (11 fotos, muestra oficial de OpenMVS), copiado en `data/raw/sceaux`.
Resultado con `-Calidad rapida`: 11/11 fotos registradas, error de reproyección 0,70 px,
pipeline completo en 1,6 min. Reporte en `outputs/sceaux/reporte.md`.

## 11. Visor web paso a paso

Para entender el resultado sin software 3D externo, el repo incluye un visor web local:

```powershell
.\srcbrir_visor.ps1 -Sesion sceaux          # prepara datos, levanta servidor local y abre el navegador
.\srcbrir_visor.ps1 -Sesion sceaux -Regenerar   # vuelve a generar manifest y miniaturas
```

- `src/preparar_visor.py` genera `outputs/<sesion>/visor/manifest.json` (cámaras, métricas, tiempos,
  rutas de archivos) y miniaturas de las fotos.
- `src/visor/index.html` muestra seis etapas: fotos, cámaras + nube dispersa, nube densa, malla,
  malla refinada y modelo con textura. Clic en una cámara resalta su foto; doble clic en una
  miniatura la abre en grande. Se puede abrir en una etapa concreta con `&paso=N` en la URL.
- El servidor es `python -m http.server` escuchando solo en 127.0.0.1. No expone nada a la red.
- Renderiza con three.js desde CDN, así que necesita internet la primera vez que se abre.
