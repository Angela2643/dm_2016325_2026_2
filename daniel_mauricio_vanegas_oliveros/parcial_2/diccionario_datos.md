# Diccionario de datos · `productos.sqlite`

Base SQLite del comparador de precios (categoría *Galletas, cereales, frutos secos,
barras convencionales, conservas y otros alimentos*; Carulla, Éxito y Jumbo).
Todos los precios están en **pesos colombianos (COP)** y son los que mostraba el
comercio en el momento de la consulta. Las fechas usan la hora de Colombia (UTC-5).

## Cómo leer el modelo

Cada vez que se corre el scraper se crea una **ejecución** (`ejecuciones`). Cada
ejecución tiene una fila por comercio (`ejecuciones_comercio`) y muchas
observaciones (`productos`). Lo que no pasa la validación va a `rechazados`; los
cambios hechos a la base del Taller 1 se anotan en `correcciones`.

| Tabla / vista | Para qué sirve |
|---|---|
| `ejecuciones` | Una fila por lectura del scraper (fecha, origen, estado). |
| `ejecuciones_comercio` | Resultado de cada comercio dentro de una ejecución. |
| `productos` | Una fila por anuncio observado en una ejecución. |
| `presentaciones_comparables` | Catálogo de las 8 presentaciones comparables y sus reglas. |
| `rechazados` | Observaciones que no pasaron la validación, con el motivo. |
| `correcciones` | Cambios hechos a la base del Taller 1. |
| `v_productos` | `productos` con la fecha de su ejecución. Base de los filtros de la app. |
| `v_ultimo_precio` | El precio más reciente de cada anuncio. |
| `v_comparables` | Los productos comparables con su precio unitario. |
| `v_cambios_precio` | Anuncios cuyo precio cambió frente a su observación anterior. |

---

## `ejecuciones`

| Columna | Tipo | Significado | Valores |
|---|---|---|---|
| `id_ejecucion` | INTEGER (PK) | Número de la ejecución. | 1, 2, 3… |
| `clave` | TEXT, única | Identifica las copias crudas de la ejecución. Impide registrar dos veces lo mismo. | `raw:1` (sin sufijo, 10 oct.), `raw:2` (archivos `…2.html`), … |
| `fecha_consulta` | TEXT | Fecha de la ejecución (primera observación). | `AAAA-MM-DD` |
| `inicio`, `fin` | TEXT | Hora de la primera y la última consulta. | ISO 8601 con zona, p. ej. `2026-10-10T18:33:55-0500` |
| `modo` | TEXT | Cómo se obtuvo. | `online` (scraping desde la app), `offline` (reproceso de `raw/`), `importada` (lectura del Taller 1) |
| `estado` | TEXT | Resultado global. | `completa`, `parcial`, `fallida` |
| `sufijo_raw` | TEXT | Sufijo de los archivos de `raw/`. | `""`, `"2"`, `"3"`… |
| `n_obs` | INTEGER | Observaciones insertadas. | ≥ 0 |
| `nota` | TEXT | Comentario libre. | |

## `ejecuciones_comercio`

| Columna | Tipo | Significado | Valores |
|---|---|---|---|
| `id_ejecucion` | INTEGER | Ejecución. | FK a `ejecuciones` |
| `comercio` | TEXT | Comercio. | `Carulla`, `Exito`, `Jumbo` |
| `estado` | TEXT | `completa`: las 8 consultas respondieron y están los 8 comparables. `parcial`: faltó algo. `fallida`: no se obtuvo nada. | `completa`, `parcial`, `fallida` |
| `n_recolectados` | INTEGER | Productos extraídos del HTML. | |
| `n_insertados` | INTEGER | Observaciones que entraron a la base. | |
| `n_rechazados` | INTEGER | Observaciones rechazadas por la validación. | |
| `motivo` | TEXT | Por qué no fue `completa` (errores de red, comparables que faltan…). | |

## `productos`

Restricción de unicidad: `(id_ejecucion, comercio, subcategoria, titulo_norm)`.
Insertar dos veces la misma observación no la duplica.

