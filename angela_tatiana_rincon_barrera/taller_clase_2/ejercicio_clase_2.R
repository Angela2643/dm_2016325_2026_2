# =============================================================================
# Taller práctico de Web Scraping con R — Parte 1
# 13. Ejercicio de clase: temperaturas máxima y mínima diarias de Bogotá
#     (años 2024 y 2025) a partir de las páginas históricas de AccuWeather
#
# Curso de Minería de Datos — Universidad Nacional de Colombia
# Docente: Andrés Felipe Flórez Rivera
# Autora: Angela Tatiana Rincón Barrera
# =============================================================================


# -----------------------------------------------------------------------------
# 0. Paquetes
# -----------------------------------------------------------------------------

# httr viene instalado junto con rvest, por lo que no requiere instalación
# adicional
paquetes <- c("rvest", "xml2", "httr", "dplyr", "stringr",
              "purrr", "tibble", "readr")

# Verificamos qué paquetes faltan antes de cargarlos
instalados <- rownames(installed.packages())
pendientes <- setdiff(paquetes, instalados)

if (length(pendientes) > 0) {
  stop(
    "Faltan paquetes: ", paste(pendientes, collapse = ", "),
    ". Instálelos con install.packages(c(",
    paste(sprintf('"%s"', pendientes), collapse = ", "), "))"
  )
}

# Cargamos los paquetes sin mostrar mensajes
invisible(lapply(paquetes, library, character.only = TRUE))


# -----------------------------------------------------------------------------
# 1. Parámetros generales
# -----------------------------------------------------------------------------

# Identificador de Bogotá en AccuWeather y segmento de idioma/país de la URL
base_url      <- "https://www.accuweather.com"
idioma_pais   <- "es/co"
ciudad_slug   <- "bogota"
location_key  <- "107487"

# Periodo solicitado
anios <- c(2024, 2025)

# Pausa (en segundos) entre solicitudes
pausa_segundos <- 3

# Identificación del cliente, como recomienda la sección 12.3
agente <- "Taller Web Scraping R - Mineria de Datos UNAL (uso academico)"

# Carpeta para guardar el HTML de cada mes y no repetir solicitudes (12.4)
carpeta_cache <- "cache_accuweather"
dir.create(carpeta_cache, showWarnings = FALSE)

# Archivos de salida
archivo_salida      <- "temperaturas_bogota_2024_2025.csv"
archivo_limitaciones <- "limitaciones_scraping_accuweather.csv"

# Confirmación manual de los términos de uso. Los términos no se pueden
# evaluar con código: deben leerse en el enlace "Términos de uso" del pie
# de página de AccuWeather. Cambie a TRUE solo después de verificar que
# permiten las consultas automatizadas de este ejercicio.
terminos_revisados <- FALSE


# -----------------------------------------------------------------------------
# 2. Construcción de las URL de cada mes (requisito 1)
# -----------------------------------------------------------------------------

# AccuWeather usa el nombre del mes en inglés dentro de la ruta
meses_en <- c("january", "february", "march", "april", "may", "june",
              "july", "august", "september", "october", "november",
              "december")

# Construimos la URL de un mes y un año
construir_url_mes <- function(anio, mes) {
  paste0(
    base_url, "/", idioma_pais, "/", ciudad_slug, "/", location_key, "/",
    meses_en[mes], "-weather/", location_key, "?year=", anio
  )
}

# Tabla con las 24 combinaciones año-mes y su URL
urls_meses <- expand.grid(mes = 1:12, anio = anios) %>%
  as_tibble() %>%
  select(anio, mes) %>%
  mutate(url = map2_chr(anio, mes, construir_url_mes))

urls_meses


# -----------------------------------------------------------------------------
# 3. Verificación de robots.txt
# -----------------------------------------------------------------------------

# Lee robots.txt y devuelve las reglas Allow/Disallow aplicables a
# "User-agent: *"
leer_reglas_robots <- function(texto_robots) {
  lineas <- texto_robots %>%
    str_split("\n") %>%
    unlist() %>%
    str_remove("#.*$") %>%
    str_squish()
  lineas <- lineas[lineas != ""]

  reglas <- tibble(tipo = character(), ruta = character())
  grupo_aplica <- FALSE
  leyendo_agentes <- FALSE

  for (linea in lineas) {
    campo <- str_to_lower(str_extract(linea, "^[^:]+"))
    valor <- str_squish(str_remove(linea, "^[^:]+:"))

    if (campo == "user-agent") {
      # Varias líneas User-agent seguidas forman un mismo grupo
      if (!leyendo_agentes) grupo_aplica <- FALSE
      leyendo_agentes <- TRUE
      if (valor == "*") grupo_aplica <- TRUE
    } else {
      leyendo_agentes <- FALSE
      if (grupo_aplica && campo %in% c("allow", "disallow") && valor != "") {
        reglas <- add_row(reglas, tipo = campo, ruta = valor)
      }
    }
  }
  reglas
}

