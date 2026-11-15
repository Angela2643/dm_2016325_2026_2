# Comparador de precios: lágrimas artificiales y medicamentos oculares/óticos (Taller 2)

- **Asignatura:** Minería de Datos (2016325) — Universidad Nacional de Colombia
- **Lenguaje de programación:** R (Shiny + `bslib` + `highcharter` + `DT` + SQLite)
- **Aplicación publicada:** *(Pendiente de despliegue en shinyapps.io — completar tras ejecutar `rsconnect::deployApp()`)*

> **Nota sobre despliegue en plataforma gratuita:** En plataformas gratuitas como `shinyapps.io`, el sistema de archivos es efímero y los cambios en `comparador_precios.sqlite` tras una actualización en línea o sin conexión no persisten cuando el contenedor se reinicia. La actualización en línea funciona de forma persistente en la ejecución local; además, si los comercios bloquean peticiones desde la nube o no está configurada `FARMATODO_ALGOLIA_KEY`, la aplicación informa el estado por comercio y permite reprocesar las copias en `raw/` mediante el **modo sin conexión**.

---

## 1. Estructura de archivos

```text
taller_2/
├── app.R                      # Aplicación web Shiny (bslib, highcharter, DT, ExtendedTask)
├── db.R                       # Capa de acceso a datos SQL parametrizada (sin SQL en la interfaz)
├── scraper.R                  # Módulo de web scraping (Farmatodo, Colsubsidio, Farmacias Pasteur) y esquema SQLite
├── validacion.R               # Reglas explícitas de validación antes de insertar y limpieza de precios
├── migracion.R                # Script idempotente de migración y registro en la tabla correcciones
├── comparador_precios.sqlite  # Base SQLite con corridas completas del 2026-10-10 y 2026-11-11
├── diccionario_datos.md       # Diccionario completo de tablas, vistas, columnas e índices
├── raw/                       # Copias crudas JSON (.json.gz + meta.json) por comercio y fecha
├── tests/
│   └── test_taller2.R         # Pruebas automáticas con testthat (datos pequeños/base temporal)
├── renv.lock                  # Dependencias de R con versiones fijas
├── .gitignore                 # Excluye .Renviron, .RData, .Rhistory, rsconnect/ y librería renv
├── .rscignore                 # Excluye credenciales y archivos locales del paquete de despliegue
└── README.md
```

---

## 2. Ejecución local y pruebas

### Requisitos previos y restauración del entorno
1. Tener instalado **R (>= 4.6.0)**.
2. Restaurar las dependencias exactas registradas en `renv.lock`:
   ```r
   renv::restore()
   ```
3. *(Opcional, solo para scraping en vivo de Farmatodo)* Crear un archivo `.Renviron` (ignorado por Git) en la raíz del proyecto con la clave pública de solo búsqueda de Algolia observada en las herramientas de red del navegador:
   ```text
   FARMATODO_ALGOLIA_KEY=tu_clave_aqui
   ```
   Sin esta clave, Farmatodo reportará el faltante de forma controlada y la aplicación permitirá seguir usando el modo sin conexión (`raw/`) y los demás comercios.

### Ejecutar la aplicación localmente
Desde la carpeta `taller_2/`:
```bash
Rscript -e "shiny::runApp('.')"
```
O desde R/RStudio:
```r
shiny::runApp(".")
```

### Ejecutar las pruebas automáticas
Desde la carpeta `taller_2/` (un solo comando):
```bash
Rscript -e "testthat::test_dir('tests')"
```
Las 8 pruebas en [tests/test_taller2.R](tests/test_taller2.R) usan datos sintéticos pequeños y bases SQLite temporales (nunca la base de entrega ni los sitios reales) para verificar:
1. Conversión de precios en texto a número (`limpiar_precio`).
2. Normalización de unidades a `mL` y `g` descartando concentraciones (`extraer_contenido`).
3. Cálculo de ahorro entre comercios manejando empates en el mínimo (`ahorro_comparables`).
4. Idempotencia: insertar dos veces la misma ejecución no duplica observaciones.
5. Detección de cambios de precio (`subio`, `bajo`, `nuevo`, `dejo de observarse`) y umbral configurable (`cambios_precio`).
6. Regla de canasta incompleta: no se calcula total en comercios donde falte algún producto (`resultado_canasta`).
7. Rechazo de observaciones inválidas (precio `<= 0`, URL ausente, duplicados).
8. Validación y saneamiento de búsquedas de texto libre (`validar_busqueda`).

---

## 3. Vistas SQL y acceso a datos

Todas las consultas viven en `db.R` usando marcadores `?` (consultas parametrizadas) y consultan directamente las vistas creadas por `scraper.R`:

- **`v_corridas_completas`**: identifica las corridas (`AAAAMMDDTHHMMSS`) en las que los tres comercios finalizaron con estado `completa`, conservando la última corrida válida de cada día.
- **`v_precio_por_corrida`**: entrega exactamente una observación válida (`descartada = 0`, `precio > 0`) por anuncio y corrida, con su precio, precio de lista, indicador de promoción y estado de disponibilidad.
- **`v_ultimo_precio`**: devuelve el precio más reciente observado para cada anuncio incluido en la categoría (`incluido = 1`), junto con el `precio_unitario` calculado cuando el contenido es positivo.
- **`v_comparables`**: cruza `v_precio_por_corrida` con los 12 productos comparables (`productos`), exponiendo precio total y `precio_unitario` por `mL` en los tres comercios.
- **`v_cambios_precio`**: compara las dos últimas corridas completas sobre el mismo anuncio incluido en el mismo comercio, calculando `cambio_cop`, `cambio_pct` y `direccion` (`subio`, `bajo`, `igual`).

