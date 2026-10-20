# Fotogrametría

Proyecto para reconstruir objetos y escenas en 3D a partir de fotografías.

## Objetivo inicial

Completar y documentar una reconstrucción reproducible: fotografías → cámaras estimadas → nube de puntos → malla → modelo con textura.

## Estructura

- `data/raw/`: fotografías originales (no se suben a Git).
- `data/processed/`: datos intermedios (no se suben a Git).
- `outputs/`: nubes de puntos, mallas, texturas y reportes (no se suben a Git).
- `src/`: código y scripts del proyecto.
- `docs/`: documentación de captura, configuración y experimentos.

## Primeros pasos

1. Definir el objeto o escena y el resultado esperado.
2. Capturar fotografías con buena cobertura, solapamiento y luz uniforme.
3. Guardar los originales en `data/raw/` y registrar la sesión en `docs/experimentos.md`.
4. Elegir la herramienta de reconstrucción y registrar su versión y parámetros.
5. Ejecutar la reconstrucción y guardar los resultados en `outputs/`.
6. Documentar calidad, problemas y próximos ajustes.

Las herramientas y dependencias se definirán después de conocer el sistema operativo, el hardware y el tipo de reconstrucción. No hay un pipeline implementado todavía.

## Datos y archivos grandes

Las fotografías y los resultados quedan fuera de Git para evitar subir archivos pesados o información sensible. Documentar la ubicación de los datos y cómo obtenerlos cuando se trabaje en equipo. No guardar credenciales en el repositorio.