# Convierte una regla de robots.txt en expresión regular: "*" equivale a
# cualquier texto y "$" al final de la ruta
regla_a_regex <- function(ruta) {
  patron <- str_replace_all(ruta, "([.?+^(){}|\\[\\]\\\\])", "\\\\\\1")
  patron <- str_replace_all(patron, "\\*", ".*")
  paste0("^", patron)
}

# Indica si una ruta está permitida: gana la regla coincidente más larga y,
# en caso de empate, Allow
ruta_permitida <- function(ruta, reglas) {
  if (nrow(reglas) == 0) return(TRUE)
  coincidencias <- reglas %>%
    filter(map_lgl(ruta, ~ str_detect(.env$ruta, regla_a_regex(.x)))) %>%
    mutate(largo = nchar(ruta))
  if (nrow(coincidencias) == 0) return(TRUE)
  ganadora <- coincidencias %>%
    arrange(desc(largo), tipo != "allow") %>%
    slice(1)
  ganadora$tipo == "allow"
}

# Descargamos robots.txt
respuesta_robots <- GET(paste0(base_url, "/robots.txt"), user_agent(agente))

# Si el servidor rechaza la consulta automatizada de robots.txt, no es
# posible verificar las reglas desde R. Se documenta la limitación y se
# detiene el script sin consultar las páginas mensuales.
if (status_code(respuesta_robots) != 200) {
  limitacion_robots <- tibble(
    recurso     = "robots.txt",
    url         = paste0(base_url, "/robots.txt"),
    estado_http = status_code(respuesta_robots),
    fecha_consulta = as.character(Sys.time()),
    descripcion = paste(
      "El servidor rechazó la solicitud automatizada hecha desde R.",
      "No fue posible verificar robots.txt con el cliente del script,",
      "por lo que no se consultaron las páginas mensuales.",
      "Se requiere consultar con el docente antes de continuar."
    )
  )
  write_csv(limitacion_robots, archivo_limitaciones)
  stop("No fue posible leer robots.txt (estado HTTP ",
       status_code(respuesta_robots), "). La limitación quedó registrada en '",
       archivo_limitaciones, "'. Se detiene el script.")
}

reglas_robots <- leer_reglas_robots(
  content(respuesta_robots, as = "text", encoding = "UTF-8")
)

# Evaluamos la ruta y la consulta de cada URL mensual
urls_meses <- urls_meses %>%
  mutate(
    ruta = str_remove(url, fixed(base_url)),
    permitida_robots = map_lgl(ruta, ruta_permitida, reglas = reglas_robots)
  )

urls_meses %>% count(permitida_robots)

if (!all(urls_meses$permitida_robots)) {
  stop("robots.txt no permite consultar todas las URL mensuales. ",
       "Se detiene el script sin hacer solicitudes.")
}

if (!terminos_revisados) {
  stop("Revise los términos de uso de AccuWeather y, si permiten las ",
       "consultas automatizadas, cambie 'terminos_revisados' a TRUE.")
}


# -----------------------------------------------------------------------------
# 4. Descarga de cada mes con pausa (requisito 2)
# -----------------------------------------------------------------------------

# Descarga el HTML de un mes; si ya existe en la caché, lo reutiliza
descargar_mes <- function(url, anio, mes) {
  archivo <- file.path(carpeta_cache, sprintf("bogota_%d_%02d.html", anio, mes))

  if (file.exists(archivo)) {
    return(list(html = read_file(archivo), estado = 200L, desde_cache = TRUE))
  }

  # Pausa antes de cada solicitud real al servidor
  Sys.sleep(pausa_segundos)
  message("Consultando: ", url)

  respuesta <- GET(
    url,
    user_agent(agente),
    add_headers(`Accept-Language` = "es-CO,es;q=0.9")
  )

  estado <- status_code(respuesta)
  html <- if (estado == 200) {
    content(respuesta, as = "text", encoding = "UTF-8")
  } else {
    NA_character_
  }

  # Guardamos solo las respuestas exitosas
  if (estado == 200) write_file(html, archivo)

  list(html = html, estado = estado, desde_cache = FALSE)
}


# -----------------------------------------------------------------------------
# 5. Extracción de fecha, máxima y mínima (requisitos 3, 4 y 5)
# -----------------------------------------------------------------------------

# El calendario mensual muestra días del mes anterior y del siguiente para
# completar las semanas. A partir de la secuencia de números de día se
# identifica a qué mes pertenece cada casilla y se conservan solo las del
# mes consultado.
asignar_mes_relativo <- function(dias) {
  desplazamiento <- integer(length(dias))
  actual <- if (dias[1] == 1) 0L else -1L
  desplazamiento[1] <- actual
  if (length(dias) > 1) {
    for (i in 2:length(dias)) {
      if (dias[i] < dias[i - 1]) actual <- actual + 1L
      desplazamiento[i] <- actual
    }
  }
  desplazamiento
}

# Convierte textos como "21°" o "-3°" en número
texto_a_numero <- function(x) {
  x %>%
    str_replace_all("−", "-") %>%
    str_extract("-?\\d+(\\.\\d+)?") %>%
    as.numeric()
}

