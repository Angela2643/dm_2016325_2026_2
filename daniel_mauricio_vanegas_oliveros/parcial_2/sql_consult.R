# sql_consult.R - Arma y actualiza productos.sqlite.
# (Módulos 1 y 2: datos, validación, ejecuciones y actualización.)
#
# v2.0 - Taller 2.
# Este archivo toma lo que entrega scraper.R (tablas extraídas de las copias de
# raw/), lo valida y lo deja listo para el análisis en productos.sqlite:
#   ejecuciones, ejecuciones_comercio, productos, presentaciones_comparables,
#   rechazados, correcciones y las vistas v_productos, v_ultimo_precio,
#   v_comparables y v_cambios_precio.
#
# Uso como script (desde taller_2/):
#   Rscript sql_consult.R
# Crea la base si no existe, importa la lectura del Taller 1 (10 de octubre,
# desde consultas_iniciales.db) y procesa las copias de raw/ que todavía no
# estén en la base (por ejemplo las "...2.html" de hoy).
#
# Dentro de la app solo se cargan las funciones (options(taller2.ejecutar = FALSE)).

# ---- 1. Paquetes y módulos ------------------------------------------------

library(DBI)
library(RSQLite)
library(dplyr)
library(tibble)

# Carga un módulo sin disparar su ejecución automática como script.
cargar_modulo <- function(archivo) {
  op <- options(taller2.ejecutar = FALSE)
  on.exit(options(op))
  source(archivo, encoding = "UTF-8")
}

if (!exists("validar_observaciones")) cargar_modulo("validacion.R")
if (!exists("recolectar_comercio"))   cargar_modulo("scraper.R")
if (!exists("abrir_con"))             cargar_modulo("db.R")

# ---- 2. Catálogo de presentaciones comparables ----------------------------

# Las ocho presentaciones del Taller 1, ahora como reglas con parámetros (en
# lugar de texto SQL pegado). NA = la regla no usa ese campo.
#   marca_like / marca_like_alt: patrones LIKE sobre la marca
#   gramos / unidades: igualdad exacta
#   titulo_like / titulo_not_like: patrones LIKE sobre el título
# Cambios frente al Taller 1 (también registrados en la tabla correcciones):
#   P07: se cambió "precio < 4000" por "unidades = 1". El tope de precio
#        servía para excluir el paquete de 5 unidades de Jumbo, pero dejaba
#        de funcionar si el precio subía.
#   P03 y P04: se añadió una condición sobre el título para no confundirlos
#        con otras presentaciones del mismo peso.
CATALOGO <- tibble::tribble(
  ~id_presentacion, ~producto,                              ~contenido_total, ~unidades_paquete, ~marca_like,    ~marca_like_alt,  ~gramos, ~unidades, ~titulo_like,    ~titulo_not_like,
  "P01", "Maní La Especial con arándanos 450 g",            450,              1,                  "%especial%",   NA_character_,    450,     NA_real_,  NA_character_,  NA_character_,
  "P02", "Cereal Zucaritas 610 g",                          610,              1,                  "%zuca%",       NA_character_,    610,     NA_real_,  NA_character_,  NA_character_,
  "P03", "Cereal Choco Krispis 570 g",                      570,              1,                  "%choco%",      NA_character_,    570,     NA_real_,  "%krispis%",    NA_character_,
  "P04", "Corn Flakes Kellogg's 410 g",                     410,              1,                  "%kellogg%",    NA_character_,    410,     NA_real_,  "%corn flakes%",NA_character_,
  "P05", "Froot Loops 450 g",                               450,              1,                  "%froot%",      NA_character_,    450,     NA_real_,  NA_character_,  NA_character_,
  "P06", "Cereal Flips chocolate 400 g",                    400,              1,                  "%flips%",      NA_character_,    400,     NA_real_,  "%choco%",      NA_character_,
  "P07", "Ponqué Chocoramo tajada 65 g",                    65,               1,                  "%chocoramo%",  "%chocorramo%",   65,      1,         "%ponqu%",      NA_character_,
  "P08", "Gansito x6 (222 g)",                              222,              6,                  "%gansito%",    NA_character_,    NA_real_, 6,        NA_character_,  "%zombie%"
)
CATALOGO$unidad_medida <- "g"

# ---- 3. Esquema de la base ------------------------------------------------

