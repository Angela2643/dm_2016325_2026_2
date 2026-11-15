# scraper.R - Descarga las páginas de los comercios y extrae los datos.
# (Módulo 2: el botón de la app llama a estas funciones; no se copian.)
#
# v2.0 - Taller 2.
# Novedades respecto al Taller 1:
#  - Sin setwd() ni rstudioapi: todas las rutas son relativas a taller_2/.
#  - El HTML descargado se guarda como <Sitio>_<consulta><sufijo>.html.
#    La lectura del 10 de octubre quedó sin sufijo (Carulla_cereales.html);
#    la lectura de hoy usa el sufijo "2" (Carulla_cereales2.html), la
#    siguiente "3", etc.
#  - raw/manifiesto.csv guarda la hora y la URL de cada descarga, para que
#    el modo sin conexión recupere la fecha real de la consulta.
#  - Se corrigieron dos errores que impedían la ejecución en línea:
#    verificar_chrome() no estaba definida y extraer_producto() se llamaba
#    con un argumento (online) que no existía. Los selectores NO se tocaron.
#  - Este archivo solo descarga y extrae. Validar e insertar en SQLite se
#    hace en sql_consult.R.
#
# Uso como script (descarga las 24 páginas con el sufijo SUFIJO_EJECUCION):
#   Rscript scraper.R
# Dentro de la app solo se cargan las funciones (options(taller2.ejecutar = FALSE)).

# ---- 1. Paquetes ----------------------------------------------------------

paquetes_scraper <- c("rvest", "xml2", "dplyr", "stringr", "tibble", "readr")

faltan <- setdiff(paquetes_scraper, rownames(installed.packages()))
if (length(faltan) > 0) {
  stop("Faltan paquetes: ", paste(faltan, collapse = ", "),
       ". Ejecute renv::restore() o install.packages().")
}
invisible(lapply(paquetes_scraper, library, character.only = TRUE))

# chromote NO se carga aquí: solo hace falta para descargar en línea y en un
# servidor publicado normalmente no existe. Se revisa en scraper_disponible().

# ---- 2. Configuración -----------------------------------------------------

# Carpeta con las copias crudas (relativa a taller_2/).
DIR_RAW <- "raw"

# Consultas (subcategorías) de la categoría "Alimentos y snacks".
CONSULTAS <- c(
  "frutos_secos", "granola", "chocorramo", "barras_cereal",
  "gansito", "conserva", "cereales", "galletas"
)

# Buenas prácticas de scraping (Módulo 4):
PAUSA_SEG        <- 10    # pausa entre peticiones
MAX_PETICIONES   <- 40    # tope de peticiones por ejecución
INTENTOS         <- 3     # reintentos por página
USER_AGENT <- getOption(
  "taller2.user_agent",
  "Mozilla/5.0 (compatible; TallerMineriaDatos-UNAL/2.0; uso academico)"
)
# Si un comercio bloquea este agente, se apaga con options(taller2.user_agent = NULL)
# antes de ejecutar: se usará el agente por defecto de Chrome sin cabeza.

# Sufijo de la lectura de hoy (Taller 2). Solo se usa al correr el script.
SUFIJO_EJECUCION <- "2"

