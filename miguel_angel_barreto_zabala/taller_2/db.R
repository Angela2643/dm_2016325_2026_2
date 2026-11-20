# db.R -- capa de acceso a datos (Taller 2, Modulo 3).
# La interfaz NO contiene SQL: llama a estas funciones, que reciben la conexion y los filtros como
# argumentos y devuelven tablas. Todo valor ingresado por el usuario viaja como PARAMETRO (?);
# solo los marcadores "?" se insertan en el texto de la consulta. Los filtros, indicadores y
# agregaciones se calculan con SQL sobre SQLite (las vistas se crean en scraper.R: crear_esquema()).

suppressPackageStartupMessages({ library(DBI); library(RSQLite); library(dplyr); library(tibble) })

LONGITUD_MAX_BUSQUEDA <- 60L

# ------------------------------------------------------------------ conexion
abrir_db <- function(db = "comparador_precios.sqlite") {
  con <- dbConnect(SQLite(), db)
  invisible(dbExecute(con, "PRAGMA busy_timeout = 5000"))   # espera si otro proceso esta escribiendo
  con
}
cerrar_db <- function(con) {
  if (!is.null(con) && dbIsValid(con)) dbDisconnect(con)
  invisible(NULL)
}

marcadores <- function(n) paste(rep("?", n), collapse = ",")

# Validacion de texto libre (busqueda): longitud maxima y caracteres permitidos. Sin '%', '_' ni
# comillas, asi el texto no puede alterar el patron LIKE ni la consulta.
validar_busqueda <- function(x) {
  x <- if (is.null(x) || length(x) == 0 || is.na(x[1])) "" else trimws(as.character(x[1]))
  if (nchar(x) > LONGITUD_MAX_BUSQUEDA) x <- substr(x, 1, LONGITUD_MAX_BUSQUEDA)
  gsub("[^\\p{L}\\p{N} .,+/-]", "", x, perl = TRUE)
}

# --------------------------------------------------------------- corridas
# Corridas completas (los tres comercios), una por dia: la ultima de cada dia. Las mas nuevas primero.
corridas_disponibles <- function(con) {
  d <- dbGetQuery(con, "SELECT corrida, inicio FROM v_corridas_completas ORDER BY corrida DESC")
  d$etiqueta <- paste0(substr(d$inicio, 1, 10), " ", substr(d$inicio, 12, 16), " (", d$corrida, ")")
  d
}

