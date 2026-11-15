# app_server.R - Lógica de la aplicación (la interfaz está en app_ui.R).
# No contiene SQL: todas las consultas salen de db.R (Módulo 3).
#
# Este archivo termina con la función "server" para que app.R la reciba con
#   server <- source("app_server.R", local = TRUE)$value

`%||%` <- function(a, b) if (is.null(a)) b else a

# Etiqueta de una ejecución para los menús: "#2 · 2026-11-11".
etiqueta_menu <- function(ej) {
  setNames(ej$id_ejecucion, paste0("#", ej$id_ejecucion, " · ", ej$etiqueta))
}

server <- function(input, output, session) {

  # ---- Conexión (una por sesión, se cierra al terminar) ---------------------

  if (!file.exists(ruta_base())) {
    showModal(modalDialog(
      title = "No se encontró la base de datos",
      "Falta el archivo productos.sqlite. Genérelo con Rscript sql_consult.R ",
      "(ver README.md) y reinicie la aplicación.",
      easyClose = FALSE, footer = NULL))
    return(invisible(NULL))
  }
  con <- abrir_con()
  session$onSessionEnded(function() cerrar_con(con))

  # rv$version sube cada vez que una actualización termina: invalida el caché.
  rv <- reactiveValues(version = 0, resumen = NULL, mensaje = NULL)

  # ---- Opciones de los filtros ----------------------------------------------

  opciones <- reactive({
    rv$version
    db_opciones(con)
  })

  presentaciones <- reactive({
    rv$version
    db_presentaciones(con)
  })

  observeEvent(opciones(), {
    o  <- opciones()
    ej <- o$ejecuciones
    ultima <- if (nrow(ej) > 0) max(ej$id_ejecucion) else NULL

    updateSelectInput(session, "f_ejecuciones", choices = etiqueta_menu(ej), selected = ultima)
    updateSelectInput(session, "f_comercios", choices = o$comercios)
    updateSelectInput(session, "f_subcategorias",
                      choices = setNames(o$subcategorias, gsub("_", " ", o$subcategorias)))
    updateSelectizeInput(session, "f_marcas", choices = o$marcas, server = TRUE)
    updateSliderInput(session, "f_precio", min = floor(o$precio[["minimo"]]),
                      max = ceiling(o$precio[["maximo"]]),
                      value = c(floor(o$precio[["minimo"]]), ceiling(o$precio[["maximo"]])))

    # Cambios de precio: por defecto las dos ejecuciones más recientes.
    updateSelectInput(session, "cmb_a", choices = etiqueta_menu(ej),
                      selected = if (nrow(ej) >= 2) ej$id_ejecucion[nrow(ej) - 1] else ultima)
    updateSelectInput(session, "cmb_b", choices = etiqueta_menu(ej), selected = ultima)
    updateSelectInput(session, "cb_ejec", choices = etiqueta_menu(ej), selected = ultima)
  })

  observeEvent(presentaciones(), {
    p <- presentaciones()
    nombres <- setNames(p$id_presentacion, p$producto)
    updateSelectInput(session, "producto", choices = nombres)
    updateSelectizeInput(session, "cb_prod", choices = nombres, selected = p$id_presentacion)
  })

  observeEvent(input$f_limpiar, {
    o <- opciones()
    updateSelectInput(session, "f_ejecuciones", selected = max(o$ejecuciones$id_ejecucion))
    updateSelectInput(session, "f_comercios", selected = character())
    updateSelectInput(session, "f_subcategorias", selected = character())
    updateSelectizeInput(session, "f_marcas", selected = character())
    updateSliderInput(session, "f_precio",
                      value = c(floor(o$precio[["minimo"]]), ceiling(o$precio[["maximo"]])))
    updateCheckboxInput(session, "f_promo", value = FALSE)
    updateCheckboxInput(session, "f_comparables", value = FALSE)
    updateTextInput(session, "f_busqueda", value = "")
  })

  # ---- Filtros combinables --------------------------------------------------

  busqueda <- debounce(reactive(input$f_busqueda), 600)

  filtros <- reactive({
    req(input$f_precio)
    list(
      comercios        = input$f_comercios %||% character(),
      subcategorias    = input$f_subcategorias %||% character(),
      marcas           = input$f_marcas %||% character(),
      precio           = input$f_precio,
      ejecuciones      = as.integer(input$f_ejecuciones),
      solo_promo       = isTRUE(input$f_promo),
      solo_comparables = isTRUE(input$f_comparables),
      busqueda         = sanitizar_texto(busqueda())
    )
  })

  # Un solo reactive() alimenta la tabla, los indicadores y el gráfico de
  # distribución; el resultado se guarda en caché hasta que cambie un filtro
  # o termine una actualización.
  datos <- reactive({
    db_productos(con, filtros())
  }) |> bindCache(filtros(), rv$version)

  indicadores <- reactive({
    db_indicadores(con, filtros())
  }) |> bindCache(filtros(), rv$version)

  ultima <- reactive({
    rv$version
    db_ultima_ejecucion(con)
  })

  ahorro <- reactive({
    u <- ultima()
    req(nrow(u) > 0)
    db_ahorro_presentaciones(con, u$id_ejecucion)
  }) |> bindCache(ultima()$id_ejecucion, rv$version)

  # ---- Indicadores (todos calculados con SQL en db.R) -----------------------

  output$aviso_base <- renderUI({
    if (nrow(ultima()) == 0) {
      div(class = "alert alert-warning",
          "La base todavía no tiene ejecuciones. Ejecute sql_consult.R o use «Actualizar».")
    }
  })

  output$kpi_ejec <- renderText({
    u <- ultima(); req(nrow(u) > 0)
    u$fecha_consulta
  })
  output$kpi_ejec_nota <- renderText({
    u <- ultima(); req(nrow(u) > 0)
    paste0("Ejecución #", u$id_ejecucion, " · ", u$n_obs, " observaciones")
  })

  output$kpi_estado <- renderText({
    u <- ultima(); req(nrow(u) > 0)
    u$estado
  })
  output$kpi_estado_nota <- renderText({
    u <- ultima(); req(nrow(u) > 0)
    paste("Origen:", u$modo)
  })

  output$kpi_obs <- renderText({
    i <- indicadores()
    format(i$n_obs, big.mark = ".")
  })
  output$kpi_obs_nota <- renderText({
    i <- indicadores()
    paste0(format(i$n_productos, big.mark = "."), " anuncios distintos · ",
           i$fecha_desde, if (!identical(i$fecha_desde, i$fecha_hasta)) paste(" a", i$fecha_hasta))
  })

  output$kpi_mediana <- renderText(fmt_cop(indicadores()$mediana_precio))
  output$kpi_mediana_nota <- renderText({
    i <- indicadores()
    paste("Filtro actual ·", i$fecha_desde)
  })

  output$kpi_promo <- renderText(fmt_pct(indicadores()$pct_promocion))
  output$kpi_promo_nota <- renderText({
    i <- indicadores()
    paste("Del total filtrado ·", i$fecha_desde)
  })

  output$kpi_ahorro <- renderText({
    a <- ahorro(); req(nrow(a) > 0)
    fmt_cop(max(a$ahorro_cop))
  })
  output$kpi_ahorro_nota <- renderText({
    a <- ahorro(); req(nrow(a) > 0)
    mejor <- a[which.max(a$ahorro_cop), ]
    paste0(mejor$producto, " (", fmt_pct(mejor$ahorro_pct), ") · ejec. #", ultima()$id_ejecucion)
  })

  output$kpi_cambios <- renderText({
    u <- ultima(); req(nrow(u) > 0)
    n_ejec <- nrow(db_ejecuciones(con))
    if (n_ejec < 2) "—" else format(db_n_cambios(con, u$id_ejecucion), big.mark = ".")
  })
  output$kpi_cambios_nota <- renderText({
    u <- ultima(); req(nrow(u) > 0)
    if (nrow(db_ejecuciones(con)) < 2) "Se necesitan dos ejecuciones" else
      paste0("Anuncios con precio distinto al de la ejecución anterior (#", u$id_ejecucion, ")")
  })

  output$tabla_comercio <- renderTable({
    d <- db_resumen_comercio(con, filtros())
    validate(need(nrow(d) > 0, "No hay datos para los filtros elegidos. Amplíe los filtros."))
    names(d) <- c("Comercio", "Observaciones", "Anuncios distintos", "En promoción (%)", "Precio promedio (COP)")
    d
  }, digits = 1, na = "—")

  output$tabla_mediana <- renderTable({
    d <- db_mediana_subcategoria(con, filtros())
    validate(need(nrow(d) > 0, "No hay datos para los filtros elegidos."))
    d$subcategoria <- gsub("_", " ", d$subcategoria)
    d$mediana_precio <- fmt_cop(d$mediana_precio)
    names(d) <- c("Subcategoría", "Observaciones", "Mediana (COP)")
    d
  })

  # ---- Gráficos (highcharter) -----------------------------------------------

  output$g_distribucion <- highcharter::renderHighchart({
    d <- datos()
    validate(need(nrow(d) > 0, "No hay datos para los filtros elegidos. Amplíe los filtros."))
    periodo <- paste(unique(d$fecha_consulta), collapse = ", ")
    hc_distribucion_precios(d, "Distribución de precios (COP)",
                            subtitulo = paste("Ejecuciones:", periodo))
  })

  output$g_canasta <- highcharter::renderHighchart({
    d <- db_serie_canasta(con)
    validate(need(nrow(d) > 0, "Ningún comercio tiene los 8 productos en una misma ejecución."))
    hc_series_ejecuciones(d, "total_cop", "Costo de la canasta de 8 productos (1 unidad de cada uno)",
                          "COP", subtitulo = "Solo comercios con los 8 productos en esa ejecución")
  }) |> bindCache(rv$version)

  serie_producto <- reactive({
    req(input$producto)
    db_serie_comparable(con, input$producto)
  }) |> bindCache(input$producto, rv$version)

  nombre_producto <- reactive({
    p <- presentaciones()
    p$producto[p$id_presentacion == input$producto]
  })

  output$g_precio <- highcharter::renderHighchart({
    d <- serie_producto()
    validate(need(nrow(d) > 0, "No hay observaciones de este producto."))
    hc_series_ejecuciones(d, "precio", nombre_producto(), "Precio del empaque (COP)")
  })

  output$g_unitario <- highcharter::renderHighchart({
    d <- serie_producto()
    validate(need(nrow(d) > 0, "No hay observaciones de este producto."))
    if (identical(input$unidad_precio, "und")) {
      d$valor <- d$precio_por_unidad
      etiqueta <- "COP por unidad del empaque"
    } else {
      d$valor <- d$precio_unitario * 100
      etiqueta <- paste0("COP por 100 ", d$unidad_medida[1])
    }
    hc_series_ejecuciones(d, "valor", nombre_producto(), etiqueta,
                          subtitulo = "Una sola unidad de medida por gráfico", decimales = 1)
  })

  # ---- Cambios de precio entre dos ejecuciones ------------------------------

  cambios <- reactive({
    req(input$cmb_a, input$cmb_b, input$cmb_umbral)
    validate(
      need(nrow(db_ejecuciones(con)) >= 2,
           "Se necesitan al menos dos ejecuciones con datos para comparar precios."),
      need(input$cmb_a != input$cmb_b, "Elija dos ejecuciones distintas.")
    )
    db_cambios(con, as.integer(input$cmb_a), as.integer(input$cmb_b), input$cmb_umbral)
  })

  output$cmb_resumen <- renderText({
    d <- cambios()
    paste0("Subieron: ", sum(d$estado == "subió"), " · Bajaron: ", sum(d$estado == "bajó"),
           " · Iguales: ", sum(d$estado == "igual"), " · Nuevos: ", sum(d$estado == "nuevo"),
           " · No observados: ", sum(d$estado == "no observado"),
           " · Variaciones grandes (≥ ", input$cmb_umbral, " %): ", sum(d$variacion_grande))
  })

  output$tabla_cambios <- DT::renderDataTable({
    d <- cambios()
    validate(need(nrow(d) > 0, "No hay anuncios para comparar."))
    tabla <- data.frame(
      Comercio = d$comercio, Anuncio = d$titulo,
      `Precio anterior (COP)` = d$precio_a, `Precio nuevo (COP)` = d$precio_b,
      `Cambio (COP)` = d$cambio_cop, `Cambio (%)` = d$cambio_pct,
      Estado = d$estado, grande = d$variacion_grande,
      check.names = FALSE)
    DT::datatable(tabla, rownames = FALSE, options = list(
      pageLength = 15, columnDefs = list(list(visible = FALSE, targets = 7)),
      language = list(url = "//cdn.datatables.net/plug-ins/1.10.11/i18n/Spanish.json"))) |>
      DT::formatCurrency(c("Precio anterior (COP)", "Precio nuevo (COP)", "Cambio (COP)"),
                         currency = "$ ", digits = 0, mark = ".", dec.mark = ",") |>
      DT::formatStyle("Estado", valueColumns = "grande",
                      backgroundColor = DT::styleEqual(1, "#fde68a"),
                      fontWeight = DT::styleEqual(1, "bold"))
  })

  # ---- Canasta --------------------------------------------------------------

  output$cb_cantidades <- renderUI({
    ids <- input$cb_prod
    req(ids)
    p <- presentaciones()
    nombres <- setNames(p$producto, p$id_presentacion)
    tagList(lapply(ids, function(id) {
      numericInput(paste0("cant_", id), paste("Cantidad:", nombres[[id]]),
                   value = isolate(input[[paste0("cant_", id)]]) %||% 1,
                   min = 1, max = 20, step = 1)
    }))
  })

  cantidades <- reactive({
    ids <- input$cb_prod
    req(ids)
    vapply(ids, function(id) {
      v <- input[[paste0("cant_", id)]]
      if (is.null(v) || is.na(v) || v < 1) 1L else as.integer(min(v, 20))
    }, integer(1))
  })

  canasta <- reactive({
    req(input$cb_ejec, input$cb_prod)
    list(
      totales = db_canasta(con, as.integer(input$cb_ejec), input$cb_prod, cantidades()),
      mixta   = db_canasta_mixta(con, as.integer(input$cb_ejec), input$cb_prod, cantidades())
    )
  })

  resumen_cb <- reactive({
    cb <- canasta()
    resumen_canasta(cb$totales, cb$mixta, length(input$cb_prod))
  })

  output$tabla_canasta <- renderTable({
    t <- canasta()$totales
    data.frame(
      Comercio = t$comercio,
      `Total (COP)` = ifelse(is.na(t$total_cop),
                             paste0("Incompleta: tiene ", t$n_encontrados, " de ", t$n_seleccionados,
                                    " productos"),
                             fmt_cop(t$total_cop)),
      check.names = FALSE)
  })

  output$cb_unico <- renderText(fmt_cop(resumen_cb()$mejor_unico))
  output$cb_unico_nota <- renderText({
    r <- resumen_cb()
    if (is.na(r$comercio_unico)) "Ningún comercio tiene todos los productos" else r$comercio_unico
  })
  output$cb_mixto <- renderText(fmt_cop(resumen_cb()$mixto))
  output$cb_ahorro <- renderText(fmt_cop(resumen_cb()$ahorro_cop))
  output$cb_ahorro_nota <- renderText(fmt_pct(resumen_cb()$ahorro_pct))

  output$tabla_mixta <- renderTable({
    m <- canasta()$mixta
    validate(need(nrow(m) > 0, "No hay precios para los productos elegidos en esta ejecución."))
    data.frame(
      Producto = m$producto, Cantidad = m$cantidad,
      `Precio mínimo (COP)` = fmt_cop(m$precio_min),
      `Dónde comprarlo` = m$comercios_menor_precio,
      `Subtotal (COP)` = fmt_cop(m$subtotal_cop),
      check.names = FALSE)
  })

  # ---- Tabla de datos -------------------------------------------------------

  output$tabla_datos <- DT::renderDataTable({
    d <- datos()
    validate(need(nrow(d) > 0, "No hay datos para los filtros elegidos. Amplíe los filtros."))
    tabla <- data.frame(
      Fecha = d$fecha_consulta, Comercio = d$comercio, Anuncio = d$titulo, Marca = d$marca,
      Contenido = ifelse(is.na(d$contenido_total), NA,
                         paste(format(d$contenido_total, trim = TRUE), d$unidad_medida)),
      `Precio (COP)` = d$precio, `Precio unitario (COP)` = d$precio_unitario,
      Promoción = ifelse(d$tiene_descuento == 1, "Sí", "No"),
      Disponibilidad = ifelse(is.na(d$disponibilidad), "sin dato", d$disponibilidad),
      Enlace = paste0('<a href="', htmltools::htmlEscape(d$pagina_consulta, attribute = TRUE),
                      '" target="_blank" rel="noopener">Ver búsqueda</a>'),
      check.names = FALSE)
    DT::datatable(tabla, rownames = FALSE, escape = setdiff(names(tabla), "Enlace"),
                  filter = "top",
                  options = list(pageLength = 15,
                                 language = list(url = "//cdn.datatables.net/plug-ins/1.10.11/i18n/Spanish.json"))) |>
      DT::formatCurrency("Precio (COP)", currency = "$ ", digits = 0, mark = ".", dec.mark = ",") |>
      DT::formatRound("Precio unitario (COP)", digits = 2, mark = ".", dec.mark = ",")
  })

  output$descargar_csv <- downloadHandler(
    filename = function() paste0("productos_filtrados_", Sys.Date(), ".csv"),
    content = function(file) readr::write_excel_csv(datos(), file, na = "")
  )

  # ---- Actualización de precios (sin bloquear la app) -----------------------

  output$aviso_scraping <- renderUI({
    if (!SCRAPING_DISPONIBLE) {
      div(class = "alert alert-warning",
          strong("El scraping en línea no está disponible en este equipo."),
          " Esto es normal en un servidor publicado: los comercios suelen bloquearlo",
          " y no hay Chrome. Use «Reprocesar raw/ (sin conexión)».")
    }
  })

  # Cada tarea corre en otro proceso (future_promise). Allí se cargan los
  # módulos y se llama a actualizar_precios(), que usa scraper.R.
  nueva_tarea <- function(modo, boton) {
    ExtendedTask$new(function(ruta) {
      promises::future_promise({
        options(taller2.ejecutar = FALSE, taller2.ruta_db = ruta)
        for (f in c("validacion.R", "scraper.R", "db.R", "sql_consult.R")) {
          source(f, encoding = "UTF-8")
        }
        actualizar_precios(modo = modo)
      }, seed = NULL)
    }) |> bslib::bind_task_button(boton)
  }
  tarea_online  <- nueva_tarea("online",  "actualizar")
  tarea_offline <- nueva_tarea("offline", "offline")

  observeEvent(input$actualizar, tarea_online$invoke(ruta_base()))
  observeEvent(input$offline,    tarea_offline$invoke(ruta_base()))

  # Al terminar: guarda el resumen, invalida el caché y avisa al usuario.
  al_terminar <- function(tarea) {
    observeEvent(tarea$status(), {
      estado <- tarea$status()
      if (estado == "success") {
        res <- tarea$result()
        rv$resumen <- res$resumen
        rv$mensaje <- res$mensaje
        if (nrow(res$resumen) > 0) rv$version <- rv$version + 1
        showNotification(res$mensaje, duration = 12,
                         type = if (identical(res$estado, "completa")) "message" else "warning")
      } else if (estado == "error") {
        rv$mensaje <- "La actualización terminó con un error. La base no se modificó."
        showNotification(rv$mensaje, type = "error", duration = 12)
      }
    }, ignoreInit = TRUE)
  }
  al_terminar(tarea_online)
  al_terminar(tarea_offline)

  output$mensaje_actualizacion <- renderText(rv$mensaje %||% "")

  output$resumen_actualizacion <- renderTable({
    r <- rv$resumen
    req(r, nrow(r) > 0)
    names(r) <- c("Comercio", "Estado", "Productos recolectados", "Observaciones nuevas",
                  "Productos nuevos", "Cambios de precio", "No observados", "Rechazados", "Motivo")
    r
  }, na = "—")

  output$tabla_ejecuciones <- renderTable({
    rv$version
    e <- db_ejecuciones(con, solo_con_datos = FALSE)
    data.frame(Ejecución = e$id_ejecucion, Fecha = e$fecha_consulta, Origen = e$modo,
               Estado = e$estado, Observaciones = e$n_obs, check.names = FALSE)
  })
}

server