| Columna | Tipo | Significado | Unidad / valores |
|---|---|---|---|
| `id_obs` | INTEGER (PK) | Identificador de la observación. | |
| `id_ejecucion` | INTEGER | Ejecución a la que pertenece. | FK |
| `fecha_consulta` | TEXT | Fecha de la consulta. | `AAAA-MM-DD` |
| `hora_consulta` | TEXT | Fecha y hora exactas de la consulta. | ISO 8601 |
| `comercio` | TEXT | Comercio donde apareció. | `Carulla`, `Exito`, `Jumbo` |
| `subcategoria` | TEXT | Término de búsqueda con el que se encontró. | `frutos_secos`, `granola`, `chocorramo`, `barras_cereal`, `gansito`, `conserva`, `cereales`, `galletas` |
| `titulo` | TEXT | Texto original del anuncio. | |
| `titulo_norm` | TEXT | `titulo` en minúsculas y sin espacios sobrantes. Con el comercio identifica el mismo anuncio entre ejecuciones. | |
| `marca_producto` | TEXT | Marca. En Jumbo viene del sitio; en Carulla y Éxito se extrae de las palabras en mayúsculas del título. Puede ser `NULL`. | |
| `precio_texto` | TEXT | Precio tal como se mostraba. | p. ej. `$ 16.730` |
| `precio` | REAL | Precio final. | COP, > 0 |
| `precio_previo_texto`, `precio_previo` | TEXT, REAL | Precio antes del descuento; `NULL` si no hay descuento. | COP |
| `tiene_descuento` | INTEGER | 1 si el anuncio mostraba precio previo. | 0 / 1 |
| `descuento_pct` | REAL | Descuento mostrado frente al precio previo. | % (`NULL` sin descuento) |
| `gramos` | REAL | Gramaje que dice el título (en gramos; los kg se convierten). Puede ser **por unidad**. | g, `NULL` si no se encontró |
| `unidades` | REAL | Unidades por empaque según el título (1 si no dice nada). | |
| `contenido_total` | REAL | Contenido del empaque completo. Si el título dice «x6 … 37 g c/u» es 6 × 37. `NULL` si no se pudo calcular (no se inventa). | g o unidades |
| `unidad_medida` | TEXT | Unidad de `contenido_total`. | `g`, `mL`, `unidad` (`NULL` si no hay dato) |
| `disponibilidad` | TEXT | Disponibilidad indicada por el sitio. **El scraper actual no captura el aviso de «agotado»**, por eso siempre es `NULL` (= sin dato). | `disponible`, `agotado` o `NULL` |
| `pagina_consulta` | TEXT | URL de la búsqueda del comercio donde apareció el anuncio. | URL |
| `archivo_raw` | TEXT | Copia cruda de la que salió la observación (para rastrearla). | p. ej. `raw/Carulla_cereales2.html` |
| `comparable` | INTEGER | 1 si cumple la regla de alguna presentación comparable. | 0 / 1 |
| `id_presentacion` | TEXT | Presentación comparable a la que corresponde. | `P01`…`P08` o `NULL` |

> **Los tres estados de disponibilidad.** *Disponible* y *agotado* se guardan en
> `disponibilidad` cuando el sitio los informe. *No observado* no se guarda: es la
> ausencia de una fila y se calcula comparando ejecuciones (columna `estado` de la
> sección «Cambios de precio»). Un producto no observado **no** se interpreta como
> agotado ni como retirado.

## `presentaciones_comparables`

| Columna | Tipo | Significado | Unidad / valores |
|---|---|---|---|
| `id_presentacion` | TEXT (PK) | Código de la presentación. | `P01`…`P08` |
| `producto` | TEXT | Nombre normalizado. | |
| `contenido_total` | REAL | Contenido del empaque. | g |
| `unidad_medida` | TEXT | Unidad. | `g` |
| `unidades_paquete` | REAL | Unidades que trae el empaque. | 1 o 6 |
| `marca_like`, `marca_like_alt` | TEXT | Patrones `LIKE` sobre la marca. | |
| `gramos`, `unidades` | REAL | Igualdad exacta con lo extraído del título (`NULL` = no se usa). | |
| `titulo_like`, `titulo_not_like` | TEXT | Patrones `LIKE` que el título debe / no debe cumplir. | |