DDL <- c(
  "CREATE TABLE IF NOT EXISTS ejecuciones (
     id_ejecucion   INTEGER PRIMARY KEY AUTOINCREMENT,
     clave TEXT NOT NULL UNIQUE,
     fecha_consulta TEXT NOT NULL,
     inicio TEXT,
     fin TEXT,
     modo TEXT NOT NULL CHECK (modo IN ('online', 'offline', 'importada')),
     estado TEXT NOT NULL CHECK (estado IN ('completa', 'parcial', 'fallida')),
     sufijo_raw TEXT,
     n_obs INTEGER NOT NULL DEFAULT 0,
     nota TEXT
   )",

  "CREATE TABLE IF NOT EXISTS presentaciones_comparables (
     id_presentacion TEXT PRIMARY KEY,
     producto TEXT NOT NULL,
     contenido_total REAL NOT NULL,
     unidad_medida TEXT NOT NULL CHECK (unidad_medida IN ('g', 'mL', 'unidad')),
     unidades_paquete REAL NOT NULL DEFAULT 1,
     marca_like TEXT,
     marca_like_alt TEXT,
     gramos REAL,
     unidades REAL,
     titulo_like TEXT,
     titulo_not_like TEXT
   )",

  "CREATE TABLE IF NOT EXISTS productos (
     id_obs INTEGER PRIMARY KEY AUTOINCREMENT,
     id_ejecucion INTEGER NOT NULL REFERENCES ejecuciones (id_ejecucion),
     fecha_consulta TEXT NOT NULL,
     hora_consulta TEXT NOT NULL,
     comercio TEXT NOT NULL,
     subcategoria TEXT NOT NULL,
     titulo TEXT NOT NULL,
     titulo_norm TEXT NOT NULL,
     marca_producto TEXT,
     precio_texto TEXT,
     precio REAL NOT NULL CHECK (precio > 0),
     precio_previo_texto TEXT,
     precio_previo REAL,
     tiene_descuento INTEGER NOT NULL DEFAULT 0 CHECK (tiene_descuento IN (0, 1)),
     descuento_pct REAL,
     gramos REAL,
     unidades REAL,
     contenido_total REAL,
     unidad_medida TEXT CHECK (unidad_medida IN ('g', 'mL', 'unidad')),
     disponibilidad TEXT CHECK (disponibilidad IN ('disponible', 'agotado')),
     pagina_consulta TEXT NOT NULL,
     archivo_raw TEXT,
     comparable INTEGER NOT NULL DEFAULT 0 CHECK (comparable IN (0, 1)),
     id_presentacion     TEXT REFERENCES presentaciones_comparables (id_presentacion),
     UNIQUE (id_ejecucion, comercio, subcategoria, titulo_norm)
   )",

  "CREATE TABLE IF NOT EXISTS ejecuciones_comercio (
     id_ejecucion INTEGER NOT NULL REFERENCES ejecuciones (id_ejecucion),
     comercio TEXT NOT NULL,
     estado TEXT NOT NULL CHECK (estado IN ('completa', 'parcial', 'fallida')),
     n_recolectados INTEGER,
     n_insertados INTEGER,
     n_rechazados INTEGER,
     motivo TEXT,
     PRIMARY KEY (id_ejecucion, comercio)
   )",

  "CREATE TABLE IF NOT EXISTS rechazados (
     id_rechazo INTEGER PRIMARY KEY AUTOINCREMENT,
     id_ejecucion INTEGER NOT NULL REFERENCES ejecuciones (id_ejecucion),
     comercio TEXT,
     subcategoria TEXT,
     titulo TEXT,
     precio_texto TEXT,
     motivo TEXT NOT NULL,
     fecha_registro TEXT NOT NULL
   )",

  "CREATE TABLE IF NOT EXISTS correcciones (
     id_correccion INTEGER PRIMARY KEY AUTOINCREMENT,
     fecha TEXT NOT NULL,
     tabla TEXT NOT NULL,
     registro TEXT NOT NULL,
     campo TEXT NOT NULL,
     valor_anterior TEXT,
     valor_nuevo TEXT,
     motivo TEXT NOT NULL
   )",

  # Índices sobre las columnas que usan los filtros de la app.
  "CREATE INDEX IF NOT EXISTS ix_prod_ejecucion ON productos (id_ejecucion)",
  "CREATE INDEX IF NOT EXISTS ix_prod_comercio ON productos (comercio)",
  "CREATE INDEX IF NOT EXISTS ix_prod_subcat ON productos (subcategoria)",
  "CREATE INDEX IF NOT EXISTS ix_prod_precio ON productos (precio)",
  "CREATE INDEX IF NOT EXISTS ix_prod_marca ON productos (UPPER(TRIM(marca_producto)))",
  "CREATE INDEX IF NOT EXISTS ix_prod_anuncio ON productos (comercio, titulo_norm, id_ejecucion)",
  "CREATE INDEX IF NOT EXISTS ix_prod_comparable ON productos (id_presentacion, comercio, id_ejecucion)",
  # Un comercio no puede tener dos observaciones de la misma presentación en una ejecución.
  "CREATE UNIQUE INDEX IF NOT EXISTS ux_comparable_ejecucion
     ON productos (id_ejecucion, comercio, id_presentacion) WHERE id_presentacion IS NOT NULL"
)