# precio_final: selectores en orden de prioridad. Gana el primero que exista.
# precio_previo: precio antes del descuento. Es NA si no hay descuento.
# previo_solo_con_primero: si es TRUE, el precio previo solo cuenta
#   cuando existe el primer selector de precio_final (caso Exito).
SITIOS <- list(
  Jumbo = list(
    url      = function(q) paste0("https://www.jumbocolombia.com/search?query=", q, "&type=term"),
    # Estas clases llevan hash. Actualicelas si el sitio cambia.
    tarjeta  = ".jumbo-ds-ProductCardstyles-1szk4ok",
    titulo   = ".jumbo-ds-ProductCardstyles-1szk4ol",
    precio_final  = c(".jumbo-ds-ProductCardstyles-1szk4on"),
    precio_previo = ".jumbo-ds-ProductCardstyles-1szk4oo",
    marca_producto = ".jumbo-ds-ProductCardstyles-1szk4om",
    previo_solo_con_primero = FALSE,
    scroll   = TRUE
  ),
  Carulla = list(
    url      = function(q) paste0("https://www.carulla.com/s?q=", q, "&sort=score_desc&page=0"),
    tarjeta  = "[class*='productCard_contentInfo']",
    titulo   = "[class*='styles_name']",
    precio_final  = c("[class*='ProductPrice_container__price']"),
    precio_previo = "[class*='priceSection_container-promotion_price-dashed']",
    marca_producto = NA_character_,
    previo_solo_con_primero = FALSE,
    scroll   = FALSE
  ),
  Exito = list(
    url      = function(q) paste0("https://www.exito.com/s?q=", q, "&sort=score_desc&page=0"),
    tarjeta  = "[class*='productCard_contentInfo']",
    titulo   = "[class*='styles_name']",
    # Con descuento: price_fs-price es el final y ProductPrice es el original.
    # Sin descuento: ProductPrice es el final.
    precio_final  = c("[class*='price_fs-price']",
                      "[class*='ProductPrice_container__price']"),
    precio_previo = "[class*='ProductPrice_container__price']",
    marca_producto = NA_character_,
    previo_solo_con_primero = TRUE,
    scroll   = FALSE
  )
)

# ---- 3. Utilidades de texto -----------------------------------------------

# Extrae el texto de un selector dentro de cada tarjeta. Devuelve NA si falta.
texto_selector <- function(nodo, selector) {
  if (is.na(selector)) return(rep(NA_character_, length(nodo)))
  nodo %>%
    rvest::html_element(selector) %>%
    rvest::html_text2()
}

# Convierte texto de precio a número. Formato colombiano: "$ 12.900" -> 12900
limpiar_precio <- function(x) {
  readr::parse_number(
    x,
    locale = readr::locale(decimal_mark = ",", grouping_mark = ".")
  )
}

# Extracción de marcas en mayúsculas (Carulla y Exito no traen la marca aparte).
extraer_marca <- function(x) {
  patron <- "(?<!\\p{L})\\p{Lu}{2,}(?:\\s+\\p{Lu}{2,})*(?!\\p{L})"
  sapply(x, function(t) {
    if (is.na(t)) return(NA_character_)
    m <- regmatches(t, regexpr(patron, t, perl = TRUE))
    if (length(m) == 0) NA_character_ else m
  }, USE.NAMES = FALSE)
}

# Gramaje del título, en gramos (kg se convierte).
extraer_gramos <- function(x) {
  x <- ifelse(is.na(x), "", x)
  patron <- "(?i)(?<![\\d.,])(\\d+(?:[.,]\\d+)?)\\s*(kg|grs?|gramos?|g)\\b"
  m <- regmatches(x, regexec(patron, x, perl = TRUE))
  sapply(m, function(v) {
    if (length(v) == 0) return(NA_real_)
    num <- as.numeric(sub(",", ".", v[2]))
    if (tolower(v[3]) == "kg") num * 1000 else num
  })
}

# Unidades por presentación (1 si el título no dice nada).
extraer_unidades <- function(x) {
  x <- ifelse(is.na(x), "", x)
  patron <- "(?i)(?<![\\d.,])(\\d+)\\s*(?:unds?|unid(?:ad(?:es)?)?|uds?)\\b"
  m <- regmatches(x, regexec(patron, x, perl = TRUE))
  sapply(m, function(v) if (length(v) == 0) 1 else as.numeric(v[2]))
}

# Marca, gramos y unidades para las filas recién extraídas.
completar_campos <- function(df) {
  if (nrow(df) == 0) {
    return(dplyr::mutate(df, gramos = numeric(), unidades = numeric()))
  }
  sin_marca <- is.na(df$marca_producto) | !nzchar(trimws(df$marca_producto))
  df$marca_producto[sin_marca] <- extraer_marca(df$titulo[sin_marca])
  df$gramos   <- extraer_gramos(df$titulo)
  df$unidades <- extraer_unidades(df$titulo)
  df
}

# ---- 4. Nombres de archivo y manifiesto -----------------------------------