## `rechazados`

| Columna | Tipo | Significado |
|---|---|---|
| `id_rechazo` | INTEGER (PK) | Identificador. |
| `id_ejecucion` | INTEGER | Ejecución en la que se rechazó. |
| `comercio`, `subcategoria`, `titulo`, `precio_texto` | TEXT | Datos de la observación rechazada. |
| `motivo` | TEXT | `precio no numérico`, `precio menor o igual a cero`, `comercio ausente`, `URL ausente`, `fecha y hora de consulta ausentes`, `título ausente`, `observación duplicada en la misma ejecución`. |
| `fecha_registro` | TEXT | Día en que se registró el rechazo. |

## `correcciones`

| Columna | Tipo | Significado |
|---|---|---|
| `id_correccion` | INTEGER (PK) | Identificador. |
| `fecha` | TEXT | Día de la corrección. |
| `tabla`, `registro`, `campo` | TEXT | Qué se corrigió y dónde (`id_obs=…` o el código de la presentación). |
| `valor_anterior`, `valor_nuevo` | TEXT | Antes y después. |
| `motivo` | TEXT | Por qué. |

---

## Vistas

### `v_productos`
Todas las columnas de `productos` útiles para filtrar, más:

| Columna | Significado | Unidad |
|---|---|---|
| `fecha_consulta` | Fecha de la **ejecución** (la que se usa en los ejes de los gráficos). | `AAAA-MM-DD` |
| `marca` | `marca_producto` en mayúsculas y sin espacios sobrantes. | |
| `precio_unitario` | `precio / contenido_total`. `NULL` si no hay contenido. | COP por g (o por unidad) |

### `v_ultimo_precio`
Mismas columnas que `v_productos` (más `rn`, siempre 1): una fila por anuncio
(`comercio` + `titulo_norm`) con su observación más reciente.

### `v_comparables`
Las observaciones con `comparable = 1`, unidas al catálogo.

| Columna | Significado | Unidad |
|---|---|---|
| `id_ejecucion`, `fecha_consulta`, `hora_consulta` | Ejecución y momento. | |
| `comercio`, `id_presentacion`, `producto`, `titulo` | Qué producto y dónde. | |
| `precio`, `precio_previo`, `tiene_descuento`, `descuento_pct` | Precio y descuento. | COP, 0/1, % |
| `contenido_total`, `unidad_medida`, `unidades_paquete` | Del catálogo (ya normalizados). | g, texto, unidades |
| `precio_unitario` | `precio / contenido_total`. | COP por g |
| `precio_por_unidad` | `precio / unidades_paquete`. | COP por unidad del empaque |

### `v_cambios_precio`
Un anuncio aparece cuando su precio es distinto al de su observación anterior.

| Columna | Significado | Unidad |
|---|---|---|
| `id_ejecucion`, `id_ejecucion_anterior`, `fecha_consulta` | Ejecución en que se vio el cambio y la anterior en que se observó el anuncio. | |
| `comercio`, `titulo` | Anuncio. | |
| `precio_anterior`, `precio` | Antes y después. | COP |
| `cambio_cop`, `cambio_pct` | Diferencia absoluta y relativa. | COP, % |

---

## Comparación entre dos ejecuciones (`db_cambios()`)

No es una vista porque las dos ejecuciones las elige el usuario.

| Columna | Significado | Valores |
|---|---|---|
| `estado` | Qué pasó con el anuncio. | `subió`, `bajó`, `igual`, `nuevo` (solo en la segunda), `no observado` (solo en la primera) |
| `variacion_grande` | 1 si `|cambio_pct|` ≥ el umbral elegido. | 0 / 1 |