VISTAS <- list(

  # Todas las observaciones con la fecha de su ejecución. Base de los filtros.
  v_productos =
    "CREATE VIEW v_productos AS
     SELECT p.id_obs, p.id_ejecucion, e.fecha_consulta, p.hora_consulta,
            p.comercio, p.subcategoria, p.titulo, p.titulo_norm,
            UPPER(TRIM(p.marca_producto)) AS marca,
            p.precio, p.precio_previo, p.tiene_descuento, p.descuento_pct,
            p.contenido_total, p.unidad_medida,
            CASE WHEN p.contenido_total > 0 THEN p.precio / p.contenido_total END AS precio_unitario,
            p.disponibilidad, p.comparable, p.id_presentacion,
            p.pagina_consulta, p.archivo_raw
     FROM productos p JOIN ejecuciones e USING (id_ejecucion)",

  # El precio más reciente de cada anuncio (comercio + título).
  v_ultimo_precio =
    "CREATE VIEW v_ultimo_precio AS
     SELECT * FROM (
       SELECT v.*, ROW_NUMBER() OVER (
                PARTITION BY v.comercio, v.titulo_norm
                ORDER BY v.id_ejecucion DESC, v.id_obs) AS rn
       FROM v_productos v)
     WHERE rn = 1",

  # Las presentaciones comparables con su precio unitario (COP por g, o por
  # unidad del paquete). El contenido sale del catálogo, ya normalizado.
  v_comparables =
    "CREATE VIEW v_comparables AS
     SELECT p.id_obs, p.id_ejecucion, e.fecha_consulta, p.hora_consulta,
            p.comercio, c.id_presentacion, c.producto, p.titulo,
            p.precio, p.precio_previo, p.tiene_descuento, p.descuento_pct,
            c.contenido_total, c.unidad_medida, c.unidades_paquete,
            p.precio / c.contenido_total  AS precio_unitario,
            p.precio / c.unidades_paquete AS precio_por_unidad
     FROM productos p
       JOIN presentaciones_comparables c USING (id_presentacion)
       JOIN ejecuciones e USING (id_ejecucion)
     WHERE p.comparable = 1",

  # Cambios de precio de un anuncio frente a su observación anterior.
  v_cambios_precio =
    "CREATE VIEW v_cambios_precio AS
     WITH a AS (
       SELECT id_ejecucion, fecha_consulta, comercio, titulo_norm,
              MIN(titulo) AS titulo, MIN(precio) AS precio
       FROM v_productos
       GROUP BY id_ejecucion, fecha_consulta, comercio, titulo_norm),
     l AS (
       SELECT a.*,
              LAG(precio) OVER w AS precio_anterior,
              LAG(id_ejecucion) OVER w AS id_ejecucion_anterior
       FROM a
       WINDOW w AS (PARTITION BY comercio, titulo_norm ORDER BY id_ejecucion))
     SELECT id_ejecucion, id_ejecucion_anterior, fecha_consulta, comercio, titulo,
            precio_anterior, precio,
            precio - precio_anterior AS cambio_cop,
            ROUND(100.0 * (precio - precio_anterior) / precio_anterior, 1) AS cambio_pct
     FROM l
     WHERE precio_anterior IS NOT NULL AND precio <> precio_anterior"
)

crear_esquema <- function(con) {
  for (s in DDL) DBI::dbExecute(con, s)
  for (nombre in names(VISTAS)) {
    DBI::dbExecute(con, paste0("DROP VIEW IF EXISTS ", nombre))
    DBI::dbExecute(con, VISTAS[[nombre]])
  }
  invisible(con)
}

