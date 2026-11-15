# graficos.R - Gráficos de highcharter y formatos de números.
# Los gráficos de precio son series de tiempo: el eje horizontal muestra la
# fecha de cada ejecución del scraper y hay una serie (un color fijo) por comercio.
#
# v1.0

# ---- 1. Formatos (COP, punto de miles y coma decimal) ---------------------

fmt_cop <- function(x) {
  ifelse(is.na(x), "—", paste0("$ ", formatC(round(x), format = "d", big.mark = ".", decimal.mark = ",")))
}

fmt_pct <- function(x, digits = 1) {
  ifelse(is.na(x), "—",
         paste0(formatC(x, format = "f", digits = digits, big.mark = ".", decimal.mark = ","), " %"))
}

color_comercio <- function(comercio) {
  col <- COLORES[comercio]
  ifelse(is.na(col), "#555555", col)
}

# ---- 2. Series de tiempo --------------------------------------------------

# d: tabla con id_ejecucion, fecha_consulta, comercio y la columna "valor".
# Cada ejecución es un punto del eje horizontal (etiquetado con su fecha);
# si un comercio no tiene dato en una ejecución, queda un hueco.
hc_series_ejecuciones <- function(d, valor, titulo, y_titulo, subtitulo = NULL,
                                  decimales = 0) {
  ejec <- d[!duplicated(d$id_ejecucion), c("id_ejecucion", "fecha_consulta")]
  ejec <- ejec[order(ejec$id_ejecucion), ]
  etiquetas <- etiquetas_ejecucion(ejec)

  hc <- highcharter::highchart() |>
    highcharter::hc_chart(type = "line") |>
    highcharter::hc_title(text = titulo) |>
    highcharter::hc_xAxis(categories = as.list(etiquetas),
                          title = list(text = "Fecha de la ejecución")) |>
    highcharter::hc_yAxis(title = list(text = y_titulo)) |>
    highcharter::hc_plotOptions(series = list(marker = list(enabled = TRUE, radius = 5))) |>
    highcharter::hc_tooltip(shared = TRUE, valueDecimals = decimales) |>
    highcharter::hc_credits(enabled = FALSE)

  if (!is.null(subtitulo)) hc <- highcharter::hc_subtitle(hc, text = subtitulo)

  for (com in sort(unique(d$comercio))) {
    v <- d[d$comercio == com, ]
    y <- v[[valor]][match(ejec$id_ejecucion, v$id_ejecucion)]
    hc <- highcharter::hc_add_series(hc, name = com, data = as.list(y),
                                     color = unname(color_comercio(com)))
  }
  hc
}

# ---- 3. Distribución de precios por comercio ------------------------------

# Caja de precios por comercio (bigotes de Tukey) con los atípicos como puntos.
hc_distribucion_precios <- function(d, titulo, subtitulo = NULL) {
  comercios <- sort(unique(d$comercio))

  cajas <- lapply(comercios, function(com) {
    p <- d$precio[d$comercio == com]
    e <- grDevices::boxplot.stats(p)
    list(low = e$stats[1], q1 = e$stats[2], median = e$stats[3],
         q3 = e$stats[4], high = e$stats[5],
         color = unname(color_comercio(com)))
  })

  atipicos <- unlist(lapply(seq_along(comercios), function(i) {
    p <- d$precio[d$comercio == comercios[i]]
    lapply(grDevices::boxplot.stats(p)$out, function(y) list(x = i - 1, y = y))
  }), recursive = FALSE)

  hc <- highcharter::highchart() |>
    highcharter::hc_title(text = titulo) |>
    highcharter::hc_xAxis(categories = as.list(comercios)) |>
    highcharter::hc_yAxis(title = list(text = "Precio (COP)")) |>
    highcharter::hc_legend(enabled = FALSE) |>
    highcharter::hc_credits(enabled = FALSE) |>
    highcharter::hc_add_series(name = "Precio (COP)", type = "boxplot", data = cajas)

  if (!is.null(subtitulo)) hc <- highcharter::hc_subtitle(hc, text = subtitulo)
  if (length(atipicos) > 0) {
    hc <- highcharter::hc_add_series(hc, name = "Atípicos", type = "scatter",
                                     data = atipicos, color = "#6b7280",
                                     marker = list(radius = 3))
  }
  hc
}