# "Carulla_cereales2.html" -> sitio "Carulla", consulta "cereales", sufijo "2"
# Las consultas no llevan números, así que los dígitos finales son el sufijo.
nombre_raw <- function(sitio, consulta, sufijo = "") {
  paste0(sitio, "_", consulta, sufijo, ".html")
}

parsear_nombre_raw <- function(archivo) {
  base <- basename(archivo)
  m <- regmatches(base, regexec("^([^_]+)_(.+?)(\\d*)\\.html$", base))[[1]]
  if (length(m) == 0) return(NULL)
  list(sitio = m[2], consulta = m[3], sufijo = m[4])
}

# Archivos crudos disponibles en raw/ (una fila por archivo).
raw_disponibles <- function(dir_raw = DIR_RAW) {
  archivos <- list.files(dir_raw, pattern = "\\.html$", full.names = TRUE)
  filas <- lapply(archivos, function(a) {
    p <- parsear_nombre_raw(a)
    if (is.null(p) || !p$sitio %in% names(SITIOS)) return(NULL)
    tibble::tibble(archivo = a, sitio = p$sitio, consulta = p$consulta, sufijo = p$sufijo)
  })
  filas <- Filter(Negate(is.null), filas)
  if (length(filas) == 0) {
    return(tibble::tibble(archivo = character(), sitio = character(),
                          consulta = character(), sufijo = character()))
  }
  dplyr::bind_rows(filas)
}

hora_actual <- function() {
  format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z", tz = "America/Bogota")
}

ruta_manifiesto <- function(dir_raw = DIR_RAW) file.path(dir_raw, "manifiesto.csv")

# Una fila por descarga: permite reconstruir la hora de consulta sin conexión.
registrar_descarga <- function(archivo, sitio, consulta, sufijo, hora, url,
                               dir_raw = DIR_RAW) {
  fila <- tibble::tibble(
    archivo = basename(archivo), sitio = sitio, consulta = consulta,
    sufijo = sufijo, hora_consulta = hora, url = url
  )
  ruta <- ruta_manifiesto(dir_raw)
  readr::write_csv(fila, ruta, append = file.exists(ruta))
  invisible(fila)
}

# Hora de una copia cruda: manifiesto si existe; si no, fecha de modificación.
hora_de_archivo <- function(archivo, dir_raw = DIR_RAW) {
  ruta <- ruta_manifiesto(dir_raw)
  if (file.exists(ruta)) {
    man <- readr::read_csv(ruta, show_col_types = FALSE, col_types = readr::cols(.default = "c"))
    fila <- man[man$archivo == basename(archivo), , drop = FALSE]
    if (nrow(fila) > 0) return(fila$hora_consulta[nrow(fila)])
  }
  format(file.info(archivo)$mtime, "%Y-%m-%dT%H:%M:%S%z", tz = "America/Bogota")
}

# ---- 5. Descarga ----------------------------------------------------------

# ¿Se puede hacer scraping en línea en esta máquina? (Chrome + chromote)
scraper_disponible <- function() {
  if (!requireNamespace("chromote", quietly = TRUE)) return(FALSE)
  tryCatch({ chromote::chromote_info(); TRUE }, error = function(e) FALSE)
}

# Copia el HTML renderizado a un documento estático.
# Evita el error "No node with given id found": la página re-renderiza
# y los nodos vivos de Chrome quedan obsoletos.
# Repite la copia hasta encontrar nodos o vencer el tiempo.
obtener_doc_estable <- function(pagina_viva, selector, timeout = 20) {
  inicio <- Sys.time()
  doc <- NULL
  repeat {
    html_texto <- tryCatch(
      pagina_viva$session$Runtime$evaluate(
        "document.documentElement.outerHTML"
      )$result$value,
      error = function(e) NULL
    )

    if (is.character(html_texto) && nchar(html_texto) > 0) {
      doc <- xml2::read_html(html_texto)
      if (length(rvest::html_elements(doc, selector)) > 0) return(doc)
    }

    if (as.numeric(difftime(Sys.time(), inicio, units = "secs")) > timeout) return(doc)
    Sys.sleep(1)
  }
}