# Guarda (o actualiza) el catálogo de presentaciones comparables.
sembrar_presentaciones <- function(con) {
  cols <- c("id_presentacion", "producto", "contenido_total", "unidad_medida",
            "unidades_paquete", "marca_like", "marca_like_alt", "gramos",
            "unidades", "titulo_like", "titulo_not_like")
  DBI::dbExecute(con, sprintf(
    "INSERT OR REPLACE INTO presentaciones_comparables (%s) VALUES (%s)",
    paste(cols, collapse = ", "), marcadores(length(cols))),
    params = unname(as.list(CATALOGO[cols])))
  invisible(nrow(CATALOGO))
}

# ---- 4. Preparación de las observaciones ----------------------------------

# Contenido total y unidad normalizada. Si el título dice "6und x 37g c/u" el
# gramaje es por unidad: el contenido total del empaque es 6 x 37 = 222 g.
# Un dato ausente queda ausente (NA): no se inventa.
normalizar_contenido <- function(titulo, gramos, unidades) {
  por_unidad <- grepl("c/u|cada\\s*uno", tolower(ifelse(is.na(titulo), "", titulo)))
  hay_gramos <- !is.na(gramos)
  varias     <- !is.na(unidades) & unidades > 1

  contenido <- dplyr::case_when(
    hay_gramos & por_unidad & !is.na(unidades) ~ gramos * unidades,
    hay_gramos                                 ~ gramos,
    varias                                     ~ unidades,
    TRUE                                       ~ NA_real_
  )
  unidad <- dplyr::case_when(
    hay_gramos ~ "g",
    varias     ~ "unidad",
    TRUE       ~ NA_character_
  )
  tibble::tibble(contenido_total = contenido, unidad_medida = unidad)
}

# De la tabla del scraper (pagina, consulta, ...) a las columnas de productos.
preparar_observaciones <- function(df) {
  if (nrow(df) == 0) return(NULL)
  if (!"archivo_raw" %in% names(df)) df$archivo_raw <- NA_character_
  cont <- normalizar_contenido(df$titulo, df$gramos, df$unidades)

  tibble::tibble(
    comercio = df$pagina,
    subcategoria = df$consulta,
    titulo = df$titulo,
    titulo_norm = tolower(trimws(df$titulo)),
    marca_producto= df$marca_producto,
    precio_texto = df$precio_texto,
    precio = df$precio,
    precio_previo_texto = df$precio_previo_texto,
    precio_previo = df$precio_previo,
    tiene_descuento = as.integer(df$tiene_descuento),
    descuento_pct = df$descuento_pct,
    gramos = df$gramos,
    unidades = df$unidades,
    contenido_total = cont$contenido_total,
    unidad_medida = cont$unidad_medida,
    hora_consulta = df$hora_consulta,
    fecha_consulta = substr(df$hora_consulta, 1, 10),
    pagina_consulta = df$pagina_consulta,
    archivo_raw = df$archivo_raw
  )
}

fecha_hoy <- function() format(Sys.time(), "%Y-%m-%d", tz = "America/Bogota")

# ---- 5. Ejecuciones e inserción -------------------------------------------

# Una ejecución se identifica por la clave de sus copias crudas: raw:1 (sin
# sufijo, 10 de octubre), raw:2 (sufijo "2"), etc. Así reprocesar las mismas
# copias nunca crea una ejecución nueva ni duplica observaciones.
clave_ejecucion <- function(sufijo) paste0("raw:", ifelse(nzchar(sufijo), sufijo, "1"))

# Sufijo de la próxima ejecución en línea: "" si la base está vacía, si no
# el siguiente número libre.
siguiente_sufijo <- function(con) {
  n <- consultar(con, "SELECT COALESCE(MAX(id_ejecucion), 0) AS n FROM ejecuciones")$n + 1
  repeat {
    suf <- if (n == 1) "" else as.character(n)
    ocupada <- consultar(con, "SELECT COUNT(*) AS n FROM ejecuciones WHERE clave = ?",
                         list(clave_ejecucion(suf)))$n
    if (ocupada == 0) return(suf)
    n <- n + 1
  }
}