# Extrae la tabla diaria del HTML de un mes
extraer_mes <- function(html, url, anio, mes) {
  pagina <- read_html(html)
  casillas <- html_elements(pagina, ".monthly-calendar .monthly-daypanel")

  # Si el calendario no está en el HTML recibido, se informa la limitación
  if (length(casillas) == 0) {
    stop("El calendario mensual no aparece en el HTML recibido por R ",
         "(posible carga dinámica con JavaScript o bloqueo del sitio).")
  }

  tibble(
    dia      = casillas %>% html_element(".date") %>% html_text2() %>% texto_a_numero(),
    high_txt = casillas %>% html_element(".high") %>% html_text2(),
    low_txt  = casillas %>% html_element(".low")  %>% html_text2()
  ) %>%
    mutate(mes_relativo = asignar_mes_relativo(dia)) %>%
    filter(mes_relativo == 0) %>%
    transmute(
      fecha      = as.Date(sprintf("%d-%02d-%02d", anio, mes, dia)),
      high       = texto_a_numero(high_txt),
      low        = texto_a_numero(low_txt),
      url_origen = url
    )
}

# Une descarga y extracción; cualquier fallo queda registrado como error
procesar_mes <- function(url, anio, mes) {
  descarga <- descargar_mes(url, anio, mes)
  if (descarga$estado != 200) {
    stop("Respuesta HTTP ", descarga$estado, " del servidor.")
  }
  extraer_mes(descarga$html, url, anio, mes)
}

procesar_mes_seguro <- purrr::safely(procesar_mes)

respuestas <- pmap(
  list(urls_meses$url, urls_meses$anio, urls_meses$mes),
  procesar_mes_seguro
)

# Registro de limitaciones o errores por URL
limitaciones <- urls_meses %>%
  select(anio, mes, url) %>%
  mutate(
    error = map_chr(
      respuestas,
      ~ if (is.null(.x$error)) NA_character_ else conditionMessage(.x$error)
    )
  ) %>%
  filter(!is.na(error))

if (nrow(limitaciones) > 0) {
  write_csv(limitaciones, archivo_limitaciones)
  message(
    nrow(limitaciones), " mes(es) no se pudieron extraer. Detalle en '",
    archivo_limitaciones, "'. Si la causa es que el contenido no aparece ",
    "en el HTML, consulte con el docente antes de usar automatización ",
    "de navegador."
  )
}

# Unimos los meses extraídos correctamente
temperaturas <- respuestas %>%
  map("result") %>%
  compact() %>%
  list_rbind() %>%
  arrange(fecha)

if (nrow(temperaturas) == 0) {
  stop("No se extrajo ningún mes. Revise '", archivo_limitaciones, "'.")
}


# -----------------------------------------------------------------------------
# 6. Temperaturas en grados Celsius
# -----------------------------------------------------------------------------

# La versión es/co del sitio presenta las temperaturas en °C. Como control,
# si la mediana de las máximas supera 45 (imposible en Bogotá en °C), se
# asume que llegaron en °F y se convierten.
if (median(temperaturas$high, na.rm = TRUE) > 45) {
  message("Las temperaturas parecen estar en °F; se convierten a °C.")
  temperaturas <- temperaturas %>%
    mutate(
      high = round((high - 32) * 5 / 9),
      low  = round((low - 32) * 5 / 9)
    )
}


# -----------------------------------------------------------------------------
# 7. Validación: duplicados, faltantes y cobertura (requisito 6)
# -----------------------------------------------------------------------------

fechas_esperadas <- seq(as.Date("2024-01-01"), as.Date("2025-12-31"), by = "day")
fechas_faltantes <- as.Date(setdiff(fechas_esperadas, temperaturas$fecha),
                            origin = "1970-01-01")

validacion <- temperaturas %>%
  summarise(
    filas              = n(),
    fechas_unicas      = n_distinct(fecha),
    duplicados_fecha   = sum(duplicated(fecha)),
    faltantes_high     = sum(is.na(high)),
    faltantes_low      = sum(is.na(low)),
    high_menor_que_low = sum(high < low, na.rm = TRUE),
    fecha_minima       = min(fecha),
    fecha_maxima       = max(fecha)
  ) %>%
  mutate(
    dias_esperados   = length(fechas_esperadas),
    dias_sin_dato    = length(fechas_faltantes),
    cobertura_pct    = round(100 * fechas_unicas / dias_esperados, 1)
  )

validacion

# Fechas del periodo que no quedaron en la tabla
fechas_faltantes

# Si hubiera fechas repetidas, se conserva la primera aparición
temperaturas <- temperaturas %>% distinct(fecha, .keep_all = TRUE)


# -----------------------------------------------------------------------------
# 8. Resultado y archivo CSV (requisito 7)
# -----------------------------------------------------------------------------

head(temperaturas, 10)

write_csv(temperaturas, archivo_salida)
message("Resultado guardado en '", archivo_salida, "' (",
        nrow(temperaturas), " filas).")
