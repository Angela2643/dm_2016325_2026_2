# db.R - Capa de acceso a datos (Módulo 3).
# La interfaz NO contiene SQL: llama a estas funciones, que reciben los
# filtros como argumentos y devuelven tablas.
#
# v1.0
#  - Todo valor que viene del usuario se pasa como parámetro (?), nunca se
#    pega en el texto de la consulta. Solo se insertan marcadores "?".
#  - Filtros, indicadores y agregaciones se calculan con SQL sobre SQLite.
#  - La conexión se abre y se cierra de forma controlada (abrir_con / cerrar_con).

# ---- 1. Conexión ----------------------------------------------------------

# Ruta relativa a taller_2/. Se puede cambiar con options(taller2.ruta_db = ...)
# (las pruebas usan una base temporal).
ruta_base <- function() getOption("taller2.ruta_db", "productos.sqlite")

abrir_con <- function(ruta = ruta_base()) {
  con <- DBI::dbConnect(RSQLite::SQLite(), ruta)
  DBI::dbExecute(con, "PRAGMA foreign_keys = ON;")
  DBI::dbExecute(con, "PRAGMA busy_timeout = 8000;")
  con
}

cerrar_con <- function(con) {
  if (!is.null(con) && DBI::dbIsValid(con)) DBI::dbDisconnect(con)
  invisible(NULL)
}

# Ejecuta una consulta con parámetros posicionales (?).
consultar <- function(con, sql, params = list()) {
  if (length(params) == 0) return(DBI::dbGetQuery(con, sql))
  DBI::dbGetQuery(con, sql, params = unname(params))
}

marcadores <- function(n) paste(rep("?", n), collapse = ", ")

# ---- 2. Filtros -----------------------------------------------------------

filtros_vacios <- function() {
  list(
    comercios = character(), subcategorias = character(), marcas = character(),
    precio = NULL, ejecuciones = integer(),
    solo_promo = FALSE, solo_comparables = FALSE, busqueda = ""
  )
}

# Convierte la lista de filtros en un trozo de WHERE con marcadores "?" y la
# lista de parámetros en el mismo orden. Sobre la vista v_productos.
construir_filtro <- function(f = filtros_vacios()) {

  parte_in <- function(campo, valores) {
    if (length(valores) == 0) return(NULL)
    list(sql = sprintf("%s IN (%s)", campo, marcadores(length(valores))),
         params = as.list(valores))
  }

  palabras <- strsplit(tolower(sanitizar_texto(f$busqueda)), "\\s+")[[1]]
  palabras <- head(palabras[nzchar(palabras)], 5)
  partes_busqueda <- lapply(palabras, function(p) {
    list(sql = "titulo_norm LIKE ?", params = list(paste0("%", p, "%")))
  })

  partes <- c(
    list(
      parte_in("comercio", f$comercios),
      parte_in("subcategoria", f$subcategorias),
      parte_in("marca", toupper(f$marcas)),
      parte_in("id_ejecucion", as.integer(f$ejecuciones)),
      if (length(f$precio) == 2) {
        list(sql = "precio BETWEEN ? AND ?", params = list(f$precio[1], f$precio[2]))
      },
      if (isTRUE(f$solo_promo))       list(sql = "tiene_descuento = 1", params = list()),
      if (isTRUE(f$solo_comparables)) list(sql = "comparable = 1",      params = list())
    ),
    partes_busqueda
  )
  partes <- Filter(Negate(is.null), partes)

  list(
    sql    = paste(c("1 = 1", vapply(partes, `[[`, character(1), "sql")), collapse = " AND "),
    params = unlist(lapply(partes, `[[`, "params"), recursive = FALSE)
  )
}

# ---- 3. Opciones de los filtros -------------------------------------------