obtener_o_crear_ejecucion <- function(con, sufijo, modo) {
  clave <- clave_ejecucion(sufijo)
  fila <- consultar(con, "SELECT id_ejecucion FROM ejecuciones WHERE clave = ?", list(clave))
  if (nrow(fila) > 0) return(list(id = fila$id_ejecucion, nueva = FALSE))

  DBI::dbExecute(con,
    "INSERT INTO ejecuciones (clave, fecha_consulta, inicio, modo, estado, sufijo_raw)
     VALUES (?, ?, ?, ?, 'parcial', ?)",
    params = list(clave, fecha_hoy(), hora_actual(), modo, sufijo))
  list(id = DBI::dbGetQuery(con, "SELECT last_insert_rowid() AS id")$id, nueva = TRUE)
}

# Recalcula los totales de la ejecución a partir de sus observaciones.
finalizar_ejecucion <- function(con, id_ejecucion, estado, nota = NA_character_) {
  DBI::dbExecute(con,
    "UPDATE ejecuciones SET
        estado = ?, nota = COALESCE(?, nota),
        n_obs = (SELECT COUNT(*) FROM productos WHERE id_ejecucion = ?),
        fecha_consulta = COALESCE((SELECT MIN(fecha_consulta) FROM productos WHERE id_ejecucion = ?), fecha_consulta),
        inicio = COALESCE((SELECT MIN(hora_consulta) FROM productos WHERE id_ejecucion = ?), inicio),
        fin    = COALESCE((SELECT MAX(hora_consulta) FROM productos WHERE id_ejecucion = ?), ?)
      WHERE id_ejecucion = ?",
    params = list(estado, nota, id_ejecucion, id_ejecucion, id_ejecucion,
                  id_ejecucion, hora_actual(), id_ejecucion))
}

COLS_OBS <- c(
  "id_ejecucion", "fecha_consulta", "hora_consulta", "comercio", "subcategoria",
  "titulo", "titulo_norm", "marca_producto", "precio_texto", "precio",
  "precio_previo_texto", "precio_previo", "tiene_descuento", "descuento_pct",
  "gramos", "unidades", "contenido_total", "unidad_medida", "pagina_consulta",
  "archivo_raw"
)

# INSERT OR IGNORE + restricción UNIQUE: insertar dos veces la misma
# observación no la duplica. Devuelve cuántas filas entraron de verdad.
insertar_observaciones <- function(con, obs, id_ejecucion) {
  if (is.null(obs) || nrow(obs) == 0) return(0L)
  obs$id_ejecucion <- as.integer(id_ejecucion)
  sql <- sprintf("INSERT OR IGNORE INTO productos (%s) VALUES (%s)",
                 paste(COLS_OBS, collapse = ", "), marcadores(length(COLS_OBS)))
  DBI::dbExecute(con, sql, params = unname(as.list(obs[COLS_OBS])))
}

registrar_rechazadas <- function(con, rechazadas, id_ejecucion) {
  if (is.null(rechazadas) || nrow(rechazadas) == 0) return(0L)
  DBI::dbExecute(con,
    "INSERT INTO rechazados (id_ejecucion, comercio, subcategoria, titulo, precio_texto, motivo, fecha_registro)
     VALUES (?, ?, ?, ?, ?, ?, ?)",
    params = list(rep(as.integer(id_ejecucion), nrow(rechazadas)),
                  rechazadas$comercio, rechazadas$subcategoria, rechazadas$titulo,
                  rechazadas$precio_texto, rechazadas$motivo,
                  rep(fecha_hoy(), nrow(rechazadas))))
}

# ---- 6. Productos comparables ---------------------------------------------

# Marca las observaciones que cumplen cada regla del catálogo. Todos los
# valores van como parámetros. Si dos filas cumplen la misma regla en un
# comercio, solo se marca la primera (el índice único lo exige).
marcar_comparables <- function(con, id_ejecucion = NULL) {
  idej <- if (is.null(id_ejecucion)) NA_integer_ else as.integer(id_ejecucion)
  reglas <- consultar(con, "SELECT * FROM presentaciones_comparables ORDER BY id_presentacion")

  sql <- "UPDATE productos SET comparable = 1, id_presentacion = ?
          WHERE id_obs IN (
            SELECT id_obs FROM (
              SELECT id_obs,
                     ROW_NUMBER() OVER (PARTITION BY id_ejecucion, comercio ORDER BY id_obs) AS rn
              FROM productos
              WHERE comparable = 0
                AND (? IS NULL OR id_ejecucion = ?)
                AND (LOWER(marca_producto) LIKE ?
                     OR (? IS NOT NULL AND LOWER(marca_producto) LIKE ?))
                AND (? IS NULL OR gramos = ?)
                AND (? IS NULL OR unidades = ?)
                AND (? IS NULL OR LOWER(titulo) LIKE ?)
                AND (? IS NULL OR LOWER(titulo) NOT LIKE ?))
            WHERE rn = 1)
            AND NOT EXISTS (
              SELECT 1 FROM productos q
              WHERE q.id_ejecucion = productos.id_ejecucion
                AND q.comercio = productos.comercio AND q.id_presentacion = ?)"

  n <- 0L
  for (i in seq_len(nrow(reglas))) {
    r <- reglas[i, ]
    n <- n + DBI::dbExecute(con, sql, params = list(
      r$id_presentacion, idej, idej,
      r$marca_like, r$marca_like_alt, r$marca_like_alt,
      r$gramos, r$gramos, r$unidades, r$unidades,
      r$titulo_like, r$titulo_like, r$titulo_not_like, r$titulo_not_like,
      r$id_presentacion))
  }
  n
}

