# validacion.R - Validación de observaciones antes de insertar (Módulo 1.4)
# y de los textos que escribe el usuario (Módulo 4).
#
# v1.0: Reglas explícitas, una por una. Cada observación que no las cumple
# no se inserta: se devuelve aparte con el motivo del rechazo.
#
# Nota: el enunciado sugiere pointblank como ejemplo. Aquí las reglas se
# escriben con dplyr porque se necesita saber FILA por FILA cuál es el motivo
# del rechazo (pointblank entrega un resumen por regla, no el motivo por fila).

# ---- 1. Reglas por observación --------------------------------------------

# Recibe la tabla ya preparada (ver preparar_observaciones() en sql_consult.R)
# y devuelve una lista con las filas válidas y las rechazadas (con "motivo").
validar_observaciones <- function(obs) {

  vacio <- function(x) is.na(x) | !nzchar(trimws(as.character(x)))

  clave <- paste(obs$comercio, obs$subcategoria, obs$titulo_norm, sep = "|")

  motivo <- dplyr::case_when(
    is.na(obs$precio) | !is.finite(obs$precio) ~ "precio no numérico",
    obs$precio <= 0                            ~ "precio menor o igual a cero",
    vacio(obs$comercio)                        ~ "comercio ausente",
    vacio(obs$pagina_consulta)                 ~ "URL ausente",
    vacio(obs$hora_consulta)                   ~ "fecha y hora de consulta ausentes",
    vacio(obs$titulo)                          ~ "título ausente",
    duplicated(clave)                          ~ "observación duplicada en la misma ejecución",
    TRUE                                       ~ NA_character_
  )

  list(
    validas    = obs[is.na(motivo), , drop = FALSE],
    rechazadas = dplyr::mutate(obs[!is.na(motivo), , drop = FALSE],
                               motivo = motivo[!is.na(motivo)])
  )
}

# Tabla de control: cuántas filas incumplen cada regla (para el registro de
# la ejecución y para mostrarla al usuario si hace falta).
reporte_validacion <- function(obs) {
  v <- validar_observaciones(obs)
  if (nrow(v$rechazadas) == 0) {
    return(tibble::tibble(motivo = character(), n = integer()))
  }
  dplyr::count(v$rechazadas, motivo, name = "n", sort = TRUE)
}

# ---- 2. Presencia de los comparables en cada comercio ---------------------

# Regla de la ejecución (no de la fila): cada comercio debe tener los ocho
# productos comparables. Devuelve los id_presentacion que faltan.
presentaciones_faltantes <- function(ids_encontrados, ids_esperados) {
  setdiff(ids_esperados, unique(ids_encontrados))
}

# ---- 3. Texto escrito por el usuario --------------------------------------

# Longitud máxima y caracteres permitidos (letras, números, espacio y unos
# pocos signos). Se aplica ANTES de usar el texto en una consulta; aun así la
# consulta va parametrizada: esta validación es una segunda barrera.
sanitizar_texto <- function(x, max_chars = 60) {
  if (is.null(x) || length(x) == 0 || is.na(x[1])) return("")
  x <- substr(trimws(as.character(x[1])), 1, max_chars)
  gsub("[^\\p{L}\\p{N} .,'+/-]", "", x, perl = TRUE)
}
