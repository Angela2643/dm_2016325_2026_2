# Diccionario de datos - `comparador_precios.sqlite`

Categoría: lágrimas artificiales y medicamentos de aplicación ocular u ótica (excluye soluciones para limpiar lentes de contacto).
Comercios: Farmatodo, Droguerías Colsubsidio y Farmacias Pasteur. Moneda: COP. Fechas: ISO 8601, hora de Colombia (`-05:00`).
Un dato ausente es `NULL`; nunca se reemplaza por cero.

## Conceptos clave

- **Corrida**: una llamada a `recolectar_todo()`. Identificador `AAAAMMDDTHHMMSS` (los 15 primeros caracteres de `ejecuciones.id`). Una corrida tiene una ejecución por comercio.
- **Ejecución**: la corrida de un comercio. `ejecuciones.id = <corrida>_<comercio>` (por ejemplo `20261111T155146_pasteur`).
- **Corrida completa**: aquella en la que los tres comercios terminaron con estado `completa`.
- **Anuncio**: un producto tal como aparece en un comercio (con su texto original). **Observación**: el precio de un anuncio en un momento dado.
- **Disponibilidad**: tres situaciones. *Disponible* y *agotado según el sitio* (columna `estado_disponibilidad`) y *no observado* (el anuncio no tiene observación ni rechazo en esa ejecución; no significa agotado ni retirado).

## Tablas

### `comercios`
| Columna | Tipo | Significado |
|---|---|---|
| id | INTEGER | Identificador del comercio. |
| nombre | TEXT | Nombre (único): Farmatodo, Colsubsidio, Farmacias Pasteur. |
| url_base | TEXT | Dirección base del sitio. |
| categorias_equivalentes | TEXT | Secciones del sitio consideradas equivalentes a la categoría. |

### `ejecuciones`
| Columna | Tipo | Significado |
|---|---|---|
| id | TEXT | `<corrida>_<comercio>`. Clave primaria. |
| inicio | TEXT | Fecha y hora de inicio (ISO 8601, `-05:00`). |
| comercio_id | INTEGER | Comercio de la ejecución. |
| n_registros | INTEGER | Productos obtenidos. |
| total_sitio | INTEGER | Total que declara el propio sitio para la categoría (`NULL` si no se pudo leer). |
| estado | TEXT | `completa`, `parcial` o `fallida`. Parcial: menos productos que el total del sitio, o menos de 8 comparables presentes. |
| detalle | TEXT | Modo (en línea o reprocesado desde `raw/`), observaciones válidas y rechazadas, comparables presentes, o el mensaje de error si falló. |

### `productos`
Productos o presentaciones comparables (identificador común entre comercios).
| Columna | Tipo | Significado |
|---|---|---|
| id | INTEGER | Identificador común del producto/presentación. |
| nombre | TEXT | Nombre, por ejemplo `Systane Ultra 10 mL`. |
| marca | TEXT | Marca. |
| presentacion | TEXT | Presentación (`10 mL`). |
| contenido_valor | REAL | Contenido total normalizado. |
| contenido_unidad | TEXT | Unidad normalizada: `mL`, `g` o `unidad`. |
| num_unidades | INTEGER | Unidades por empaque (1). |
| regla_correspondencia | TEXT | Regla documentada con la que se asignaron los anuncios de cada comercio. |

### `anuncios`
| Columna | Tipo | Significado |
|---|---|---|
| id | INTEGER | Identificador. |
| comercio_id | INTEGER | Comercio. |
| sku | TEXT | Identificador interno del producto en el comercio (único por comercio). |
| url | TEXT | Página del anuncio. |
| nombre_original | TEXT | Nombre tal como lo publica el sitio, sin limpiar. |
| marca_original | TEXT | Marca/laboratorio tal como la publica el sitio. |
| descripcion_original | TEXT | Descripción o ficha del sitio (HTML original), si existe. |
| categoria_sitio | TEXT | Sección del sitio de la que se extrajo. |
| nombre_estandar | TEXT | Nombre en minúsculas, sin espacios repetidos, con la presentación. |
| marca_estandar | TEXT | Marca normalizada (de una lista de marcas conocidas; si no, la del sitio). |
| subcategoria | TEXT | `lagrima_artificial`, `oftalmico` u `otico`. |
| marca_comercial, principio_activo, concentracion, presentacion, registro_invima | TEXT | Datos que el sitio publica por separado (`NULL` si no los da). |
| registro_invima_norm | TEXT | Registro Invima sin guiones, sin sufijo de renovación y sin ceros a la izquierda. |
| contenido_valor | REAL | Contenido del envase normalizado (1 L = 1000 mL). `NULL` en ofertas o combos ambiguos. |
| contenido_unidad | TEXT | `mL` o `g`. |
| incluido | INTEGER | 1 si pertenece a la categoría; 0 si se excluyó. |
| motivo_exclusion | TEXT | Por qué se excluyó (solución de lentes, higiene de párpados, vía oral, volumen mayor de 30 mL). |
| revisar_manual | INTEGER | 1 si es un caso borde que conviene revisar a mano. |
| producto_id | INTEGER | Producto comparable al que corresponde (`NULL` si no es comparable). |
| comparable | INTEGER | 1 si el anuncio corresponde a un producto comparable. |