reiniciar_comparables <- function(con) {
  DBI::dbExecute(con, "UPDATE productos SET comparable = 0, id_presentacion = NULL")
}

# ---- 7. Procesar un comercio ----------------------------------------------

# Valida e inserta lo recolectado de UN comercio dentro de una transacción:
# si algo falla, la base queda como estaba. Devuelve una fila de resumen.
procesar_comercio <- function(con, id_ejecucion, res, id_previa = NA_integer_) {

  obs <- preparar_observaciones(res$datos)
  val <- if (is.null(obs)) list(validas = NULL, rechazadas = NULL) else validar_observaciones(obs)
  n_rec <- if (is.null(val$rechazadas)) 0L else nrow(val$rechazadas)

  n_ins <- 0L
  tryCatch(
    DBI::dbWithTransaction(con, {
      n_ins <- insertar_observaciones(con, val$validas, id_ejecucion)
      registrar_rechazadas(con, val$rechazadas, id_ejecucion)
      marcar_comparables(con, id_ejecucion)
    }),
    error = function(e) {
      res$estado <<- "fallida"
      res$errores[["base de datos"]] <<- conditionMessage(e)
      n_ins <<- 0L
    }
  )

  # Regla de la ejecución: los ocho comparables deben estar en el comercio.
  encontrados <- consultar(con,
    "SELECT DISTINCT id_presentacion FROM productos
     WHERE id_ejecucion = ? AND comercio = ? AND id_presentacion IS NOT NULL",
    list(as.integer(id_ejecucion), res$sitio))$id_presentacion
  faltan <- presentaciones_faltantes(encontrados, CATALOGO$id_presentacion)
  estado <- res$estado
  if (length(faltan) > 0 && estado == "completa") estado <- "parcial"

  motivos <- c(
    if (length(res$errores) > 0) paste0(names(res$errores), ": ", res$errores),
    if (length(faltan) > 0 && res$estado != "fallida") paste("faltan comparables:", paste(faltan, collapse = ", "))
  )
  motivo <- if (length(motivos) > 0) paste(motivos, collapse = "; ") else NA_character_

  # Cambios frente a la ejecución anterior. Si el comercio no se pudo leer
  # completo, "no observados" no es confiable y se deja en NA.
  nuevos <- cambios <- no_obs <- NA_integer_
  if (!is.na(id_previa) && estado != "fallida") {
    cmp <- db_cambios(con, id_previa, id_ejecucion, umbral_pct = 0, comercios = res$sitio)
    nuevos  <- sum(cmp$estado == "nuevo")
    cambios <- sum(cmp$estado %in% c("subió", "bajó"))
    if (estado == "completa") no_obs <- sum(cmp$estado == "no observado")
  }

  DBI::dbExecute(con,
    "INSERT OR REPLACE INTO ejecuciones_comercio
       (id_ejecucion, comercio, estado, n_recolectados, n_insertados, n_rechazados, motivo)
     VALUES (?, ?, ?, ?, ?, ?, ?)",
    params = list(as.integer(id_ejecucion), res$sitio, estado,
                  nrow(res$datos), as.integer(n_ins), n_rec, motivo))

  tibble::tibble(
    comercio = res$sitio, estado = estado,
    recolectados = nrow(res$datos), insertados = as.integer(n_ins),
    productos_nuevos = as.integer(nuevos), cambios_precio = as.integer(cambios),
    no_observados = as.integer(no_obs), rechazados = n_rec, motivo = motivo
  )
}

# ---- 8. Actualización completa (la llama el botón de la app) --------------