# Descarga UNA página y guarda su HTML en raw/. Devuelve archivo, hora y URL.
descargar_pagina <- function(sitio, consulta, sufijo = SUFIJO_EJECUCION,
                             timeout = 20, dir_raw = DIR_RAW) {

  if (!scraper_disponible()) {
    stop("Chrome o el paquete chromote no están disponibles en este equipo ",
         "(en un servidor publicado es lo normal). Use el modo sin conexión.")
  }

  cfg <- SITIOS[[sitio]]
  termino <- utils::URLencode(stringr::str_replace_all(consulta, "_", " "), reserved = TRUE)
  url <- cfg$url(termino)

  if (!is.null(USER_AGENT)) {
    chromote::set_chrome_args(c(chromote::default_chrome_args(),
                                paste0("--user-agent=", USER_AGENT)))
  }

  hora <- hora_actual()
  pagina_viva <- rvest::read_html_live(url)
  on.exit(try(pagina_viva$session$close(), silent = TRUE), add = TRUE)

  if (cfg$scroll) {
    Sys.sleep(3)
    pagina_viva$scroll_by(top = 2000)
    Sys.sleep(2)
  }

  doc <- obtener_doc_estable(pagina_viva, cfg$tarjeta, timeout)
  if (is.null(doc)) stop("La página no respondió o no se pudo leer.")

  dir.create(dir_raw, showWarnings = FALSE, recursive = TRUE)
  archivo <- file.path(dir_raw, nombre_raw(sitio, consulta, sufijo))
  xml2::write_html(doc, archivo)
  registrar_descarga(archivo, sitio, consulta, sufijo, hora, url, dir_raw)

  list(archivo = archivo, hora_consulta = hora, url = url)
}

# ---- 6. Extracción --------------------------------------------------------

tabla_vacia <- function() {
  tibble::tibble(
    titulo = character(),
    precio_texto = character(), precio = numeric(),
    precio_previo_texto = character(), precio_previo = numeric(),
    marca_producto = character(),
    tiene_descuento = logical(), descuento_pct = numeric(),
    consulta = character(), pagina = character(), hora_consulta = character(),
    pagina_consulta = character(), gramos = numeric(), unidades = numeric(),
    archivo_raw = character()
  )
}

# Lee un HTML (de raw/ o recién descargado) y devuelve una fila por producto.
extraer_desde_html <- function(archivo, sitio, consulta, hora_consulta, url = NA_character_) {

  if (!file.exists(archivo)) stop("No existe el archivo: ", archivo)
  cfg <- SITIOS[[sitio]]
  if (is.null(cfg)) stop("Sitio desconocido: ", sitio)

  if (is.na(url)) {
    termino <- utils::URLencode(stringr::str_replace_all(consulta, "_", " "), reserved = TRUE)
    url <- cfg$url(termino)
  }

  doc  <- xml2::read_html(archivo, encoding = "UTF-8")
  nodo <- rvest::html_elements(doc, cfg$tarjeta)
  if (length(nodo) == 0) return(tabla_vacia())

  titulo <- texto_selector(nodo, cfg$titulo)

  # Precio final: el primer selector con valor.
  finales <- lapply(cfg$precio_final, function(sel) texto_selector(nodo, sel))
  precio_texto <- do.call(dplyr::coalesce, finales)

  # Precio previo al descuento.
  precio_previo_texto <- texto_selector(nodo, cfg$precio_previo)
  if (cfg$previo_solo_con_primero) {
    precio_previo_texto[is.na(finales[[1]])] <- NA_character_
  }

  precio        <- limpiar_precio(precio_texto)
  precio_previo <- limpiar_precio(precio_previo_texto)

  df <- tibble::tibble(
    titulo              = titulo,
    precio_texto        = precio_texto,
    precio              = precio,
    precio_previo_texto = precio_previo_texto,
    precio_previo       = precio_previo,
    marca_producto      = texto_selector(nodo, cfg$marca_producto),
    tiene_descuento     = !is.na(precio_previo),
    descuento_pct       = round((1 - precio / precio_previo) * 100, 1),
    consulta            = consulta,
    pagina              = sitio,
    hora_consulta       = hora_consulta,
    pagina_consulta     = url
  )

  df <- completar_campos(df)
  df$archivo_raw <- file.path(basename(dirname(archivo)), basename(archivo))
  df
}