ultima_ejecucion <- function(con) {
  dbGetQuery(con, "
    SELECT c.nombre AS comercio, e.inicio, e.estado, e.n_registros, e.total_sitio, e.detalle
    FROM ejecuciones e JOIN comercios c ON c.id = e.comercio_id
    WHERE e.id = (SELECT e2.id FROM ejecuciones e2 WHERE e2.comercio_id = e.comercio_id
                  ORDER BY e2.inicio DESC LIMIT 1)
    ORDER BY c.nombre")
}

# ---------------------------------------------------------------- filtros
opciones_filtros <- function(con) {
  list(
    comercios     = dbGetQuery(con, "SELECT nombre FROM comercios ORDER BY nombre")$nombre,
    subcategorias = dbGetQuery(con, "SELECT DISTINCT subcategoria FROM anuncios
                                     WHERE incluido = 1 AND subcategoria IS NOT NULL ORDER BY 1")$subcategoria,
    marcas        = dbGetQuery(con, "SELECT DISTINCT marca_estandar FROM anuncios
                                     WHERE incluido = 1 AND marca_estandar IS NOT NULL ORDER BY 1")$marca_estandar,
    precio        = unlist(dbGetQuery(con, "SELECT MIN(precio) AS min, MAX(precio) AS max FROM v_precio_por_corrida")),
    corridas      = corridas_disponibles(con),
    productos     = dbGetQuery(con, "SELECT id, nombre FROM productos ORDER BY nombre"))
}

# Productos de una corrida con los filtros del panel lateral. Devuelve una fila por anuncio.
productos_filtrados <- function(con, corrida, comercios = NULL, subcategorias = NULL, marcas = NULL,
                                pmin = NULL, pmax = NULL, solo_promo = FALSE,
                                solo_comparables = FALSE, texto = "") {
  if (is.null(corrida) || length(corrida) == 0 || is.na(corrida)) return(tibble())
  donde <- c("a.incluido = 1", "p.corrida = ?")
  par   <- list(corrida)
  if (length(comercios)) {
    donde <- c(donde, sprintf("c.nombre IN (%s)", marcadores(length(comercios)))); par <- c(par, as.list(comercios))
  }
  if (length(subcategorias)) {
    donde <- c(donde, sprintf("a.subcategoria IN (%s)", marcadores(length(subcategorias)))); par <- c(par, as.list(subcategorias))
  }
  if (length(marcas)) {
    donde <- c(donde, sprintf("a.marca_estandar IN (%s)", marcadores(length(marcas)))); par <- c(par, as.list(marcas))
  }
  if (!is.null(pmin) && !is.na(pmin)) { donde <- c(donde, "p.precio >= ?"); par <- c(par, list(as.numeric(pmin))) }
  if (!is.null(pmax) && !is.na(pmax)) { donde <- c(donde, "p.precio <= ?"); par <- c(par, list(as.numeric(pmax))) }
  if (isTRUE(solo_promo))       donde <- c(donde, "p.promocion = 1")
  if (isTRUE(solo_comparables)) donde <- c(donde, "a.comparable = 1")
  texto <- validar_busqueda(texto)
  if (nzchar(texto)) {
    donde <- c(donde, "(a.nombre_original LIKE ? OR a.descripcion_original LIKE ?)")
    par <- c(par, list(paste0("%", texto, "%"), paste0("%", texto, "%")))
  }
  sql <- paste(
    "SELECT c.nombre AS comercio, a.nombre_original AS producto, a.marca_estandar AS marca,
            a.subcategoria, a.contenido_valor, a.contenido_unidad,
            p.precio, p.precio_lista, p.promocion,
            CASE WHEN a.contenido_valor > 0 THEN p.precio / a.contenido_valor END AS precio_unitario,
            p.estado_disponibilidad AS disponibilidad, p.fecha_consulta, a.comparable, a.url
     FROM v_precio_por_corrida p
     JOIN anuncios a  ON a.id = p.anuncio_id
     JOIN comercios c ON c.id = a.comercio_id
     WHERE", paste(donde, collapse = " AND "), "ORDER BY c.nombre, a.nombre_original")
  d <- dbGetQuery(con, sql, params = par)
  d$presentacion <- ifelse(is.na(d$contenido_valor), NA_character_,
                           paste(format(d$contenido_valor, trim = TRUE, scientific = FALSE), d$contenido_unidad))
  d
}

# -------------------------------------------------------------- indicadores
# Ahorro entre comercios para cada presentacion comparable (maneja empates: GROUP_CONCAT).
ahorro_comparables <- function(con, corrida) {
  dbGetQuery(con, "
    WITH p AS (SELECT * FROM v_comparables WHERE corrida = ?),
         s AS (SELECT producto_id, producto, MIN(precio) AS pmin, MAX(precio) AS pmax,
                      COUNT(DISTINCT comercio) AS n_comercios
               FROM p GROUP BY producto_id HAVING COUNT(DISTINCT comercio) >= 2)
    SELECT s.producto, s.pmin, s.pmax, s.pmax - s.pmin AS ahorro_cop,
           ROUND(100.0 * (s.pmax - s.pmin) / s.pmax, 1) AS ahorro_pct, s.n_comercios,
           (SELECT GROUP_CONCAT(comercio, ' / ') FROM p WHERE p.producto_id = s.producto_id AND p.precio = s.pmin) AS mas_barato,
           (SELECT GROUP_CONCAT(comercio, ' / ') FROM p WHERE p.producto_id = s.producto_id AND p.precio = s.pmax) AS mas_caro
    FROM s ORDER BY ahorro_pct DESC, ahorro_cop DESC", params = list(corrida))
}

mediana_por_subcategoria <- function(con, corrida) {
  dbGetQuery(con, "
    WITH x AS (SELECT a.subcategoria AS subcategoria, p.precio,
                      ROW_NUMBER() OVER (PARTITION BY a.subcategoria ORDER BY p.precio) AS rn,
                      COUNT(*) OVER (PARTITION BY a.subcategoria) AS n
               FROM v_precio_por_corrida p JOIN anuncios a ON a.id = p.anuncio_id
               WHERE a.incluido = 1 AND p.corrida = ?)
    SELECT subcategoria, AVG(precio) AS mediana, MAX(n) AS productos
    FROM x WHERE rn IN ((n + 1) / 2, (n + 2) / 2) GROUP BY subcategoria ORDER BY subcategoria",
    params = list(corrida))
}

# Indicadores (todos con SQL) de la corrida elegida.
indicadores <- function(con, corrida) {
  q <- function(sql, par = NULL) {
    if (is.null(par) || length(par) == 0) dbGetQuery(con, sql)
    else dbGetQuery(con, sql, params = par)
  }
  por_comercio <- q("
    SELECT c.nombre AS comercio, COUNT(*) AS productos, SUM(p.promocion) AS en_promocion
    FROM v_precio_por_corrida p JOIN anuncios a ON a.id = p.anuncio_id
    JOIN comercios c ON c.id = a.comercio_id
    WHERE a.incluido = 1 AND p.corrida = ? GROUP BY c.nombre ORDER BY c.nombre", list(corrida))
  mediana <- q("
    WITH x AS (SELECT p.precio, ROW_NUMBER() OVER (ORDER BY p.precio) AS rn, COUNT(*) OVER () AS n
               FROM v_precio_por_corrida p JOIN anuncios a ON a.id = p.anuncio_id
               WHERE a.incluido = 1 AND p.corrida = ?)
    SELECT AVG(precio) AS mediana FROM x WHERE rn IN ((n + 1) / 2, (n + 2) / 2)", list(corrida))$mediana
  ahorro <- ahorro_comparables(con, corrida)
  list(
    productos        = sum(por_comercio$productos),
    por_comercio     = por_comercio,
    observaciones    = q("SELECT COUNT(*) AS n FROM observaciones WHERE descartada = 0")$n,
    pct_promocion    = if (sum(por_comercio$productos) > 0)
                         round(100 * sum(por_comercio$en_promocion) / sum(por_comercio$productos), 1) else NA_real_,
    mediana          = mediana,
    ahorro_max_pct   = if (nrow(ahorro)) ahorro$ahorro_pct[1] else NA_real_,
    ahorro_max_prod  = if (nrow(ahorro)) ahorro$producto[1] else NA_character_,
    cambios_ultima   = q("SELECT COUNT(*) AS n FROM v_cambios_precio WHERE direccion <> 'igual'")$n,
    ultima_ejecucion = ultima_ejecucion(con))
}

# ----------------------------------------------------------------- graficos
evolucion_precio <- function(con, producto_id) {
  dbGetQuery(con, "
    SELECT substr(v.fecha_consulta, 1, 10) AS fecha, v.fecha_consulta, v.corrida,
           v.comercio, v.precio
    FROM v_comparables v JOIN v_corridas_completas cc ON cc.corrida = v.corrida
    WHERE v.producto_id = ? ORDER BY v.fecha_consulta", params = list(producto_id))
}

unidades_comparables <- function(con, corrida) {
  dbGetQuery(con, "
    SELECT DISTINCT contenido_unidad AS unidad
    FROM v_comparables
    WHERE corrida = ? AND contenido_unidad IS NOT NULL
    ORDER BY contenido_unidad", params = list(corrida))$unidad
}

precio_unitario_comparables <- function(con, corrida, unidad = "mL") {
  dbGetQuery(con, "
    SELECT producto, comercio, precio, precio_unitario, contenido_valor, contenido_unidad AS unidad
    FROM v_comparables WHERE corrida = ? AND contenido_unidad = ? ORDER BY producto, comercio",
    params = list(corrida, unidad))
}

distribucion_precios <- function(con, corrida) {
  dbGetQuery(con, "
    SELECT c.nombre AS comercio, p.precio
    FROM v_precio_por_corrida p JOIN anuncios a ON a.id = p.anuncio_id
    JOIN comercios c ON c.id = a.comercio_id
    WHERE a.incluido = 1 AND p.corrida = ? ORDER BY c.nombre", params = list(corrida))
}

# ---------------------------------------------------------- cambios de precio
# Compara dos corridas sobre el MISMO anuncio en el MISMO comercio. Tipos: subio, bajo, igual,
# nuevo (solo esta en la corrida nueva) y 'dejo de observarse' (solo en la anterior).
cambios_precio <- function(con, corrida_anterior, corrida_nueva, umbral_pct = 5) {
  dbGetQuery(con, "
    WITH a AS (SELECT anuncio_id, precio FROM v_precio_por_corrida WHERE corrida = ?),
         b AS (SELECT anuncio_id, precio FROM v_precio_por_corrida WHERE corrida = ?)
    SELECT c.nombre AS comercio, an.nombre_original AS producto, an.marca_estandar AS marca,
           a.precio AS precio_anterior, b.precio AS precio_nuevo,
           b.precio - a.precio AS cambio_cop,
           ROUND(100.0 * (b.precio - a.precio) / a.precio, 1) AS cambio_pct,
           CASE WHEN a.precio IS NULL THEN 'nuevo'
                WHEN b.precio IS NULL THEN 'dejo de observarse'
                WHEN b.precio > a.precio THEN 'subio'
                WHEN b.precio < a.precio THEN 'bajo' ELSE 'igual' END AS tipo,
           CASE WHEN a.precio IS NOT NULL AND b.precio IS NOT NULL
                  AND ABS(100.0 * (b.precio - a.precio) / a.precio) >= ? THEN 1 ELSE 0 END AS variacion_grande,
           an.url
    FROM (SELECT anuncio_id FROM a UNION SELECT anuncio_id FROM b) k
    LEFT JOIN a ON a.anuncio_id = k.anuncio_id
    LEFT JOIN b ON b.anuncio_id = k.anuncio_id
    JOIN anuncios an ON an.id = k.anuncio_id
    JOIN comercios c ON c.id = an.comercio_id
    WHERE an.incluido = 1
    ORDER BY ABS(COALESCE(cambio_pct, 0)) DESC, c.nombre, an.nombre_original",
    params = list(corrida_anterior, corrida_nueva, as.numeric(umbral_pct)))
}

# Resumen por comercio de la ultima corrida frente a la anterior completa (para el boton de
# actualizacion): productos recolectados, nuevos, con cambio de precio y no observados.
resumen_actualizacion <- function(con) {
  nueva <- dbGetQuery(con, "SELECT MAX(substr(id, 1, 15)) AS corrida FROM ejecuciones")$corrida
  if (is.na(nueva)) return(tibble())
  previa <- dbGetQuery(con, "SELECT MAX(corrida) AS corrida FROM v_corridas_completas WHERE corrida < ?",
                       params = list(nueva))$corrida
  if (is.na(previa)) return(tibble())
  cambios_precio(con, previa, nueva, 0) |>
    group_by(comercio) |>
    summarise(recolectados   = sum(tipo != "dejo de observarse"),
              nuevos         = sum(tipo == "nuevo"),
              cambio_precio  = sum(tipo %in% c("subio", "bajo")),
              no_observados  = sum(tipo == "dejo de observarse"), .groups = "drop")
}

# ------------------------------------------------------------------ canasta
# 'items' = data.frame(producto_id, cantidad). Siempre sobre los precios de UNA misma corrida.
items_sql <- function(items) {
  list(cte = sprintf("items(producto_id, cantidad) AS (VALUES %s)",
                     paste(rep("(?, ?)", nrow(items)), collapse = ", ")),
       par = as.list(as.vector(rbind(as.integer(items$producto_id), as.numeric(items$cantidad)))))
}

# Costo de la canasta en cada comercio. El total es NA si al comercio le falta algun producto.
canasta_por_comercio <- function(con, items, corrida) {
  if (nrow(items) == 0) return(tibble())
  it <- items_sql(items)
  dbGetQuery(con, paste("
    WITH", it$cte, ",
    p AS (SELECT comercio, producto_id, precio FROM v_comparables WHERE corrida = ?),
    por_com AS (
      SELECT c.nombre AS comercio, COUNT(DISTINCT p.producto_id) AS tiene, SUM(p.precio * i.cantidad) AS total
      FROM comercios c LEFT JOIN items i ON 1 = 1
      LEFT JOIN p ON p.comercio = c.nombre AND p.producto_id = i.producto_id
      GROUP BY c.nombre)
    SELECT comercio, tiene, (SELECT COUNT(*) FROM items) AS necesarios,
           CASE WHEN tiene = (SELECT COUNT(*) FROM items) THEN total END AS total
    FROM por_com ORDER BY comercio"), params = c(it$par, list(corrida)))
}

# Productos que le faltan a cada comercio (para avisar en vez de mostrar un total incompleto).
canasta_faltantes <- function(con, items, corrida) {
  if (nrow(items) == 0) return(tibble())
  it <- items_sql(items)
  dbGetQuery(con, paste("
    WITH", it$cte, ",
    p AS (SELECT comercio, producto_id, precio FROM v_comparables WHERE corrida = ?)
    SELECT c.nombre AS comercio, pr.nombre AS producto_faltante
    FROM comercios c JOIN items i ON 1 = 1 JOIN productos pr ON pr.id = i.producto_id
    LEFT JOIN p ON p.comercio = c.nombre AND p.producto_id = i.producto_id
    WHERE p.precio IS NULL ORDER BY c.nombre, pr.nombre"), params = c(it$par, list(corrida)))
}

# Comprar cada producto donde es mas barato (con empates) y costo minimo total.
canasta_minimo <- function(con, items, corrida) {
  if (nrow(items) == 0) return(tibble())
  it <- items_sql(items)
  dbGetQuery(con, paste("
    WITH", it$cte, ",
    p AS (SELECT comercio, producto_id, precio FROM v_comparables WHERE corrida = ?),
    m AS (SELECT producto_id, MIN(precio) AS pmin FROM p GROUP BY producto_id)
    SELECT pr.nombre AS producto, i.cantidad, m.pmin AS precio_minimo,
           GROUP_CONCAT(p.comercio, ' / ') AS comercio_mas_barato, m.pmin * i.cantidad AS subtotal
    FROM items i JOIN productos pr ON pr.id = i.producto_id
    LEFT JOIN m ON m.producto_id = i.producto_id
    LEFT JOIN p ON p.producto_id = i.producto_id AND p.precio = m.pmin
    GROUP BY i.producto_id ORDER BY pr.nombre"), params = c(it$par, list(corrida)))
}

# Resultado completo de la canasta: totales por comercio, compra minima y ahorro frente a comprar
# todo en el comercio completo mas barato. Si algun producto no tiene precio en ningun comercio,
# no se calcula el minimo.
resultado_canasta <- function(con, items, corrida) {
  por_com  <- canasta_por_comercio(con, items, corrida)
  faltan   <- canasta_faltantes(con, items, corrida)
  minimo   <- canasta_minimo(con, items, corrida)
  completos <- por_com[!is.na(por_com$total), ]
  min_total <- if (nrow(minimo) && !anyNA(minimo$subtotal)) sum(minimo$subtotal) else NA_real_
  mejor_unico <- if (nrow(completos)) min(completos$total) else NA_real_
  list(por_comercio = por_com, faltantes = faltan, minimo = minimo,
       costo_minimo = min_total, mejor_comercio_unico = mejor_unico,
       ahorro_cop = if (!is.na(min_total) && !is.na(mejor_unico)) mejor_unico - min_total else NA_real_)
}