# modo "online":  descarga las páginas (scraper.R), valida e inserta.
# modo "offline": reprocesa las copias de raw/ con el sufijo indicado; si esa
#                 ejecución ya está en la base no se duplica nada.
# Devuelve el resumen por comercio y el estado de la ejecución. Si un comercio
# falla, sigue con los demás.
actualizar_precios <- function(modo = c("online", "offline"), sufijo = NULL,
                               ruta = ruta_base(), consultas = CONSULTAS,
                               pausa = PAUSA_SEG, dir_raw = DIR_RAW) {
  modo <- match.arg(modo)

  con <- abrir_con(ruta)
  on.exit(cerrar_con(con), add = TRUE)
  crear_esquema(con)
  sembrar_presentaciones(con)

  salida <- function(mensaje, resumen = tibble::tibble(), id = NA_integer_, estado = "fallida") {
    list(resumen = resumen, id_ejecucion = id, estado = estado, mensaje = mensaje)
  }

  if (modo == "online") {
    if (!scraper_disponible()) {
      return(salida(paste(
        "Este equipo no puede hacer scraping en línea (no hay Chrome/chromote o el",
        "comercio bloquea el servidor). Use el modo sin conexión, que reprocesa raw/.")))
    }
    sufijo <- siguiente_sufijo(con)
  } else {
    if (is.null(sufijo)) {
      disp <- unique(raw_disponibles(dir_raw)$sufijo)
      if (length(disp) == 0) return(salida("No hay copias crudas en raw/."))
      claves <- consultar(con, "SELECT clave FROM ejecuciones")$clave
      pendientes <- disp[!clave_ejecucion(disp) %in% claves]
      sufijo <- if (length(pendientes) > 0) pendientes[1] else disp[length(disp)]
    }
    archivos <- file.path(dir_raw, nombre_raw(rep(names(SITIOS), each = length(consultas)),
                                              rep(consultas, times = length(SITIOS)), sufijo))
    if (!any(file.exists(archivos))) {
      return(salida(paste0("No hay copias crudas con el sufijo '", sufijo, "' en raw/.")))
    }
  }

  ejec <- obtener_o_crear_ejecucion(con, sufijo, if (modo == "online") "online" else "offline")
  id_previa <- consultar(con,
    "SELECT MAX(id_ejecucion) AS id FROM ejecuciones WHERE id_ejecucion < ? AND n_obs > 0",
    list(as.integer(ejec$id)))$id

  filas <- lapply(names(SITIOS), function(s) {
    res <- recolectar_comercio(s, consultas, sufijo, modo = modo, pausa = pausa, dir_raw = dir_raw)
    procesar_comercio(con, ejec$id, res, id_previa)
  })
  resumen <- dplyr::bind_rows(filas)

  estado <- if (all(resumen$estado == "completa")) "completa"
            else if (all(resumen$estado == "fallida")) "fallida" else "parcial"
  finalizar_ejecucion(con, ejec$id, estado)

  fecha <- consultar(con, "SELECT fecha_consulta FROM ejecuciones WHERE id_ejecucion = ?",
                     list(as.integer(ejec$id)))$fecha_consulta
  list(
    resumen = resumen, id_ejecucion = ejec$id, estado = estado,
    mensaje = paste0("Ejecución ", ejec$id, " (", fecha, "): ", estado,
                     if (!ejec$nueva) " · ya existía; solo se agregó lo que faltaba." else ".")
  )
}

# ---- 9. Importar la lectura del Taller 1 ----------------------------------

# La ejecución del 10 de octubre salió del scraper del Taller 1 y está en
# consultas_iniciales.db. Se importa SIN modificar los precios; solo pasa
# por la misma validación que cualquier ejecución nueva.
importar_ejecucion_inicial <- function(con, origen = "consultas_iniciales.db") {
  ya <- consultar(con, "SELECT COUNT(*) AS n FROM ejecuciones WHERE clave = ?",
                  list(clave_ejecucion("")))$n
  if (ya > 0) return(invisible(NULL))
  if (!file.exists(origen)) {
    stop("No se encontró ", origen, ". Cópielo a taller_2/ (es la base del Taller 1).")
  }

  con_o <- DBI::dbConnect(RSQLite::SQLite(), origen)
  on.exit(DBI::dbDisconnect(con_o), add = TRUE)
  df <- tibble::as_tibble(DBI::dbGetQuery(con_o, "SELECT * FROM productos"))
  df$archivo_raw <- file.path(DIR_RAW, nombre_raw(df$pagina, df$consulta, ""))

  ejec <- obtener_o_crear_ejecucion(con, "", "importada")
  filas <- lapply(unique(df$pagina), function(s) {
    res <- list(sitio = s, datos = df[df$pagina == s, ], estado = "completa", errores = character())
    procesar_comercio(con, ejec$id, res, id_previa = NA_integer_)
  })
  resumen <- dplyr::bind_rows(filas)
  estado <- if (all(resumen$estado == "completa")) "completa" else "parcial"
  finalizar_ejecucion(con, ejec$id, estado,
                      "Lectura del Taller 1 (scraper del 10 de octubre), importada de consultas_iniciales.db.")
  registrar_correcciones_taller1(con, ejec$id)
  invisible(resumen)
}

