# =======================================================================
# db.R - Capa de Acceso a Datos 
# Propósito: Gestiona la conexión a SQLite, crea las vistas SQL requeridas,
#            registra las correcciones del Taller 1 y provee funciones con
#            consultas parametrizadas seguras para la aplicación Shiny.
# =======================================================================

library(DBI)
library(RSQLite)
library(glue)
library(dplyr)


DB_PATH <- "comparador_precios.sqlite"

# =======================================================================
# FUNCIÓN DE CONEXIÓN Y CREACIÓN DE ESTRUCTURA INICIAL
# =======================================================================
conectar_db <- function(ruta_db = DB_PATH) {
  con <- dbConnect(RSQLite::SQLite(), ruta_db)
  
  
  dbExecute(con, "PRAGMA foreign_keys = ON")
  
  # --- TABLA DE CORRECCIONES  ---
  dbExecute(con, "
    CREATE TABLE IF NOT EXISTS correcciones (
      id_correccion INTEGER PRIMARY KEY AUTOINCREMENT,
      fecha TEXT NOT NULL,
      registro_afectado TEXT,
      valor_anterior TEXT,
      valor_nuevo TEXT,
      motivo TEXT NOT NULL
    )
  ")
  
  # --- VISTAS SQL  ---
  
  # Vista 1: v_comparables (Solo los 8 productos homologados presentes en los 3 comercios)
  dbExecute(con, "DROP VIEW IF EXISTS v_comparables")
  dbExecute(con, "
    CREATE VIEW v_comparables AS
    SELECT 
      ph.id_homologado,
      ph.marca,
      ph.mascota,
      ph.etapa_vida,
      ph.sabor,
      ph.categoria,
      ph.presentacion_estandar
    FROM productos_homologados ph
    JOIN anuncios a ON ph.id_homologado = a.id_homologado
    WHERE ph.id_homologado NOT LIKE '%OTRA/SINMARCA%'
    GROUP BY 
      ph.id_homologado,
      ph.marca,
      ph.mascota,
      ph.etapa_vida,
      ph.sabor,
      ph.categoria,
      ph.presentacion_estandar
    HAVING COUNT(DISTINCT a.id_comercio) = 3
  ")
  # Vista 2: v_ultimo_precio (El precio más reciente de cada producto por comercio)
  dbExecute(con, "DROP VIEW IF EXISTS v_ultimo_precio")
  dbExecute(con, "
    CREATE VIEW v_ultimo_precio AS
    WITH UltimaEjecucion AS (
      SELECT 
        id_anuncio, 
        MAX(fecha_consulta) AS fecha_reciente
      FROM precios_historial
      GROUP BY id_anuncio
    )
    SELECT 
      a.id_homologado,
      a.id_anuncio,
      c.comercio,
      a.marca,
      a.texto_original AS presentacion_original,
      ph.presentacion_estandar,
      p.precio,            
      p.precio_x_und,      
      p.fecha_consulta,
      p.id_ejecucion
    FROM precios_historial p
    JOIN UltimaEjecucion ue 
      ON p.id_anuncio = ue.id_anuncio AND p.fecha_consulta = ue.fecha_reciente
    JOIN anuncios a ON p.id_anuncio = a.id_anuncio
    JOIN comercios c ON a.id_comercio = c.id_comercio
    JOIN v_comparables ph ON a.id_homologado = ph.id_homologado
  ")
  
  # Vista 3: v_cambios_precio (Compara la penúltima ejecución con la última)
  dbExecute(con, "DROP VIEW IF EXISTS v_cambios_precio")
  dbExecute(con, "
    CREATE VIEW v_cambios_precio AS
    WITH FechasUnicas AS (
      SELECT DISTINCT id_ejecucion, date(fecha_consulta) as dia
      FROM precios_historial
      ORDER BY fecha_consulta DESC
    ),
    Ultima AS (SELECT * FROM FechasUnicas LIMIT 1 OFFSET 0),
    Penultima AS (SELECT * FROM FechasUnicas LIMIT 1 OFFSET 1),
    PreciosNuevos AS (
      SELECT p.id_anuncio, p.precio_x_und as precio_nuevo, p.id_ejecucion
      FROM precios_historial p
      JOIN Ultima u ON p.id_ejecucion = u.id_ejecucion
    ),
    PreciosViejos AS (
      SELECT p.id_anuncio, p.precio_x_und as precio_viejo, p.id_ejecucion
      FROM precios_historial p
      JOIN Penultima u ON p.id_ejecucion = u.id_ejecucion
    )
    SELECT 
      a.id_homologado,
      c.comercio,
      ph.presentacion_estandar,
      v.precio_viejo,
      n.precio_nuevo,
      ROUND(((n.precio_nuevo - v.precio_viejo) / v.precio_viejo) * 100, 2) AS diferencia_pct,
      CASE 
        WHEN n.precio_nuevo > v.precio_viejo THEN 'Subió'
        WHEN n.precio_nuevo < v.precio_viejo THEN 'Bajó'
        ELSE 'Sin cambio'
      END AS estado_cambio
    FROM anuncios a
    JOIN comercios c ON a.id_comercio = c.id_comercio
    JOIN v_comparables ph ON a.id_homologado = ph.id_homologado
    LEFT JOIN PreciosNuevos n ON a.id_anuncio = n.id_anuncio
    LEFT JOIN PreciosViejos v ON a.id_anuncio = v.id_anuncio
    WHERE v.precio_viejo IS NOT NULL AND n.precio_nuevo IS NOT NULL
  ")
  return(con)
}

# =======================================================================
#  FUNCIÓN PARA REGISTRAR LAS CORRECCIONES DEL TALLER 1 
# =======================================================================
registrar_correcciones_taller_1 <- function() {
  con <- conectar_db()
  
  # Verificamos si ya insertamos las correcciones para no duplicarlas
  conteo <- dbGetQuery(con, "SELECT COUNT(*) as n FROM correcciones")$n
  
  if (conteo == 0) {
    correcciones <- data.frame(
      fecha = as.character(Sys.time()),
      registro_afectado = c("Estructura Promociones", "Reglas Homologación", "Esquema Base de Datos"),
      valor_anterior = c("Precio dividido erróneamente en 4x3", "IDs de 1 a 8 manuales", "Sin columna id_ejecucion"),
      valor_nuevo = c("Uso de 'cantidad_lleva' para precio efectivo", "ID concatenado (Marca_Mascota_Etapa...)", "Tabla precios_historial con id_ejecucion"),
      motivo = c("Cálculo incorrecto del precio unitario", "Cruces de categorías distintas", "Necesidad de trazabilidad temporal")
    )
    dbWriteTable(con, "correcciones", correcciones, append = TRUE)
    message("✅ Correcciones del Taller 1 registradas exitosamente en la base de datos.")
  }
  dbDisconnect(con)
}

# =======================================================================
#  FUNCIONES DE CONSULTA PARAMETRIZADAS 
# =======================================================================

obtener_comercios <- function() {
  con <- conectar_db()
  res <- dbGetQuery(con, "SELECT comercio FROM comercios ORDER BY comercio")
  dbDisconnect(con)
  return(res$comercio)
}

# Obtiene opciones únicas de marcas y mascotas para los filtros laterales
obtener_opciones_filtros <- function() {
  con <- conectar_db()
  marcas <- dbGetQuery(con, "SELECT DISTINCT marca FROM v_ultimo_precio WHERE marca IS NOT NULL ORDER BY marca")$marca
  mascotas <- dbGetQuery(con, "SELECT DISTINCT mascota FROM v_comparables WHERE mascota IS NOT NULL ORDER BY mascota")$mascota
  dbDisconnect(con)
  list(marcas = marcas, mascotas = mascotas)
}

# Consulta parametrizada con filtros completos (comercio, marca, mascota, precio y texto)
obtener_precios_filtrados <- function(comercios_seleccionados, marcas_sel = NULL, mascotas_sel = NULL, texto_busqueda = "", precio_min = 0, precio_max = 250000) {
  con <- conectar_db()
  
  sql_base <- "
    SELECT u.* 
    FROM v_ultimo_precio u
    JOIN v_comparables c ON u.id_homologado = c.id_homologado
    WHERE u.comercio IN ({comercios_seleccionados*})
      AND u.precio_x_und BETWEEN {precio_min} AND {precio_max}
  "
  
  if (!is.null(marcas_sel) && length(marcas_sel) > 0) {
    sql_base <- paste0(sql_base, " AND u.marca IN ({marcas_sel*})")
  }
  
  if (!is.null(mascotas_sel) && length(mascotas_sel) > 0) {
    sql_base <- paste0(sql_base, " AND c.mascota IN ({mascotas_sel*})")
  }
  
  if (!is.null(texto_busqueda) && trimws(texto_busqueda) != "") {
    patron <- paste0("%", trimws(texto_busqueda), "%")
    sql_base <- paste0(sql_base, " AND (u.presentacion_original LIKE {patron} OR u.marca LIKE {patron} OR u.id_homologado LIKE {patron})")
  }
  
  sql <- glue_sql(sql_base, .con = con)
  resultados <- dbGetQuery(con, sql)
  dbDisconnect(con)
  return(resultados)
}

# Calcula los 6 indicadores clave directamente en SQL
obtener_indicadores <- function() {
  con <- conectar_db()

  n_comparables <- dbGetQuery(con, "SELECT COUNT(*) as n FROM v_comparables")$n
  
  n_historial <- dbGetQuery(con, "SELECT COUNT(*) as n FROM precios_historial")$n
  
  n_ejecuciones <- dbGetQuery(con, "SELECT COUNT(DISTINCT id_ejecucion) as n FROM precios_historial")$n
  
  df_eco <- dbGetQuery(con, "
    SELECT comercio AS com, AVG(precio_x_und) AS prom
    FROM v_ultimo_precio 
    WHERE precio_x_und IS NOT NULL AND precio_x_und > 0
    GROUP BY comercio 
    ORDER BY prom ASC 
    LIMIT 1
  ")
  comercio_economico <- if (nrow(df_eco) > 0) as.character(df_eco$com[1]) else "N/A"
  
  ahorro_promedio <- dbGetQuery(con, "
    SELECT ROUND(AVG((max_p - min_p) / max_p * 100), 1) as pct
    FROM (
      SELECT id_homologado, MIN(precio) as min_p, MAX(precio) as max_p
      FROM v_ultimo_precio
      WHERE precio > 0
      GROUP BY id_homologado
    )
  ")$pct
  if (is.na(ahorro_promedio) || length(ahorro_promedio) == 0) ahorro_promedio <- 0
  

  ultima_fecha <- dbGetQuery(con, "SELECT MAX(fecha_consulta) as fecha FROM precios_historial")$fecha
  if (is.na(ultima_fecha) || length(ultima_fecha) == 0) ultima_fecha <- "Sin datos"
  
  dbDisconnect(con)
  
  list(
    n_comparables = n_comparables,
    n_historial = n_historial,
    n_ejecuciones = n_ejecuciones,
    comercio_economico = comercio_economico,
    ahorro_promedio = ahorro_promedio,
    ultima_fecha = substr(as.character(ultima_fecha), 1, 16)
  )
}
# Obtiene la lista de ejecuciones registradas en la base de datos
obtener_ejecuciones <- function() {
  con <- conectar_db()
  res <- dbGetQuery(con, "
    SELECT DISTINCT 
      id_ejecucion, 
      MIN(substr(fecha_consulta, 1, 16)) AS fecha_inicio
    FROM precios_historial
    GROUP BY id_ejecucion
    ORDER BY fecha_inicio DESC
  ")
  dbDisconnect(con)
  return(res)
}

# Compara precios unitarios entre dos ejecuciones elegidas por el usuario
comparar_ejecuciones <- function(id_anterior, id_actual, comercios_seleccionados) {
  con <- conectar_db()
  
  sql <- glue_sql("
    WITH PreciosAct AS (
      SELECT p.id_anuncio, p.precio AS precio_nuevo, p.precio_x_und AS unit_nuevo
      FROM precios_historial p
      WHERE p.id_ejecucion = {id_actual}
    ),
    PreciosAnt AS (
      SELECT p.id_anuncio, p.precio AS precio_viejo, p.precio_x_und AS unit_viejo
      FROM precios_historial p
      WHERE p.id_ejecucion = {id_anterior}
    )
    SELECT 
      a.id_homologado,
      c.comercio,
      ph.marca || ' - ' || ph.presentacion_estandar AS producto,
      v.precio_viejo,
      n.precio_nuevo,
      (n.precio_nuevo - v.precio_viejo) AS diff_pesos,
      ROUND(((n.precio_nuevo - v.precio_viejo) / v.precio_viejo) * 100, 2) AS diff_pct,
      CASE 
        WHEN n.precio_nuevo > v.precio_viejo THEN 'Subió'
        WHEN n.precio_nuevo < v.precio_viejo THEN 'Bajó'
        ELSE 'Sin cambio'
      END AS estado_cambio
    FROM anuncios a
    JOIN comercios c ON a.id_comercio = c.id_comercio
    JOIN v_comparables ph ON a.id_homologado = ph.id_homologado
    JOIN PreciosAct n ON a.id_anuncio = n.id_anuncio
    JOIN PreciosAnt v ON a.id_anuncio = v.id_anuncio
    WHERE c.comercio IN ({comercios_seleccionados*})
      AND v.precio_viejo > 0 AND n.precio_nuevo > 0
  ", .con = con)
  
  res <- dbGetQuery(con, sql)
  dbDisconnect(con)
  return(res)
}
# =======================================================================
#  GRAFICOS
# =======================================================================


obtener_lista_comparables <- function() {
  con <- conectar_db()
  res <- dbGetQuery(con, "
    SELECT id_homologado, marca || ' - ' || presentacion_estandar || ' (' || sabor || ')' AS nombre_amigable 
    FROM v_comparables
  ")
  dbDisconnect(con)
  return(res)
}
# ========= GRAFICO 1 ==================================
# Obtiene la historia de precios de un producto específico parametrizado
obtener_historico_producto <- function(id_homo) {
  con <- conectar_db()
  # Se estandariza 'comercio' como 'Comercio' para que Highcharter lo lea bien
  sql <- "
    SELECT c.comercio AS Comercio, p.precio, p.fecha_consulta
    FROM precios_historial p
    JOIN anuncios a ON p.id_anuncio = a.id_anuncio
    JOIN comercios c ON a.id_comercio = c.id_comercio
    WHERE a.id_homologado = ?
    ORDER BY p.fecha_consulta ASC
  "
  res <- dbGetQuery(con, sql, params = list(id_homo))
  dbDisconnect(con)
  return(res)
}

# ========= GRAFICO 2 ==================================
# Obtiene el precio unitario más reciente de un producto para comparar comercios
obtener_ultimo_precio_unitario <- function(id_homo) {
  con <- conectar_db()
  # Aprovechamos la vista optimizada v_ultimo_precio (¡100x más rápido!)
  sql <- "
    SELECT comercio AS Comercio, precio_x_und AS precio_u
    FROM v_ultimo_precio
    WHERE id_homologado = ?
  "
  res <- dbGetQuery(con, sql, params = list(id_homo))
  dbDisconnect(con)
  return(res)
}

# ========= GRAFICO 3 ==================================
# Obtiene el último precio de TODOS los productos para ver la distribución
obtener_distribucion_precios <- function() {
  con <- conectar_db()
  # Aprovechamos la vista optimizada v_ultimo_precio para todo el dataset
  sql <- "
    SELECT comercio AS Comercio, precio 
    FROM v_ultimo_precio
    WHERE precio > 0
  "
  res <- dbGetQuery(con, sql)
  dbDisconnect(con)
  return(res)
}
# ========= GRÁFICO 4 ==================================
# Obtiene la cantidad de productos por marca para ver la participación
obtener_participacion_marcas <- function() {
  con <- conectar_db()
  sql <- "
    SELECT marca, COUNT(*) as cantidad 
    FROM v_comparables 
    GROUP BY marca 
    ORDER BY cantidad DESC
  "
  res <- dbGetQuery(con, sql)
  dbDisconnect(con)
  return(res)
}
# =======================================================================
#  CANASTA 
# =======================================================================
# Obtiene los precios vigentes de los productos comparables por comercio
obtener_precios_canasta <- function(ids_seleccionados) {
  con <- conectar_db()
  placeholders <- paste(rep("?", length(ids_seleccionados)), collapse = ", ")
  sql <- paste0("
    SELECT 
      id_homologado,
      comercio,
      marca || ' - ' || presentacion_estandar AS producto,
      precio
    FROM v_ultimo_precio
    WHERE id_homologado IN (", placeholders, ")
      AND precio > 0
  ")
  res <- dbGetQuery(con, sql, params = as.list(ids_seleccionados))
  dbDisconnect(con)
  return(res)
}
registrar_correcciones_taller_1()