Restricción: `UNIQUE(comercio_id, sku)`.

### `observaciones`
| Columna | Tipo | Significado |
|---|---|---|
| id | INTEGER | Identificador. |
| ejecucion_id | TEXT | Ejecución a la que pertenece. |
| anuncio_id | INTEGER | Anuncio observado. |
| precio | REAL | Precio en COP en ese momento. |
| precio_lista | REAL | Precio antes del descuento; solo si el sitio muestra una promoción. |
| promocion | INTEGER | 1 si el precio es promocional. |
| disponible | INTEGER | 1 disponible, 0 agotado según el sitio, `NULL` sin dato. |
| fecha_consulta | TEXT | Fecha y hora en que se observó el precio (ISO 8601). |
| descartada | INTEGER | 1 si se marcó como descartada (no se borra). |
| motivo_descarte | TEXT | Motivo del descarte. |
| estado_disponibilidad | TEXT | `disponible`, `agotado` o `sin_dato`. |

Restricción: `UNIQUE(anuncio_id, fecha_consulta)` impide insertar dos veces la misma observación.

### `observaciones_rechazadas`
Observaciones que no superaron la validación; no entran a `observaciones`.
| Columna | Tipo | Significado |
|---|---|---|
| id | INTEGER | Identificador. |
| ejecucion_id | TEXT | Ejecución. |
| comercio_id | INTEGER | Comercio. |
| sku | TEXT | SKU del anuncio. |
| nombre_original | TEXT | Nombre del anuncio. |
| precio | REAL | Precio recibido (puede ser `NULL`). |
| estado_disponibilidad | TEXT | `disponible`, `agotado` o `sin_dato`. Un producto agotado sin precio queda aquí. |
| motivo | TEXT | Regla incumplida: precio ausente o no positivo, URL ausente, fecha fuera de ISO 8601, duplicada en la ejecución. |
| fecha_consulta | TEXT | Fecha y hora de la consulta. |

### `correcciones`
Registro de cada corrección hecha sobre la base del Taller 1 o por cambios de plataforma.
| Columna | Tipo | Significado |
|---|---|---|
| id | INTEGER | Identificador. |
| fecha | TEXT | Fecha y hora de la corrección. |
| tabla | TEXT | Tabla afectada. |
| registro_id | TEXT | Identificador del registro afectado. |
| campo | TEXT | Campo corregido. |
| valor_anterior | TEXT | Valor antes de la corrección. |
| valor_nuevo | TEXT | Valor después. |
| motivo | TEXT | Por qué se corrigió. |

## Vistas

| Vista | Qué devuelve |
|---|---|
| `v_corridas_completas` | Corridas en las que los tres comercios terminaron `completa` (`corrida`, `inicio`). |
| `v_precio_por_corrida` | Un precio por anuncio y corrida (la última observación válida de la corrida): `corrida`, `anuncio_id`, `fecha_consulta`, `precio`, `precio_lista`, `promocion`, `estado_disponibilidad`. |
| `v_ultimo_precio` | Último precio observado de cada anuncio incluido: comercio, nombre, marca, subcategoría, contenido, precio, precio de lista, promoción, disponibilidad, fecha, URL y `precio_unitario` (COP por mL o g). |
| `v_comparables` | Observaciones de los productos comparables por corrida, con `precio_unitario` (COP por mL). |
| `v_cambios_precio` | Cambio de precio del mismo anuncio en el mismo comercio entre las dos últimas corridas completas: `precio_anterior`, `precio_nuevo`, `cambio_cop`, `cambio_pct`, `direccion` (`subio`, `bajo`, `igual`). |

## Índices

`idx_obs_anuncio_fecha`, `idx_obs_ejecucion`, `idx_anuncios_comercio`, `idx_anuncios_producto`, `idx_anuncios_marca`, `idx_anuncios_subcat`, `idx_ejec_comercio`, `idx_rech_ejecucion`: sobre las columnas que usan los filtros de la aplicación.
