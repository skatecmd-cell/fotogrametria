"""Prepara los datos del visor web para una sesion.

Genera outputs/<sesion>/visor/manifest.json y miniaturas de las fotos, a partir de:
  - data/raw/<sesion>/              fotos originales
  - data/processed/<sesion>/sparse  modelo COLMAP (poses de camara)
  - outputs/<sesion>/               nubes, mallas, modelo texturizado y reporte.md

Uso:  python src/preparar_visor.py <sesion>
"""
import json
import re
import sys
from pathlib import Path

import numpy as np
import pycolmap
from PIL import Image, ImageOps

RAIZ = Path(__file__).resolve().parent.parent
EXT_FOTO = {".jpg", ".jpeg", ".png", ".tif", ".tiff"}
ANCHO_MINIATURA = 480


def elegir_modelo(sparse: Path) -> Path:
    mejor, mejor_reg = None, -1
    for d in sorted(p for p in sparse.iterdir() if p.is_dir()):
        try:
            n = pycolmap.Reconstruction(str(d)).num_reg_images()
        except Exception:
            continue
        if n > mejor_reg:
            mejor, mejor_reg = d, n
    if mejor is None:
        raise SystemExit(f"No hay modelos COLMAP en {sparse}")
    return mejor


def camaras_json(rec: pycolmap.Reconstruction):
    camaras = []
    for img in rec.images.values():
        if not img.has_pose:
            continue
        cam = rec.cameras[img.camera_id]
        cfw = img.cam_from_world()
        R = np.asarray(cfw.rotation.matrix())          # cam_from_world
        Rt = R.T                                       # columnas: ejes de la camara en el mundo
        f = float(cam.mean_focal_length())
        camaras.append({
            "nombre": img.name,
            "centro": [float(v) for v in img.projection_center()],
            "ejeX": [float(v) for v in Rt[:, 0]],
            "ejeY": [float(v) for v in Rt[:, 1]],
            "ejeZ": [float(v) for v in Rt[:, 2]],
            "ancho": cam.width / f,
            "alto": cam.height / f,
            "puntos3D": int(img.num_points3D),
        })
    return camaras


def leer_reporte(path: Path):
    """Extrae tiempos por etapa y archivos del reporte.md, si existe."""
    tiempos, meta = [], {}
    if not path.exists():
        return tiempos, meta
    txt = path.read_text(encoding="utf-8-sig")
    for m in re.finditer(r"^\| (\d\. [^|]+?) \| ([\d\.]+) \|$", txt, re.M):
        tiempos.append({"etapa": m.group(1).strip(), "segundos": float(m.group(2))})
    for clave, patron in {
        "fecha": r"^- Fecha: (.+)$",
        "calidad": r"^- Calidad: (.+)$",
        "colmap": r"^- COLMAP: (.+)$",
        "openmvs": r"^- OpenMVS: (.+)$",
        "gpu": r"^- GPU: (.+)$",
        "tiempo_total_min": r"^- Tiempo total: ([\d\.]+) min$",
    }.items():
        m = re.search(patron, txt, re.M)
        if m:
            meta[clave] = m.group(1).strip()
    return tiempos, meta


def main(sesion: str):
    fotos_dir = RAIZ / "data" / "raw" / sesion
    sparse = RAIZ / "data" / "processed" / sesion / "sparse"
    salida = RAIZ / "outputs" / sesion
    visor = salida / "visor"
    minis = visor / "fotos"
    minis.mkdir(parents=True, exist_ok=True)

    modelo = elegir_modelo(sparse)
    rec = pycolmap.Reconstruction(str(modelo))
    camaras = camaras_json(rec)
    registradas = {c["nombre"] for c in camaras}

    fotos = []
    for p in sorted(x for x in fotos_dir.iterdir() if x.is_file() and x.suffix.lower() in EXT_FOTO):
        destino = minis / (p.stem + ".jpg")
        if not destino.exists():
            with Image.open(p) as im:
                im = ImageOps.exif_transpose(im).convert("RGB")
                im.thumbnail((ANCHO_MINIATURA, ANCHO_MINIATURA))
                im.save(destino, "JPEG", quality=82)
        fotos.append({
            "nombre": p.name,
            "miniatura": f"/outputs/{sesion}/visor/fotos/{destino.name}",
            "original": f"/data/raw/{sesion}/{p.name}",
            "registrada": p.name in registradas,
        })

    def ruta(nombre):
        p = salida / nombre
        return {"url": f"/outputs/{sesion}/{nombre}", "mb": round(p.stat().st_size / 1e6, 1)} if p.exists() else None

    textura = next((p.name for p in salida.glob("modelo_texturizado*") if p.suffix.lower() in {".jpg", ".jpeg", ".png"}), None)

    tiempos, meta = leer_reporte(salida / "reporte.md")
    # Caja robusta: percentiles de la nube dispersa (ignora puntos lejanos mal triangulados) + camaras.
    puntos = np.array([p.xyz for p in rec.points3D.values()]) if rec.num_points3D() else np.zeros((0, 3))
    centros = np.array([c["centro"] for c in camaras]) if camaras else np.zeros((0, 3))
    if len(puntos):
        p_min, p_max = np.percentile(puntos, 3, axis=0), np.percentile(puntos, 97, axis=0)
    else:
        p_min = p_max = np.zeros(3)
    todo = np.vstack([p_min, p_max, centros]) if len(centros) else np.vstack([p_min, p_max])

    manifest = {
        "sesion": sesion,
        "meta": meta,
        "estadisticas": {
            "fotos": len(fotos),
            "registradas": len(camaras),
            "puntos_dispersos": rec.num_points3D(),
            "error_reproyeccion_px": round(rec.compute_mean_reprojection_error(), 3),
            "modelo_colmap": modelo.name,
        },
        "bbox": {"min": todo.min(axis=0).tolist(), "max": todo.max(axis=0).tolist()},
        "fotos": fotos,
        "camaras": camaras,
        "archivos": {
            "nube_dispersa": ruta("nube_dispersa.ply"),
            "nube_densa": ruta("scene_dense.ply"),
            "malla": ruta("scene_mesh.ply"),
            "malla_refinada": ruta("scene_mesh_refinada.ply"),
            "obj": ruta("modelo_texturizado.obj"),
            "mtl": ruta("modelo_texturizado.mtl"),
            "textura": ruta(textura) if textura else None,
        },
        "tiempos": tiempos,
    }
    (visor / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"Visor preparado: {visor / 'manifest.json'}")
    print(f"  {len(fotos)} fotos, {len(camaras)} camaras, {rec.num_points3D()} puntos dispersos")
    print(f"  Abrir con: .\\src\\abrir_visor.ps1 -Sesion {sesion}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    main(sys.argv[1])