db_ejecuciones <- function(con, solo_con_datos = TRUE) {
  sql <- "SELECT id_ejecucion, fecha_consulta, modo, estado, n_obs, clave
          FROM ejecuciones
          WHERE (? = 0 OR n_obs > 0)
          ORDER BY id_ejecucion"
  d <- consultar(con, sql, list(as.integer(!solo_con_datos)))
  d$etiqueta <- etiquetas_ejecucion(d)
  d
}

# Etiqueta para el eje horizontal y los menús: la fecha de la ejecución.
# Si dos ejecuciones comparten fecha se añade su número para distinguirlas.
etiquetas_ejecucion <- function(d) {
  if (nrow(d) == 0) return(character())
  rep_fecha <- duplicated(d$fecha_consulta) | duplicated(d$fecha_consulta, fromLast = TRUE)
  ifelse(rep_fecha, paste0(d$fecha_consulta, " (ejec. ", d$id_ejecucion, ")"), d$fecha_consulta)
}

db_opciones <- function(con) {
  list(
    comercios     = consultar(con, "SELECT DISTINCT comercio FROM productos ORDER BY comercio")$comercio,
    subcategorias = consultar(con, "SELECT DISTINCT subcategoria FROM productos ORDER BY subcategoria")$subcategoria,
    marcas        = consultar(con, "SELECT DISTINCT marca FROM v_productos WHERE marca IS NOT NULL ORDER BY marca")$marca,
    precio        = unlist(consultar(con, "SELECT MIN(precio) AS minimo, MAX(precio) AS maximo FROM productos")),
    ejecuciones   = db_ejecuciones(con)
  )
}

# ---- 4. Tabla de productos ------------------------------------------------

db_productos <- function(con, f) {
  w <- construir_filtro(f)
  sql <- paste(
    "SELECT id_ejecucion, fecha_consulta, comercio, subcategoria, titulo, marca,
            contenido_total, unidad_medida, precio, precio_unitario, precio_previo,
            tiene_descuento, descuento_pct, disponibilidad, comparable,
            id_presentacion, pagina_consulta
     FROM v_productos WHERE", w$sql,
    "ORDER BY comercio, subcategoria, titulo"
  )
  consultar(con, sql, w$params)
}

# ---- 5. Indicadores (todos con SQL) ---------------------------------------