### Justificación del gráfico 4 (libre elección)
El cuarto gráfico interactivo (**"Ahorro potencial (%) por presentación comparable"**) responde a la pregunta del consumidor: *"¿En qué presentaciones comparables logro el mayor ahorro porcentual y en pesos al elegir el comercio más barato?"*. Muestra el porcentaje de ahorro (`100 * (Pmax - Pmin) / Pmax`) ordenado de mayor a menor, coloreado según el comercio más económico (o gris en caso de empate), y detalla en el tooltip el ahorro exacto en COP, el comercio más barato y el más caro.

---

## 4. Hallazgos para el consumidor

Análisis verificado directamente en la aplicación sobre las dos corridas completas registradas en `comparador_precios.sqlite`: **10 de octubre de 2026** (`20261010T224252`, Taller 1) y **11 de noviembre de 2026** (`20261111T155632`, Taller 2).

1. **Ahorros de hasta 16,0 % ($11.891 COP) por elegir comercio en la corrida `20261111T155632`:**
   Entre los 12 productos comparables del 11 de noviembre de 2026, la diferencia entre el comercio más caro y el más barato oscila entre 1,0 % (`Lagricel Ofteno 0.4% 10 mL`, $753 COP) y 16,0 % (`Optive Fusion 15 mL`, $11.891 COP: $62.559 COP en Farmacias Pasteur frente a $74.450 COP en Farmatodo). Farmatodo ofrece el precio mínimo (solo o empatado con Colsubsidio) en 8 de las 12 presentaciones, mientras que Farmacias Pasteur presenta el precio más alto en 11 de las 12. En toda la categoría (182 productos incluidos en `20261111T155632`), la mediana global es $62.150 COP (`lagrima_artificial`: $68.900 COP; `oftalmico`: $45.035,5 COP; `otico`: $40.950 COP).

2. **Menor costo por mililitro en envases de 15 mL y baja frecuencia de promociones (`20261111T155632`):**
   Al comparar tamaños de una misma formulación sin mezclar unidades, las presentaciones de 15 mL ofrecen un menor costo por mL: por ejemplo, en `Optive Fusion`, el frasco de `15 mL` en Farmacias Pasteur ($62.559 COP con promoción) equivale a ~$4.171 COP/mL frente a $5.495 COP/mL del envase de `10 mL` más barato ($54.950 COP en Farmatodo). Por otro lado, solo el 3,3 % de los productos incluidos (6 de 182: 4 en Colsubsidio, 2 en Farmacias Pasteur y 0 en Farmatodo) registraba precio promocional en esa corrida, lo que confirma que las ofertas son puntuales y no reemplazan la comparación directa de precios.

3. **Variaciones de precio entre octubre y noviembre de 2026 (`20261010T224252` vs `20261111T155632`):**
   Al comparar ambas corridas completas, 35 anuncios incluidos cambiaron de precio (25 subieron y 10 bajaron), aparecieron 3 anuncios nuevos y 9 dejaron de observarse (todos en Farmacias Pasteur tras su migración de plataforma de VTEX IO a Shopify). Destacan variaciones mayores al 20 %, como incrementos cercanos al 25 % en `Hialsoft 0.15% 10 mL` (Colsubsidio y Pasteur) y `Lagrifresh 15 mL` (Pasteur), junto con una rebaja del 20,0 % (-$15.640 COP) en `Optive Fusion 15 mL` en Farmacias Pasteur. Al armar una canasta, el consumidor debe evaluar si el ahorro por dividir la compra entre comercios compensa los costos de envío y mínimos de compra (no incluidos en la herramienta).

---

## 5. Declaración de uso de inteligencia artificial

Para el desarrollo de este taller se utilizó el asistente de IA **Antigravity (modelo Gemini)** como apoyo en las siguientes tareas:
- Diseño e implementación de la interfaz Shiny en `app.R` (`bslib`, gráficos interactivos `highcharter`, tabla `DT`, caché con `bindCache` y tareas asíncronas con `ExtendedTask`, `promises` y `future`).
- Corrección menor en `db.R` (manejo de consultas sin parámetros en `indicadores()`) y ajuste de `v_cambios_precio` en `scraper.R` para filtrar `a.incluido = 1`.
- Redacción de la suite de pruebas automáticas en `tests/test_taller2.R` y documentación en `README.md`.

**Verificación realizada:** Todo el código y los resultados presentados en este documento fueron ejecutados y verificados directamente sobre la base `comparador_precios.sqlite` mediante:
- Ejecución de las 8 pruebas automáticas (`testthat::test_dir("tests")`, 36 aserciones aprobadas, 0 fallos).
- Pruebas de servidor Shiny (`shiny::testServer`) validando todos los indicadores, gráficos, tabla filtrada, cambios de precio y cálculo de canasta.
- Consultas SQL independientes sobre `comparador_precios.sqlite` para corroborar los valores reportados en la sección de hallazgos.