# ---- 7. Recolección de un comercio ----------------------------------------

# Recorre todas las consultas de UN comercio. Si una página falla, sigue con
# las demás y deja el motivo. El estado resume el resultado:
#   completa: todas las consultas devolvieron productos
#   parcial:  algunas fallaron
#   fallida:  ninguna funcionó
recolectar_comercio <- function(sitio, consultas = CONSULTAS, sufijo = SUFIJO_EJECUCION,
                                modo = c("online", "offline"),
                                pausa = PAUSA_SEG, dir_raw = DIR_RAW) {
  modo <- match.arg(modo)
  datos   <- list()
  errores <- character()
  peticiones <- 0
  ultimo_error <- "error desconocido"

  # Sin Chrome no tiene sentido reintentar cada página: se falla de una vez.
  if (modo == "online" && !scraper_disponible()) {
    msg <- "Chrome o chromote no están disponibles en este equipo."
    return(list(sitio = sitio, datos = tabla_vacia(), n_consultas = length(consultas),
                n_ok = 0, errores = setNames(rep(msg, length(consultas)), consultas),
                estado = "fallida"))
  }

  for (q in consultas) {
    resultado <- tryCatch({

      if (modo == "online") {
        peticiones <- peticiones + 1
        if (peticiones > MAX_PETICIONES) stop("Se superó el límite de peticiones por ejecución.")
        d <- NULL
        for (intento in seq_len(INTENTOS)) {
          d <- tryCatch(descargar_pagina(sitio, q, sufijo, dir_raw = dir_raw),
                        error = function(e) { ultimo_error <<- conditionMessage(e); NULL })
          if (!is.null(d)) break
          Sys.sleep(5)
        }
        if (is.null(d)) stop(ultimo_error)
        archivo <- d$archivo; hora <- d$hora_consulta; url <- d$url
        Sys.sleep(pausa)
      } else {
        archivo <- file.path(dir_raw, nombre_raw(sitio, q, sufijo))
        if (!file.exists(archivo)) stop("no existe ", basename(archivo), " en raw/")
        hora <- hora_de_archivo(archivo, dir_raw); url <- NA_character_
      }

      df <- extraer_desde_html(archivo, sitio, q, hora, url)
      if (nrow(df) == 0) stop("la página no trae productos (bloqueo o cambio de estructura)")
      df
    }, error = function(e) {
      errores[q] <<- conditionMessage(e)
      NULL
    })
    if (!is.null(resultado)) datos[[q]] <- resultado
  }

  n_ok <- length(datos)
  list(
    sitio   = sitio,
    datos   = if (n_ok > 0) dplyr::bind_rows(datos) else tabla_vacia(),
    n_consultas = length(consultas),
    n_ok    = n_ok,
    errores = errores,
    estado  = if (n_ok == length(consultas)) "completa" else if (n_ok > 0) "parcial" else "fallida"
  )
}

# ---- 8. Ejecución como script ---------------------------------------------

# Descarga todas las páginas con el sufijo SUFIJO_EJECUCION. Después se corre
# sql_consult.R, que lee esas copias y arma productos.sqlite.
if (isTRUE(getOption("taller2.ejecutar", TRUE))) {
  if (!scraper_disponible()) {
    stop("Chrome o el paquete chromote no están disponibles. Instale Google Chrome ",
         "y chromote (install.packages('chromote')) y vuelva a ejecutar.")
  }
  for (s in names(SITIOS)) {
    message("Comercio: ", s)
    res <- recolectar_comercio(s, CONSULTAS, SUFIJO_EJECUCION, modo = "online")
    message("  ", res$n_ok, " de ", res$n_consultas, " consultas (", res$estado, ")")
    for (q in names(res$errores)) message("  - ", q, ": ", res$errores[[q]])
  }
}
