# validacion.R -- reglas explicitas que toda observacion debe cumplir ANTES de insertarse
# (Taller 2, Modulo 1.4). Las que no las cumplen no entran a 'observaciones': se guardan en
# 'observaciones_rechazadas' con el motivo. Usa dplyr/stringr (cargados por scraper.R).

MIN_COMPARABLES <- 8L      # minimo de productos comparables que deben aparecer en cada comercio
RE_FECHA_ISO <- "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}[-+]\\d{2}:\\d{2}$"

# Convierte un precio en texto a numero (COP). Entiende "$ 12.900", "12,900", "1.299.900",
# "12.900,50" y el formato decimal con punto de Shopify ("62559.00").
limpiar_precio <- function(x) {
  x <- gsub("[^0-9.,]", "", as.character(x))
  out <- rep(NA_real_, length(x))
  for (i in seq_along(x)) {
    s <- x[i]
    if (is.na(s) || !nzchar(s)) next
    if (grepl("^\\d+\\.\\d{1,2}$", s)) {                 # 62559.00 -> decimal con punto
      out[i] <- as.numeric(s)
    } else {
      if (grepl(",\\d{1,2}$", s)) {                      # 12.900,50 -> coma decimal
        s <- sub(",", ".", gsub("\\.", "", s))
      } else {
        s <- gsub("[.,]", "", s)                         # 12.900 / 12,900 -> miles
      }
      out[i] <- suppressWarnings(as.numeric(s))
    }
  }
  out
}

# Reglas de validacion. 'df' = filas de un comercio (salida de estandarizar()).
# Devuelve list(validas = filas que pasan, rechazadas = filas con su motivo).
validar_observaciones <- function(df, comercio, fecha_consulta) {
  vacio <- tibble(sku = character(), nombre_original = character(), precio = numeric(),
                  disponible = integer(), motivo = character())
  n <- nrow(df)
  if (n == 0) return(list(validas = df, rechazadas = vacio))
  motivo <- rep(NA_character_, n)
  # Registra el PRIMER motivo por el que falla cada fila.
  marcar <- function(falla, texto) {
    falla[is.na(falla)] <- TRUE
    texto <- rep_len(texto, n)
    sel <- falla & is.na(motivo)
    motivo[sel] <<- texto[sel]
    invisible(NULL)
  }
  marcar(rep(is.na(comercio) || !nzchar(comercio), n), "comercio ausente")
  marcar(rep(is.na(fecha_consulta) || !grepl(RE_FECHA_ISO, fecha_consulta), n),
         "fecha y hora de consulta ausente o fuera de ISO 8601")
  marcar(is.na(df$url) | !nzchar(df$url), "URL ausente")
  marcar(is.na(df$precio) | df$precio <= 0,
         ifelse(!is.na(df$disponible) & df$disponible == 0,
                "precio ausente (agotado segun el sitio)", "precio ausente o no positivo"))
  marcar(duplicated(df$sku), "observacion duplicada en la misma ejecucion")

  ok <- is.na(motivo)
  list(validas = df[ok, ],
       rechazadas = tibble(sku = df$sku[!ok], nombre_original = df$nombre_original[!ok],
                           precio = df$precio[!ok], disponible = df$disponible[!ok],
                           motivo = motivo[!ok]))
}

# Cuantos de los productos comparables definidos aparecen en la extraccion de un comercio
# (misma regla que asignar_comparables(): patron en el nombre + contenido en mL).
comparables_presentes <- function(df, definiciones = PRODUCTOS_COMUNES) {
  if (nrow(df) == 0) return(0L)
  base <- df[df$incluido == 1 & !is.na(df$contenido_valor) & df$contenido_unidad %in% "mL", ]
  hay <- vapply(seq_len(nrow(definiciones)), function(i) {
    d <- definiciones[i, ]
    x <- base[abs(base$contenido_valor - d$contenido) < 1e-9 &
              str_detect(base$nombre_estandar, regex(d$patron, ignore_case = TRUE)), ]
    if (!is.na(d$excluir))
      x <- x[!str_detect(x$nombre_estandar, regex(d$excluir, ignore_case = TRUE)), ]
    nrow(x) >= 1
  }, logical(1))
  sum(hay)
}