# Conteos, proporción de promociones y mediana del precio del conjunto filtrado.
db_indicadores <- function(con, f) {
  w <- construir_filtro(f)

  base <- consultar(con, paste(
    "SELECT COUNT(*) AS n_obs,
            COUNT(DISTINCT comercio || '|' || titulo_norm) AS n_productos,
            ROUND(100.0 * AVG(tiene_descuento), 1) AS pct_promocion,
            MIN(fecha_consulta) AS fecha_desde, MAX(fecha_consulta) AS fecha_hasta
     FROM v_productos WHERE", w$sql), w$params)

  # SQLite no tiene MEDIAN: se toma el valor central (o el promedio de los dos).
  mediana <- consultar(con, paste(
    "WITH f AS (SELECT precio FROM v_productos WHERE", w$sql, "),
          r AS (SELECT precio,
                       ROW_NUMBER() OVER (ORDER BY precio) AS rn,
                       COUNT(*) OVER () AS n FROM f)
     SELECT AVG(precio) AS mediana FROM r WHERE rn IN ((n + 1) / 2, (n + 2) / 2)"), w$params)

  base$mediana_precio <- mediana$mediana
  base
}

db_resumen_comercio <- function(con, f) {
  w <- construir_filtro(f)
  consultar(con, paste(
    "SELECT comercio,
            COUNT(*) AS observaciones,
            COUNT(DISTINCT titulo_norm) AS productos,
            ROUND(100.0 * AVG(tiene_descuento), 1) AS pct_promocion,
            ROUND(AVG(precio), 0) AS precio_promedio
     FROM v_productos WHERE", w$sql, "GROUP BY comercio ORDER BY comercio"), w$params)
}

db_mediana_subcategoria <- function(con, f) {
  w <- construir_filtro(f)
  consultar(con, paste(
    "WITH f AS (SELECT subcategoria, precio FROM v_productos WHERE", w$sql, "),
          r AS (SELECT subcategoria, precio,
                       ROW_NUMBER() OVER (PARTITION BY subcategoria ORDER BY precio) AS rn,
                       COUNT(*) OVER (PARTITION BY subcategoria) AS n FROM f)
     SELECT subcategoria, MAX(n) AS observaciones, AVG(precio) AS mediana_precio
     FROM r WHERE rn IN ((n + 1) / 2, (n + 2) / 2)
     GROUP BY subcategoria ORDER BY subcategoria"), w$params)
}

# Última ejecución con datos: fecha, estado y modo.
db_ultima_ejecucion <- function(con) {
  consultar(con, "SELECT id_ejecucion, fecha_consulta, estado, modo, n_obs
                  FROM ejecuciones WHERE n_obs > 0
                  ORDER BY id_ejecucion DESC LIMIT 1")
}

# Cuántos anuncios cambiaron de precio en una ejecución (vista v_cambios_precio).
db_n_cambios <- function(con, id_ejecucion) {
  consultar(con, "SELECT COUNT(*) AS n FROM v_cambios_precio WHERE id_ejecucion = ?",
            list(as.integer(id_ejecucion)))$n
}

# ---- 6. Comparables: ahorro, series y canasta -----------------------------

db_presentaciones <- function(con) {
  consultar(con, "SELECT id_presentacion, producto, contenido_total, unidad_medida, unidades_paquete
                  FROM presentaciones_comparables ORDER BY id_presentacion")
}

# Mínimo, máximo y ahorro por presentación en UNA ejecución.
# Con empates en el mínimo se listan todos los comercios.
db_ahorro_presentaciones <- function(con, id_ejecucion) {
  consultar(con,
    "WITH p AS (SELECT id_presentacion, producto, comercio, precio
                FROM v_comparables WHERE id_ejecucion = ?),
          e AS (SELECT id_presentacion, producto,
                       COUNT(*) AS n_comercios,
                       MIN(precio) AS precio_min, MAX(precio) AS precio_max
                FROM p GROUP BY id_presentacion, producto)
     SELECT e.*,
            (SELECT COUNT(*) FROM p
              WHERE p.id_presentacion = e.id_presentacion
                AND p.precio = e.precio_min) AS n_comercios_en_minimo,
            (SELECT GROUP_CONCAT(comercio, ', ') FROM
               (SELECT comercio FROM p
                 WHERE p.id_presentacion = e.id_presentacion
                   AND p.precio = e.precio_min ORDER BY comercio)) AS comercios_menor_precio,
            e.precio_max - e.precio_min AS ahorro_cop,
            ROUND(100.0 * (e.precio_max - e.precio_min) / e.precio_max, 1) AS ahorro_pct
     FROM e ORDER BY e.id_presentacion",
    list(as.integer(id_ejecucion)))
}

# Serie de un producto comparable a través de las ejecuciones.
db_serie_comparable <- function(con, id_presentacion) {
  consultar(con,
    "SELECT id_ejecucion, fecha_consulta, comercio, precio,
            precio_unitario, precio_por_unidad, contenido_total, unidad_medida,
            unidades_paquete, tiene_descuento
     FROM v_comparables WHERE id_presentacion = ?
     ORDER BY id_ejecucion, comercio",
    list(id_presentacion))
}

# Costo de la canasta completa (los 8 comparables, 1 unidad de cada uno) por
# comercio y ejecución. Solo se incluyen las ejecuciones en que el comercio
# tiene TODOS los productos: un total incompleto no se muestra.
db_serie_canasta <- function(con) {
  consultar(con,
    "SELECT id_ejecucion, fecha_consulta, comercio,
            COUNT(DISTINCT id_presentacion) AS n_productos, SUM(precio) AS total_cop
     FROM v_comparables
     GROUP BY id_ejecucion, fecha_consulta, comercio
     HAVING COUNT(DISTINCT id_presentacion) = (SELECT COUNT(*) FROM presentaciones_comparables)
     ORDER BY id_ejecucion, comercio")
}

# (id, cantidad) intercalados para el VALUES (?, ?), (?, ?)... de la canasta.
pares_sel <- function(ids, cantidades) {
  unlist(Map(list, ids, as.integer(cantidades)), recursive = FALSE, use.names = FALSE)
}

# Total de la canasta por comercio en una ejecución. total_cop es NA cuando al
# comercio le falta algún producto elegido.
db_canasta <- function(con, id_ejecucion, ids, cantidades) {
  n <- length(ids)
  stopifnot(n > 0, length(cantidades) == n)
  sql <- sprintf(
    "WITH sel(id_presentacion, cantidad) AS (VALUES %s),
          com AS (SELECT DISTINCT comercio FROM v_comparables),
          p AS (SELECT c.comercio, c.id_presentacion, c.precio, s.cantidad
                FROM v_comparables c JOIN sel s USING (id_presentacion)
                WHERE c.id_ejecucion = ?)
     SELECT com.comercio,
            COUNT(DISTINCT p.id_presentacion) AS n_encontrados,
            (SELECT COUNT(*) FROM sel) AS n_seleccionados,
            CASE WHEN COUNT(DISTINCT p.id_presentacion) = (SELECT COUNT(*) FROM sel)
                 THEN SUM(p.precio * p.cantidad) END AS total_cop
     FROM com LEFT JOIN p ON p.comercio = com.comercio
     GROUP BY com.comercio ORDER BY com.comercio",
    paste(rep("(?, ?)", n), collapse = ", "))
  params <- c(pares_sel(ids, cantidades), list(as.integer(id_ejecucion)))
  consultar(con, sql, params)
}

# Comprar cada producto donde es más barato: una fila por producto elegido.
# Si un producto no tiene precio en ninguna parte, simplemente no aparece
# (resumen_canasta() lo detecta y no calcula el total).
db_canasta_mixta <- function(con, id_ejecucion, ids, cantidades) {
  n <- length(ids)
  stopifnot(n > 0, length(cantidades) == n)
  sql <- sprintf(
    "WITH sel(id_presentacion, cantidad) AS (VALUES %s),
          p AS (SELECT c.comercio, c.id_presentacion, c.producto, c.precio, s.cantidad
                FROM v_comparables c JOIN sel s USING (id_presentacion)
                WHERE c.id_ejecucion = ?),
          m AS (SELECT id_presentacion, MIN(precio) AS precio_min FROM p GROUP BY id_presentacion)
     SELECT m.id_presentacion,
            (SELECT MIN(producto) FROM p WHERE p.id_presentacion = m.id_presentacion) AS producto,
            (SELECT MIN(cantidad) FROM p WHERE p.id_presentacion = m.id_presentacion) AS cantidad,
            m.precio_min,
            (SELECT GROUP_CONCAT(comercio, ', ') FROM
               (SELECT comercio FROM p
                 WHERE p.id_presentacion = m.id_presentacion
                   AND p.precio = m.precio_min ORDER BY comercio)) AS comercios_menor_precio,
            m.precio_min * (SELECT MIN(cantidad) FROM p WHERE p.id_presentacion = m.id_presentacion) AS subtotal_cop
     FROM m ORDER BY m.id_presentacion",
    paste(rep("(?, ?)", n), collapse = ", "))
  params <- c(pares_sel(ids, cantidades), list(as.integer(id_ejecucion)))
  consultar(con, sql, params)
}

# Une los totales por comercio y la compra mixta.
#  - mejor_unico: el comercio completo más barato (NA si ninguno es completo)
#  - mixto: costo comprando cada producto donde es más barato (NA si falta alguno)
#  - ahorro: mejor_unico - mixto
resumen_canasta <- function(totales, mixta, n_seleccionados) {
  completos <- totales[!is.na(totales$total_cop), , drop = FALSE]
  mejor_unico <- if (nrow(completos) > 0) min(completos$total_cop) else NA_real_
  comercio_unico <- if (nrow(completos) > 0) {
    paste(completos$comercio[completos$total_cop == mejor_unico], collapse = ", ")
  } else NA_character_
  mixto <- if (nrow(mixta) == n_seleccionados) sum(mixta$subtotal_cop) else NA_real_
  ahorro <- if (!is.na(mejor_unico) && !is.na(mixto)) mejor_unico - mixto else NA_real_
  list(
    mejor_unico = mejor_unico, comercio_unico = comercio_unico,
    mixto = mixto, ahorro_cop = ahorro,
    ahorro_pct = if (!is.na(ahorro) && mejor_unico > 0) round(100 * ahorro / mejor_unico, 1) else NA_real_
  )
}

# ---- 7. Cambios de precio entre dos ejecuciones ---------------------------

# Compara el MISMO anuncio (comercio + título) en dos ejecuciones:
# subió, bajó, igual, nuevo (solo en la segunda) o no observado (solo en la
# primera). "No observado" NO significa agotado ni retirado.
# umbral_pct: variaciones absolutas >= umbral se marcan como grandes.
db_cambios <- function(con, id_a, id_b, umbral_pct = 10, comercios = character()) {
  filtro_com <- if (length(comercios) > 0) {
    sprintf("WHERE comercio IN (%s)", marcadores(length(comercios)))
  } else ""

  sql <- sprintf(
    "WITH a AS (SELECT comercio, titulo_norm, MIN(titulo) AS titulo, MIN(precio) AS precio
                FROM v_productos WHERE id_ejecucion = ? GROUP BY comercio, titulo_norm),
          b AS (SELECT comercio, titulo_norm, MIN(titulo) AS titulo, MIN(precio) AS precio
                FROM v_productos WHERE id_ejecucion = ? GROUP BY comercio, titulo_norm),
          j AS (
            SELECT a.comercio, b.titulo, a.precio AS precio_a, b.precio AS precio_b
              FROM a JOIN b ON a.comercio = b.comercio AND a.titulo_norm = b.titulo_norm
            UNION ALL
            SELECT b.comercio, b.titulo, NULL, b.precio FROM b
             WHERE NOT EXISTS (SELECT 1 FROM a WHERE a.comercio = b.comercio AND a.titulo_norm = b.titulo_norm)
            UNION ALL
            SELECT a.comercio, a.titulo, a.precio, NULL FROM a
             WHERE NOT EXISTS (SELECT 1 FROM b WHERE b.comercio = a.comercio AND b.titulo_norm = a.titulo_norm)
          ),
          r AS (
            SELECT comercio, titulo, precio_a, precio_b,
                   precio_b - precio_a AS cambio_cop,
                   ROUND(100.0 * (precio_b - precio_a) / precio_a, 1) AS cambio_pct,
                   CASE WHEN precio_a IS NULL THEN 'nuevo'
                        WHEN precio_b IS NULL THEN 'no observado'
                        WHEN precio_b > precio_a THEN 'subió'
                        WHEN precio_b < precio_a THEN 'bajó'
                        ELSE 'igual' END AS estado
            FROM j)
     SELECT r.*,
            CASE WHEN cambio_pct IS NOT NULL AND ABS(cambio_pct) >= ? THEN 1 ELSE 0 END AS variacion_grande
     FROM r %s
     ORDER BY ABS(COALESCE(cambio_pct, 0)) DESC, comercio, titulo",
    filtro_com)
  consultar(con, sql, c(list(as.integer(id_a), as.integer(id_b), as.numeric(umbral_pct)),
                        as.list(comercios)))
}