# Deja constancia de los cambios hechos a la base del Taller 1 (Módulo 1.2).
registrar_correcciones_taller1 <- function(con, id_ejecucion) {
  hoy <- fecha_hoy()

  DBI::dbExecute(con,
    "INSERT INTO correcciones (fecha, tabla, registro, campo, valor_anterior, valor_nuevo, motivo)
     SELECT ?, 'productos', 'id_obs=' || id_obs, 'contenido_total',
            CAST(gramos AS TEXT), CAST(contenido_total AS TEXT), ?
     FROM productos
     WHERE id_ejecucion = ? AND gramos IS NOT NULL AND contenido_total <> gramos",
    params = list(hoy,
      "El título indica gramos por unidad (c/u): el contenido del empaque es gramos x unidades.",
      as.integer(id_ejecucion)))

  reglas <- tibble::tribble(
    ~registro, ~campo, ~anterior, ~nuevo, ~motivo,
    "P07", "regla", "precio < 4000", "unidades = 1",
    "El tope de precio solo servía para excluir el paquete x5 de Jumbo; la condición correcta es el número de unidades.",
    "P03", "regla", "marca LIKE %choco% y gramos = 570", "marca LIKE %choco%, gramos = 570 y título LIKE %krispis%",
    "Evita confundir Choco Krispis con otras presentaciones de 570 g.",
    "P04", "regla", "marca LIKE %kellogg% y gramos = 410", "marca LIKE %kellogg%, gramos = 410 y título LIKE %corn flakes%",
    "Evita confundir Corn Flakes con otras presentaciones Kellogg's de 410 g."
  )
  DBI::dbExecute(con,
    "INSERT INTO correcciones (fecha, tabla, registro, campo, valor_anterior, valor_nuevo, motivo)
     VALUES (?, 'presentaciones_comparables', ?, ?, ?, ?, ?)",
    params = list(rep(hoy, nrow(reglas)), reglas$registro, reglas$campo,
                  reglas$anterior, reglas$nuevo, reglas$motivo))
  invisible(NULL)
}

# ---- 10. Construcción de la base ------------------------------------------

# Sufijos de raw/ que todavía no son una ejecución de la base.
raw_pendientes <- function(con, dir_raw = DIR_RAW) {
  disp <- unique(raw_disponibles(dir_raw)$sufijo)
  if (length(disp) == 0) return(character())
  claves <- consultar(con, "SELECT clave FROM ejecuciones")$clave
  disp[!clave_ejecucion(disp) %in% claves]
}

construir_base <- function(ruta = ruta_base(), origen = "consultas_iniciales.db",
                           dir_raw = DIR_RAW) {
  con <- abrir_con(ruta)
  crear_esquema(con)
  sembrar_presentaciones(con)
  if (file.exists(origen)) {
    importar_ejecucion_inicial(con, origen)
  } else {
    message("Aviso: no está ", origen, "; no se importó la lectura del Taller 1.")
  }
  pendientes <- raw_pendientes(con, dir_raw)
  cerrar_con(con)

  for (suf in setdiff(pendientes, "")) {
    message("Procesando copias crudas con sufijo '", suf, "'...")
    print(actualizar_precios("offline", sufijo = suf, ruta = ruta, dir_raw = dir_raw)$resumen)
  }

  con <- abrir_con(ruta)
  on.exit(cerrar_con(con))
  consultar(con, "SELECT id_ejecucion, clave, fecha_consulta, modo, estado, n_obs FROM ejecuciones")
}

# ---- 11. Ejecución como script --------------------------------------------

if (isTRUE(getOption("taller2.ejecutar", TRUE))) {
  print(construir_base())
}
