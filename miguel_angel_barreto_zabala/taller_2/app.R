# app.R -- Aplicacion Shiny del Comparador de Precios (Taller 2, Mineria de Datos)
# Modulos cubiertos: actualizacion sin bloqueo (Modulo 2), acceso a datos/cache (Modulo 3),
# seguridad/consultas parametrizadas (Modulo 4), presentacion/diseno (Modulo 5) y analisis
# para el consumidor (Modulo 6). Toda consulta SQL vive en db.R; el scraping vive en scraper.R.

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(highcharter)
  library(DT)
  library(promises)
  library(future)
  library(dplyr)
  library(htmltools)
})

source("db.R")
source("validacion.R")

DB_PATH <- "comparador_precios.sqlite"
RAW_DIR <- "raw"

COLORES_COMERCIO <- c(
  "Farmatodo"         = "#1b9e77",
  "Colsubsidio"       = "#d95f02",
  "Farmacias Pasteur" = "#7570b3"
)

tryCatch(plan(multisession, workers = 1), error = function(e) plan(sequential))

# ------------------------------------------------------------------ utilidades UI
fmt_cop <- function(x, con_unidad = TRUE) {
  ifelse(
    is.na(x),
    "Sin dato",
    paste0(
      "$ ",
      format(round(x), big.mark = ".", decimal.mark = ",", trim = TRUE, scientific = FALSE),
      if (con_unidad) " COP" else ""
    )
  )
}

fmt_num <- function(x, dec = 1) {
  ifelse(
    is.na(x),
    "Sin dato",
    format(round(x, dec), big.mark = ".", decimal.mark = ",", nsmall = dec, trim = TRUE)
  )
}

limpiar_ansi <- function(x) {
  gsub("\033\\[[0-9;]*m", "", as.character(x))
}

fechas_raw_disponibles <- function(raw_dir = RAW_DIR) {
  if (!dir.exists(raw_dir)) return(character())
  comercios_dirs <- list.dirs(raw_dir, recursive = FALSE, full.names = TRUE)
  fechas <- unique(unlist(lapply(comercios_dirs, function(d) {
    sub_dirs <- list.dirs(d, recursive = FALSE, full.names = FALSE)
    sub_dirs[vapply(file.path(d, sub_dirs), function(p) {
      length(list.files(p, pattern = "\\.json\\.gz$")) > 0
    }, logical(1))]
  })))
  sort(fechas, decreasing = TRUE)
}

correr_recoleccion <- function(modo, fecha_dir = NULL, db = DB_PATH) {
  tryCatch({
    source("scraper.R")
    res <- if (identical(modo, "offline")) {
      recolectar_todo(db = db, offline = TRUE, fecha_dir = fecha_dir)
    } else {
      recolectar_todo(db = db, offline = FALSE)
    }
    if (any(res$estado %in% c("completa", "parcial"))) {
      tryCatch(asignar_comparables(db), error = function(e) NULL)
    }
    list(ok = TRUE, modo = modo, fecha_dir = fecha_dir, resumen = res)
  }, error = function(e) {
    list(ok = FALSE, modo = modo, fecha_dir = fecha_dir, error = limpiar_ansi(conditionMessage(e)))
  })
}

# Lectura inicial para poblar controles del sidebar sin abrir una conexion permanente global
init_opc <- local({
  con0 <- abrir_db(DB_PATH)
  on.exit(cerrar_db(con0), add = TRUE)
  opciones_filtros(con0)
})

choices_corridas <- if (nrow(init_opc$corridas) > 0) {
  setNames(init_opc$corridas$corrida, init_opc$corridas$etiqueta)
} else {
  character()
}
pmin_init <- if (length(init_opc$precio) >= 1 && !is.na(init_opc$precio["min"])) {
  floor(as.numeric(init_opc$precio["min"]) / 1000) * 1000
} else 0
pmax_init <- if (length(init_opc$precio) >= 2 && !is.na(init_opc$precio["max"])) {
  ceiling(as.numeric(init_opc$precio["max"]) / 1000) * 1000
} else 200000
choices_productos <- if (nrow(init_opc$productos) > 0) {
  setNames(init_opc$productos$id, init_opc$productos$nombre)
} else {
  character()
}

# ------------------------------------------------------------------ interfaz (bslib)
ui <- page_navbar(
  title = "Comparador de precios | Ocular y Ótico",
  id = "nav_principal",
  theme = bs_theme(
    version = 5,
    bootswatch = "flatly",
    primary = "#1b9e77",
    secondary = "#7570b3"
  ),
  sidebar = sidebar(
    width = 300,
    title = "Filtros de consulta",
    selectInput(
      "corrida",
      "Ejecución (corrida completa)",
      choices = choices_corridas,
      selected = if (length(choices_corridas)) choices_corridas[1] else NULL
    ),
    selectizeInput(
      "comercios",
      "Comercios",
      choices = init_opc$comercios,
      selected = init_opc$comercios,
      multiple = TRUE,
      options = list(placeholder = "Todos los comercios")
    ),
    selectizeInput(
      "subcategorias",
      "Subcategoría",
      choices = init_opc$subcategorias,
      selected = character(),
      multiple = TRUE,
      options = list(placeholder = "Todas las subcategorías")
    ),
    selectizeInput(
      "marcas",
      "Marca",
      choices = init_opc$marcas,
      selected = character(),
      multiple = TRUE,
      options = list(placeholder = "Todas las marcas")
    ),
    sliderInput(
      "precio",
      "Rango de precio (COP)",
      min = pmin_init,
      max = pmax_init,
      value = c(pmin_init, pmax_init),
      step = 1000,
      pre = "$",
      sep = "."
    ),
    checkboxInput("solo_promo", "Solo productos en promoción", value = FALSE),
    checkboxInput("solo_comp", "Solo productos comparables (12)", value = FALSE),
    textInput(
      "texto",
      "Buscar en nombre o descripción",
      value = "",
      placeholder = "Ej. systane, hialuronato..."
    ),
    uiOutput("aviso_busqueda"),
    actionButton("btn_limpiar", "Limpiar filtros", class = "btn-outline-secondary btn-sm w-100 mt-1"),
    hr(),
    div(
      class = "small text-muted",
      strong("Moneda:"), " COP (pesos colombianos).", br(),
      strong("Unidades:"), " mL o g según envase.", br(),
      uiOutput("badge_fecha_datos")
    )
  ),

  # 1) Resumen y graficos
  nav_panel(
    title = "Resumen y gráficos",
    icon = icon("chart-column"),
    uiOutput("banner_contexto"),
    layout_column_wrap(
      width = 1 / 3,
      fill = FALSE,
      value_box(
        title = "Productos incluidos (corrida)",
        value = textOutput("vb_productos"),
        p(textOutput("vb_productos_sub", inline = TRUE), class = "small mb-0"),
        showcase = icon("capsules"),
        theme = "primary"
      ),
      value_box(
        title = "Mediana del precio (COP)",
        value = textOutput("vb_mediana"),
        p(textOutput("vb_mediana_sub", inline = TRUE), class = "small mb-0"),
        showcase = icon("tag"),
        theme = "info"
      ),
      value_box(
        title = "Ahorro máximo entre comercios",
        value = textOutput("vb_ahorro"),
        p(textOutput("vb_ahorro_sub", inline = TRUE), class = "small mb-0"),
        showcase = icon("piggy-bank"),
        theme = "success"
      ),
      value_box(
        title = "Productos en promoción (%)",
        value = textOutput("vb_promo"),
        p(textOutput("vb_promo_sub", inline = TRUE), class = "small mb-0"),
        showcase = icon("percent"),
        theme = "warning"
      ),
      value_box(
        title = "Cambios de precio recientes",
        value = textOutput("vb_cambios"),
        p("Entre las 2 últimas corridas completas", class = "small mb-0"),
        showcase = icon("arrows-up-down"),
        theme = "secondary"
      ),
      value_box(
        title = "Última ejecución y observaciones",
        value = textOutput("vb_ultima"),
        p(textOutput("vb_obs_sub", inline = TRUE), class = "small mb-0"),
        showcase = icon("clock"),
        theme = "light"
      )
    ),
    layout_column_wrap(
      width = 1 / 2,
      card(
        full_screen = TRUE,
        card_header(
          div(
            class = "d-flex justify-content-between align-items-center flex-wrap gap-2",
            span("1. Evolución del precio de un producto comparable (COP)"),
            div(
              style = "min-width: 240px;",
              selectInput(
                "prod_evol",
                label = NULL,
                choices = choices_productos,
                selected = if (length(choices_productos)) choices_productos[1] else NULL,
                width = "100%"
              )
            )
          )
        ),
        card_body(highchartOutput("graf_evolucion", height = "340px"))
      ),
      card(
        full_screen = TRUE,
        card_header(
          div(
            class = "d-flex justify-content-between align-items-center flex-wrap gap-2",
            span("2. Precio por unidad de contenido entre comercios (COP/unidad)"),
            div(
              style = "min-width: 130px;",
              selectInput("unidad_comp", label = NULL, choices = "mL", selected = "mL", width = "100%")
            )
          )
        ),
        card_body(highchartOutput("graf_unitario", height = "340px"))
      ),
      card(
        full_screen = TRUE,
        card_header("3. Distribución de precios de la categoría por comercio (COP)"),
        card_body(highchartOutput("graf_distribucion", height = "350px"))
      ),
      card(
        full_screen = TRUE,
        card_header("4. Ahorro potencial (%) por presentación comparable"),
        card_body(highchartOutput("graf_ahorro", height = "350px"))
      )
    ),
    card(
      card_header("Mediana del precio por subcategoría (COP)"),
      card_body(tableOutput("tabla_mediana_subcat"))
    )
  ),

  # 2) Tabla de productos filtrados
  nav_panel(
    title = "Tabla de productos",
    icon = icon("table"),
    card(
      card_header(
        div(
          class = "d-flex justify-content-between align-items-center flex-wrap gap-2",
          span(textOutput("resumen_tabla_txt", inline = TRUE)),
          downloadButton("descargar_csv", "Descargar CSV filtrado", class = "btn-primary btn-sm")
        )
      ),
      card_body(
        uiOutput("alerta_tabla_vacia"),
        DTOutput("tabla_productos")
      )
    )
  ),

  # 3) Cambios de precio
  nav_panel(
    title = "Cambios de precio",
    icon = icon("arrow-trend-up"),
    card(
      card_header("Comparación entre dos ejecuciones (mismo anuncio en el mismo comercio)"),
      card_body(
        layout_column_wrap(
          width = 1 / 4,
          selectInput(
            "corrida_ant",
            "Ejecución anterior",
            choices = choices_corridas,
            selected = if (length(choices_corridas) >= 2) choices_corridas[2] else choices_corridas[1]
          ),
          selectInput(
            "corrida_nue",
            "Ejecución nueva",
            choices = choices_corridas,
            selected = if (length(choices_corridas)) choices_corridas[1] else NULL
          ),
          sliderInput(
            "umbral_cambio",
            "Umbral variación grande (%)",
            min = 1, max = 30, value = 5, step = 1, post = "%"
          ),
          selectInput(
            "filtro_tipo_cambio",
            "Filtrar por tipo de cambio",
            choices = c(
              "Todos" = "todos",
              "Subió" = "subio",
              "Bajó" = "bajo",
              "Nuevo" = "nuevo",
              "Dejó de observarse" = "dejo de observarse",
              "Sin cambio" = "igual"
            ),
            selected = "todos"
          )
        ),
        checkboxInput("solo_var_grandes", "Mostrar solo variaciones mayores o iguales al umbral", FALSE)
      )
    ),
    layout_column_wrap(
      width = 1 / 5,
      fill = FALSE,
      value_box("Subieron", textOutput("vb_subieron"), theme = "danger", showcase = icon("arrow-up")),
      value_box("Bajaron", textOutput("vb_bajaron"), theme = "success", showcase = icon("arrow-down")),
      value_box("Nuevos", textOutput("vb_nuevos"), theme = "info", showcase = icon("plus")),
      value_box("No observados", textOutput("vb_no_obs"), theme = "warning", showcase = icon("eye-slash")),
      value_box("Variaciones >= umbral", textOutput("vb_grandes"), theme = "primary", showcase = icon("bolt"))
    ),
    card(
      card_header("Detalle de cambios de precio (COP y %)"),
      card_body(DTOutput("tabla_cambios"))
    )
  ),

  # 4) Canasta
  nav_panel(
    title = "Canasta",
    icon = icon("basket-shopping"),
    div(
      class = "alert alert-warning mb-3",
      role = "alert",
      icon("triangle-exclamation"),
      strong(" Advertencia importante: "),
      "El costo de la canasta se calcula únicamente con los precios de la ejecución seleccionada y ",
      strong("no incluye costos de envío, montos mínimos de compra ni condiciones particulares de las promociones.")
    ),
    layout_columns(
      col_widths = c(4, 8),
      card(
        card_header("Armar canasta de productos comparables"),
        card_body(
          selectInput(
            "corrida_canasta",
            "Ejecución para cotizar (COP)",
            choices = choices_corridas,
            selected = if (length(choices_corridas)) choices_corridas[1] else NULL
          ),
          selectizeInput(
            "canasta_prods",
            "Productos comparables",
            choices = choices_productos,
            selected = head(unname(choices_productos), 3),
            multiple = TRUE,
            options = list(placeholder = "Selecciona al menos un producto...")
          ),
          uiOutput("canasta_cantidades_ui")
        )
      ),
      div(
        layout_column_wrap(
          width = 1 / 3,
          fill = FALSE,
          value_box("Costo mínimo (por producto)", textOutput("vb_canasta_min"), theme = "success", showcase = icon("coins")),
          value_box("Mejor comercio único completo", textOutput("vb_canasta_unico"), theme = "info", showcase = icon("store")),
          value_box("Ahorro comprando óptimo", textOutput("vb_canasta_ahorro"), theme = "primary", showcase = icon("piggy-bank"))
        ),
        card(
          card_header("Costo total de la canasta por comercio (COP)"),
          card_body(
            uiOutput("canasta_faltantes_ui"),
            tableOutput("tabla_canasta_comercios")
          )
        ),
        card(
          card_header("Compra óptima producto por producto (con empates)"),
          card_body(tableOutput("tabla_canasta_minimo"))
        )
      )
    )
  ),

  # 5) Actualizacion y estado
  nav_panel(
    title = "Actualización y estado",
    icon = icon("rotate"),
    layout_columns(
      col_widths = c(6, 6),
      card(
        card_header("Actualización en línea (web scraping)"),
        card_body(
          p("Ejecuta el módulo ", code("scraper.R"), " sin bloquear la interfaz, valida cada observación con ",
            code("validacion.R"), " e inserta en una transacción por comercio solo las observaciones nuevas."),
          p(class = "small text-muted",
            "Nota: si la aplicación corre en un servidor en la nube (por ejemplo shinyapps.io), algunos comercios ",
            "pueden bloquear peticiones o faltar la clave ", code("FARMATODO_ALGOLIA_KEY"),
            ". En ese caso, la falla se reporta por comercio y puedes usar el modo sin conexión."),
          input_task_button("btn_actualizar", "Actualizar precios en línea", icon = icon("sync"), class = "btn-primary")
        )
      ),
      card(
        card_header("Modo sin conexión (reprocesar copias de raw/)"),
        card_body(
          p("Reprocesa los JSON originales guardados en ", code("raw/"),
            " sin consultar los sitios web. Si la fecha ya existe en la base, no duplica observaciones."),
          selectInput("fecha_raw", "Fecha disponible en raw/", choices = fechas_raw_disponibles()),
          input_task_button("btn_offline", "Reprocesar desde raw/", icon = icon("folder-open"), class = "btn-secondary")
        )
      )
    ),
    uiOutput("resultado_actualizacion_ui"),
    card(
      card_header("Resumen de cambios en la última corrida"),
      card_body(tableOutput("tabla_resumen_act"))
    ),
    card(
      card_header("Estado actual de la última ejecución por comercio"),
      card_body(tableOutput("tabla_ultima_ejecucion"))
    )
  )
)

# ------------------------------------------------------------------ servidor
server <- function(input, output, session) {
  # Conexion controlada por sesion (se cierra al finalizar la sesion)
  con <- abrir_db(DB_PATH)
  session$onSessionEnded(function() cerrar_db(con))

  rv <- reactiveValues(
    version = 1L,
    ultimo_msg = NULL
  )

  # Tareas asincronas sin bloqueo (ExtendedTask + promises + future)
  tarea_online <- ExtendedTask$new(function() {
    future_promise(correr_recoleccion("online", NULL, DB_PATH))
  }) |> bind_task_button("btn_actualizar")

  tarea_offline <- ExtendedTask$new(function(fecha_dir) {
    future_promise(correr_recoleccion("offline", fecha_dir, DB_PATH))
  }) |> bind_task_button("btn_offline")

  observeEvent(input$btn_actualizar, {
    tarea_online$invoke()
  })

  observeEvent(input$btn_offline, {
    req(input$fecha_raw)
    tarea_offline$invoke(input$fecha_raw)
  })

  procesar_fin_tarea <- function(res) {
    rv$ultimo_msg <- res
    rv$version <- rv$version + 1L
    opc <- opciones_filtros(con)
    ch_cor <- if (nrow(opc$corridas) > 0) setNames(opc$corridas$corrida, opc$corridas$etiqueta) else character()
    if (length(ch_cor) > 0) {
      updateSelectInput(session, "corrida", choices = ch_cor, selected = ch_cor[1])
      updateSelectInput(session, "corrida_nue", choices = ch_cor, selected = ch_cor[1])
      updateSelectInput(session, "corrida_ant", choices = ch_cor,
                        selected = if (length(ch_cor) >= 2) ch_cor[2] else ch_cor[1])
      updateSelectInput(session, "corrida_canasta", choices = ch_cor, selected = ch_cor[1])
    }
    updateSelectInput(session, "fecha_raw", choices = fechas_raw_disponibles())
  }

  observeEvent(tarea_online$result(), {
    procesar_fin_tarea(tarea_online$result())
  })

  observeEvent(tarea_offline$result(), {
    procesar_fin_tarea(tarea_offline$result())
  })

  # Limpiar filtros
  observeEvent(input$btn_limpiar, {
    opc <- opciones_filtros(con)
    updateSelectizeInput(session, "comercios", selected = opc$comercios)
    updateSelectizeInput(session, "subcategorias", selected = character())
    updateSelectizeInput(session, "marcas", selected = character())
    updateSliderInput(session, "precio", value = c(pmin_init, pmax_init))
    updateCheckboxInput(session, "solo_promo", value = FALSE)
    updateCheckboxInput(session, "solo_comp", value = FALSE)
    updateTextInput(session, "texto", value = "")
  })

  # Validacion visual de entrada de texto libre
  output$aviso_busqueda <- renderUI({
    txt <- input$texto %||% ""
    limpio <- validar_busqueda(txt)
    if (nchar(trimws(txt)) > LONGITUD_MAX_BUSQUEDA) {
      div(class = "small text-warning mt-1",
          sprintf("Búsqueda recortada a %d caracteres.", LONGITUD_MAX_BUSQUEDA))
    } else if (!identical(trimws(txt), limpio) && nzchar(trimws(txt))) {
      div(class = "small text-warning mt-1",
          "Se ignoraron caracteres especiales no permitidos en la búsqueda.")
    }
  })

  # Etiqueta de fecha de corrida activa
  corrida_meta <- reactive({
    rv$version
    df <- corridas_disponibles(con)
    sel <- input$corrida
    if (is.null(sel) || !nzchar(sel) || nrow(df) == 0) return(NULL)
    df[df$corrida == sel, , drop = FALSE]
  })

  output$badge_fecha_datos <- renderUI({
    m <- corrida_meta()
    if (is.null(m) || nrow(m) == 0) return(span("Sin ejecuciones completas."))
    span(strong("Fecha de los datos: "), substr(m$inicio[1], 1, 16))
  })

  output$banner_contexto <- renderUI({
    m <- corrida_meta()
    fecha_txt <- if (!is.null(m) && nrow(m) > 0) paste0(substr(m$inicio[1], 1, 10), " ", substr(m$inicio[1], 12, 16), " (-05:00)") else "N/D"
    div(
      class = "alert alert-light border d-flex justify-content-between align-items-center flex-wrap gap-2 py-2 mb-3",
      span(
        icon("calendar-day"),
        strong(" Ejecución mostrada: "), fecha_txt,
        " | ", strong("Moneda: "), "COP",
        " | ", strong("Unidades: "), "mL / g"
      ),
      span(
        class = "small",
        span(style = paste0("color:", COLORES_COMERCIO["Farmatodo"], "; font-weight:600;"), "● Farmatodo  "),
        span(style = paste0("color:", COLORES_COMERCIO["Colsubsidio"], "; font-weight:600;"), "● Colsubsidio  "),
        span(style = paste0("color:", COLORES_COMERCIO["Farmacias Pasteur"], "; font-weight:600;"), "● Farmacias Pasteur")
      )
    )
  })

  # ---------------- Reactivos con cache (bindCache + rv$version) ----------------
  ind_reactivo <- reactive({
    req(input$corrida)
    indicadores(con, input$corrida)
  }) |> bindCache(rv$version, input$corrida, cache = "app")

  mediana_subcat_reactivo <- reactive({
    req(input$corrida)
    mediana_por_subcategoria(con, input$corrida)
  }) |> bindCache(rv$version, input$corrida, cache = "app")

  ahorro_reactivo <- reactive({
    req(input$corrida)
    ahorro_comparables(con, input$corrida)
  }) |> bindCache(rv$version, input$corrida, cache = "app")

  datos_filtrados <- reactive({
    req(input$corrida)
    pmin_val <- if (!is.null(input$precio) && length(input$precio) == 2) input$precio[1] else NULL
    pmax_val <- if (!is.null(input$precio) && length(input$precio) == 2) input$precio[2] else NULL
    productos_filtrados(
      con = con,
      corrida = input$corrida,
      comercios = input$comercios,
      subcategorias = input$subcategorias,
      marcas = input$marcas,
      pmin = pmin_val,
      pmax = pmax_val,
      solo_promo = isTRUE(input$solo_promo),
      solo_comparables = isTRUE(input$solo_comp),
      texto = input$texto %||% ""
    )
  }) |> bindCache(
    rv$version, input$corrida, input$comercios, input$subcategorias, input$marcas,
    input$precio, input$solo_promo, input$solo_comp, validar_busqueda(input$texto %||% ""),
    cache = "app"
  )

  # Actualizar unidades disponibles para Grafico 2 sin mezclar unidades
  observeEvent(list(rv$version, input$corrida), {
    req(input$corrida)
    uns <- unidades_comparables(con, input$corrida)
    if (length(uns) > 0) {
      sel <- if (!is.null(input$unidad_comp) && input$unidad_comp %in% uns) input$unidad_comp else uns[1]
      updateSelectInput(session, "unidad_comp", choices = uns, selected = sel)
    }
  })

  # ---------------- Indicadores (6 value boxes) ----------------
  output$vb_productos <- renderText({
    ind <- ind_reactivo()
    paste(ind$productos, "productos")
  })
  output$vb_productos_sub <- renderText({
    pc <- ind_reactivo()$por_comercio
    if (nrow(pc) == 0) return("Sin registros")
    paste(sprintf("%s: %d", pc$comercio, pc$productos), collapse = " | ")
  })
  output$vb_mediana <- renderText({
    fmt_cop(ind_reactivo()$mediana)
  })
  output$vb_mediana_sub <- renderText({
    paste("Corrida:", input$corrida)
  })
  output$vb_ahorro <- renderText({
    a <- ind_reactivo()$ahorro_max_pct
    if (is.na(a)) "Sin dato" else paste0(fmt_num(a, 1), " %")
  })
  output$vb_ahorro_sub <- renderText({
    p <- ind_reactivo()$ahorro_max_prod
    if (is.na(p)) "No disponible" else paste("Máx. en", p)
  })
  output$vb_promo <- renderText({
    p <- ind_reactivo()$pct_promocion
    if (is.na(p)) "Sin dato" else paste0(fmt_num(p, 1), " %")
  })
  output$vb_promo_sub <- renderText({
    pc <- ind_reactivo()$por_comercio
    paste(sum(pc$en_promocion, na.rm = TRUE), "en promoción en esta corrida")
  })
  output$vb_cambios <- renderText({
    paste(ind_reactivo()$cambios_ultima, "productos")
  })
  output$vb_ultima <- renderText({
    ue <- ind_reactivo()$ultima_ejecucion
    if (nrow(ue) == 0) return("Sin ejecuciones")
    comp <- sum(ue$estado == "completa")
    paste0(substr(max(ue$inicio), 1, 10), " (", comp, "/", nrow(ue), " completas)")
  })
  output$vb_obs_sub <- renderText({
    paste(ind_reactivo()$observaciones, "observaciones válidas acumuladas")
  })

  output$tabla_mediana_subcat <- renderTable({
    df <- mediana_subcat_reactivo()
    validate(need(nrow(df) > 0, "Sin datos para calcular medianas por subcategoría en esta corrida."))
    df |>
      mutate(
        Subcategoría = recode(subcategoria,
                              "lagrima_artificial" = "Lágrima artificial",
                              "oftalmico" = "Oftálmico",
                              "otico" = "Ótico"),
        `Mediana (COP)` = fmt_cop(mediana),
        `Productos incluidos` = as.integer(productos)
      ) |>
      select(Subcategoría, `Mediana (COP)`, `Productos incluidos`)
  }, striped = TRUE, hover = TRUE, width = "100%")

  # ---------------- 4 Graficos interactivos con highcharter ----------------
  # 1. Evolucion del precio de un producto comparable
  output$graf_evolucion <- renderHighchart({
    req(input$prod_evol)
    df <- evolucion_precio(con, as.integer(input$prod_evol))
    validate(need(nrow(df) > 0, "No hay observaciones históricas para el producto seleccionado."))
    fechas <- sort(unique(df$fecha))
    prod_nom <- init_opc$productos$nombre[init_opc$productos$id == as.integer(input$prod_evol)][1]

    hc <- highchart() |>
      hc_chart(type = "line") |>
      hc_title(text = prod_nom, style = list(fontSize = "14px")) |>
      hc_subtitle(text = "Evolución entre corridas completas (COP)") |>
      hc_xAxis(categories = fechas, title = list(text = "Fecha de consulta")) |>
      hc_yAxis(title = list(text = "Precio (COP)"), labels = list(format = "$ {value:,.0f}")) |>
      hc_tooltip(shared = TRUE, valuePrefix = "$ ", valueSuffix = " COP", valueDecimals = 0) |>
      hc_plotOptions(line = list(marker = list(enabled = TRUE, radius = 5), lineWidth = 2.5))

    for (com in names(COLORES_COMERCIO)) {
      sub <- df[df$comercio == com, , drop = FALSE]
      if (nrow(sub) == 0) next
      vals <- vapply(fechas, function(f) {
        idx <- which(sub$fecha == f)
        if (length(idx)) as.numeric(sub$precio[idx[1]]) else NA_real_
      }, numeric(1))
      hc <- hc |> hc_add_series(
        name = com,
        data = unname(vals),
        color = unname(COLORES_COMERCIO[com])
      )
    }
    hc
  }) |> bindCache(rv$version, input$prod_evol, cache = "app")

  # 2. Comparacion de precio por unidad sin mezclar unidades
  output$graf_unitario <- renderHighchart({
    req(input$corrida, input$unidad_comp)
    df <- precio_unitario_comparables(con, input$corrida, input$unidad_comp)
    validate(need(nrow(df) > 0, "No hay productos comparables para la unidad seleccionada."))
    prods <- unique(df$producto)
    unid <- input$unidad_comp

    hc <- highchart() |>
      hc_chart(type = "bar") |>
      hc_title(text = paste0("Precio por ", unid, " (COP/", unid, ")"), style = list(fontSize = "14px")) |>
      hc_subtitle(text = paste("Corrida:", input$corrida, "| Sin mezclar unidades")) |>
      hc_xAxis(categories = prods, title = list(text = NULL)) |>
      hc_yAxis(title = list(text = paste0("Precio unitario (COP/", unid, ")")),
               labels = list(format = "$ {value:,.0f}")) |>
      hc_tooltip(
        shared = FALSE,
        pointFormat = paste0(
          "<span style='color:{series.color}'>●</span> <b>{series.name}</b>: ",
          "<b>$ {point.y:,.0f} COP/", unid, "</b> (Total: $ {point.precio_total:,.0f} COP)<br/>"
        )
      )

    for (com in names(COLORES_COMERCIO)) {
      sub <- df[df$comercio == com, , drop = FALSE]
      if (nrow(sub) == 0) next
      pts <- lapply(prods, function(pr) {
        idx <- which(sub$producto == pr)
        if (length(idx) == 0) return(NULL)
        list(y = round(sub$precio_unitario[idx[1]], 1),
             precio_total = round(sub$precio[idx[1]]))
      })
      hc <- hc |> hc_add_series(
        name = com,
        data = pts,
        color = unname(COLORES_COMERCIO[com])
      )
    }
    hc
  }) |> bindCache(rv$version, input$corrida, input$unidad_comp, cache = "app")

  # 3. Distribucion de precios de la categoria por comercio
  output$graf_distribucion <- renderHighchart({
    req(input$corrida)
    df <- distribucion_precios(con, input$corrida)
    validate(need(nrow(df) > 0, "No hay precios disponibles en la corrida seleccionada."))
    comercios_ord <- names(COLORES_COMERCIO)[names(COLORES_COMERCIO) %in% unique(df$comercio)]
    datos_box <- lapply(seq_along(comercios_ord), function(i) {
      cm <- comercios_ord[i]
      vals <- df$precio[df$comercio == cm]
      qs <- as.numeric(quantile(vals, probs = c(0, 0.25, 0.5, 0.75, 1), na.rm = TRUE))
      col_hex <- unname(COLORES_COMERCIO[cm])
      list(
        x = i - 1,
        low = round(qs[1]),
        q1 = round(qs[2]),
        median = round(qs[3]),
        q3 = round(qs[4]),
        high = round(qs[5]),
        n = length(vals),
        color = col_hex,
        fillColor = paste0(col_hex, "44"),
        name = cm
      )
    })

    highchart() |>
      hc_chart(type = "boxplot") |>
      hc_title(text = "Distribución de precios por comercio (COP)", style = list(fontSize = "14px")) |>
      hc_subtitle(text = paste("Productos incluidos en corrida:", input$corrida)) |>
      hc_xAxis(categories = comercios_ord, title = list(text = "Comercio")) |>
      hc_yAxis(title = list(text = "Precio (COP)"), labels = list(format = "$ {value:,.0f}")) |>
      hc_add_series(
        name = "Precios (COP)",
        data = datos_box,
        showInLegend = FALSE,
        tooltip = list(
          headerFormat = "<b>{point.key}</b><br/>",
          pointFormat = paste0(
            "Máximo: $ {point.high:,.0f} COP<br/>",
            "Q3 (75%): $ {point.q3:,.0f} COP<br/>",
            "Mediana: <b>$ {point.median:,.0f} COP</b><br/>",
            "Q1 (25%): $ {point.q1:,.0f} COP<br/>",
            "Mínimo: $ {point.low:,.0f} COP<br/>",
            "N: {point.n} productos"
          )
        )
      )
  }) |> bindCache(rv$version, input$corrida, cache = "app")

  # 4. Grafico de libre eleccion: Ahorro potencial (%) y en COP por producto comparable
  output$graf_ahorro <- renderHighchart({
    req(input$corrida)
    df <- ahorro_reactivo()
    validate(need(nrow(df) > 0, "No hay suficientes comercios para calcular ahorro comparable."))
    pts <- lapply(seq_len(nrow(df)), function(i) {
      barato <- df$mas_barato[i]
      col <- if (barato %in% names(COLORES_COMERCIO)) unname(COLORES_COMERCIO[barato]) else "#6c757d"
      list(
        y = df$ahorro_pct[i],
        ahorro_cop = df$ahorro_cop[i],
        pmin = df$pmin[i],
        pmax = df$pmax[i],
        mas_barato = barato,
        mas_caro = df$mas_caro[i],
        color = col
      )
    })

    highchart() |>
      hc_chart(type = "bar") |>
      hc_title(text = "Ahorro al elegir el comercio más barato (%)", style = list(fontSize = "14px")) |>
      hc_subtitle(text = paste("Color = comercio más barato (gris = empate) | Corrida:", input$corrida)) |>
      hc_xAxis(categories = df$producto, title = list(text = NULL)) |>
      hc_yAxis(title = list(text = "Ahorro (%)"), labels = list(format = "{value} %")) |>
      hc_legend(enabled = FALSE) |>
      hc_add_series(name = "Ahorro (%)", data = pts) |>
      hc_tooltip(
        pointFormat = paste0(
          "Ahorro: <b>{point.y:.1f} % ($ {point.ahorro_cop:,.0f} COP)</b><br/>",
          "Más barato ({point.mas_barato}): $ {point.pmin:,.0f} COP<br/>",
          "Más caro ({point.mas_caro}): $ {point.pmax:,.0f} COP"
        )
      )
  }) |> bindCache(rv$version, input$corrida, cache = "app")

  # ---------------- Tabla de productos ----------------
  output$resumen_tabla_txt <- renderText({
    df <- datos_filtrados()
    paste0("Mostrando ", nrow(df), " productos | Corrida: ", input$corrida, " | Moneda: COP")
  })

  output$alerta_tabla_vacia <- renderUI({
    df <- datos_filtrados()
    if (nrow(df) > 0) return(NULL)
    div(
      class = "alert alert-info mb-3",
      icon("circle-info"),
      " Ningún producto coincide con los filtros actuales. Prueba ampliar el rango de precios, quitar marcas o limpiar la búsqueda."
    )
  })

  output$tabla_productos <- renderDT({
    df <- datos_filtrados()
    validate(need(nrow(df) > 0, ""))
    df_ui <- df |>
      mutate(
        subcategoria = recode(subcategoria,
                              "lagrima_artificial" = "Lágrima artificial",
                              "oftalmico" = "Oftálmico",
                              "otico" = "Ótico"),
        presentacion_txt = ifelse(is.na(presentacion), "Sin dato", presentacion),
        precio_txt = fmt_cop(precio, con_unidad = FALSE),
        unit_txt = ifelse(is.na(precio_unitario), "Sin dato",
                          paste0(fmt_cop(precio_unitario, con_unidad = FALSE), "/", contenido_unidad)),
        promo_txt = ifelse(promocion == 1,
                           paste0("Sí (antes ", fmt_cop(precio_lista, con_unidad = FALSE), ")"),
                           "No"),
        disp_txt = recode(disponibilidad,
                          "disponible" = "Disponible",
                          "agotado" = "Agotado",
                          "sin_dato" = "Sin dato"),
        fecha_txt = substr(fecha_consulta, 1, 16),
        enlace_html = ifelse(
          is.na(url) | !nzchar(url),
          "Sin enlace",
          sprintf('<a href="%s" target="_blank" rel="noopener noreferrer">Ver anuncio</a>',
                  htmlEscape(url, attribute = TRUE))
        )
      ) |>
      select(
        Comercio = comercio,
        Nombre = producto,
        Marca = marca,
        Subcategoría = subcategoria,
        Presentación = presentacion_txt,
        `Precio (COP)` = precio_txt,
        `Precio unitario` = unit_txt,
        Promoción = promo_txt,
        Disponibilidad = disp_txt,
        `Fecha consulta` = fecha_txt,
        Enlace = enlace_html
      )

    datatable(
      df_ui,
      escape = FALSE,
      rownames = FALSE,
      filter = "top",
      options = list(
        pageLength = 15,
        autoWidth = TRUE,
        language = list(
          search = "Buscar en tabla:",
          lengthMenu = "Mostrar _MENU_ registros",
          info = "Mostrando _START_ a _END_ de _TOTAL_ productos",
          paginate = list(previous = "Anterior", `next` = "Siguiente"),
          zeroRecords = "Sin resultados en la tabla"
        )
      )
    )
  })

  output$descargar_csv <- downloadHandler(
    filename = function() {
      paste0("productos_filtrados_", input$corrida, ".csv")
    },
    content = function(file) {
      write.csv(datos_filtrados(), file, row.names = FALSE, fileEncoding = "UTF-8")
    }
  )

  # ---------------- Cambios de precio ----------------
  cambios_reactivo <- reactive({
    req(input$corrida_ant, input$corrida_nue)
    cambios_precio(con, input$corrida_ant, input$corrida_nue, input$umbral_cambio)
  }) |> bindCache(rv$version, input$corrida_ant, input$corrida_nue, input$umbral_cambio, cache = "app")

  output$vb_subieron <- renderText({ sum(cambios_reactivo()$tipo == "subio") })
  output$vb_bajaron  <- renderText({ sum(cambios_reactivo()$tipo == "bajo") })
  output$vb_nuevos   <- renderText({ sum(cambios_reactivo()$tipo == "nuevo") })
  output$vb_no_obs   <- renderText({ sum(cambios_reactivo()$tipo == "dejo de observarse") })
  output$vb_grandes  <- renderText({ sum(cambios_reactivo()$variacion_grande == 1, na.rm = TRUE) })

  output$tabla_cambios <- renderDT({
    validate(need(input$corrida_ant != input$corrida_nue,
                  "Selecciona dos ejecuciones distintas para comparar cambios de precio."))
    df <- cambios_reactivo()
    if (!identical(input$filtro_tipo_cambio, "todos")) {
      df <- df[df$tipo == input$filtro_tipo_cambio, , drop = FALSE]
    }
    if (isTRUE(input$solo_var_grandes)) {
      df <- df[df$variacion_grande == 1, , drop = FALSE]
    }
    validate(need(nrow(df) > 0, "No hay cambios de precio que coincidan con el filtro seleccionado."))

    df_ui <- df |>
      mutate(
        `Precio anterior (COP)` = fmt_cop(precio_anterior, con_unidad = FALSE),
        `Precio nuevo (COP)` = fmt_cop(precio_nuevo, con_unidad = FALSE),
        `Cambio (COP)` = ifelse(is.na(cambio_cop), "N/A",
                                paste0(ifelse(cambio_cop > 0, "+", ""), fmt_cop(cambio_cop, con_unidad = FALSE))),
        `Cambio (%)` = ifelse(is.na(cambio_pct), "N/A",
                              paste0(ifelse(cambio_pct > 0, "+", ""), fmt_num(cambio_pct, 1), " %")),
        Tipo = recode(tipo,
                      "subio" = "Subió",
                      "bajo" = "Bajó",
                      "nuevo" = "Nuevo",
                      "dejo de observarse" = "Dejó de observarse",
                      "igual" = "Igual"),
        Destacado = ifelse(variacion_grande == 1, paste0("Sí (>= ", input$umbral_cambio, "%)"), "No"),
        Enlace = ifelse(is.na(url) | !nzchar(url), "Sin enlace",
                        sprintf('<a href="%s" target="_blank" rel="noopener noreferrer">Ver</a>',
                                htmlEscape(url, attribute = TRUE)))
      ) |>
      select(
        Comercio = comercio,
        Producto = producto,
        Marca = marca,
        `Precio anterior (COP)`,
        `Precio nuevo (COP)`,
        `Cambio (COP)`,
        `Cambio (%)`,
        Tipo,
        Destacado,
        Enlace,
        variacion_grande
      )

    datatable(
      df_ui,
      escape = FALSE,
      rownames = FALSE,
      options = list(
        pageLength = 15,
        columnDefs = list(list(targets = ncol(df_ui) - 1, visible = FALSE)),
        language = list(
          search = "Buscar:",
          lengthMenu = "Mostrar _MENU_",
          info = "Mostrando _START_ a _END_ de _TOTAL_",
          paginate = list(previous = "Anterior", `next` = "Siguiente")
        )
      )
    ) |>
      formatStyle(
        "variacion_grande",
        target = "row",
        backgroundColor = styleEqual(1, "#fff3cd")
      )
  })

  # ---------------- Canasta ----------------
  output$canasta_cantidades_ui <- renderUI({
    sel <- input$canasta_prods
    if (length(sel) == 0) {
      return(div(class = "alert alert-info mb-0", "Selecciona al menos un producto comparable para cotizar la canasta."))
    }
    prods <- init_opc$productos
    lapply(sel, function(pid) {
      nom <- prods$nombre[prods$id == as.integer(pid)][1]
      inp_id <- paste0("cant_", pid)
      val_act <- isolate(input[[inp_id]])
      if (is.null(val_act) || is.na(val_act) || val_act < 1) val_act <- 1
      numericInput(inp_id, label = paste("Cantidad:", nom), value = val_act, min = 1, max = 20, step = 1)
    })
  })

  canasta_items <- reactive({
    sel <- input$canasta_prods
    if (length(sel) == 0) return(data.frame(producto_id = integer(), cantidad = numeric()))
    cants <- vapply(sel, function(pid) {
      v <- input[[paste0("cant_", pid)]]
      if (is.null(v) || is.na(v) || v < 1) 1 else as.numeric(v)
    }, numeric(1))
    data.frame(producto_id = as.integer(sel), cantidad = cants)
  })

  canasta_res <- reactive({
    req(input$corrida_canasta)
    items <- canasta_items()
    if (nrow(items) == 0) return(NULL)
    resultado_canasta(con, items, input$corrida_canasta)
  })

  output$vb_canasta_min <- renderText({
    r <- canasta_res()
    if (is.null(r)) return("Selecciona productos")
    fmt_cop(r$costo_minimo)
  })
  output$vb_canasta_unico <- renderText({
    r <- canasta_res()
    if (is.null(r)) return("Selecciona productos")
    if (is.na(r$mejor_comercio_unico)) "Ninguno completo" else fmt_cop(r$mejor_comercio_unico)
  })
  output$vb_canasta_ahorro <- renderText({
    r <- canasta_res()
    if (is.null(r) || is.na(r$ahorro_cop)) return("Sin ahorro calculable")
    pct <- if (!is.na(r$mejor_comercio_unico) && r$mejor_comercio_unico > 0) {
      100 * r$ahorro_cop / r$mejor_comercio_unico
    } else NA_real_
    paste0(fmt_cop(r$ahorro_cop), " (", fmt_num(pct, 1), " %)")
  })

  output$canasta_faltantes_ui <- renderUI({
    r <- canasta_res()
    if (is.null(r) || nrow(r$faltantes) == 0) return(NULL)
    por_c <- split(r$faltantes$producto_faltante, r$faltantes$comercio)
    msgs <- lapply(names(por_c), function(cm) {
      tags$li(strong(cm), ": falta ", paste(por_c[[cm]], collapse = ", "))
    })
    div(
      class = "alert alert-danger",
      strong("Comercios con canasta incompleta (no se muestra total parcial):"),
      tags$ul(class = "mb-0 mt-1", msgs)
    )
  })

  output$tabla_canasta_comercios <- renderTable({
    r <- canasta_res()
    validate(need(!is.null(r), "Agrega al menos un producto comparable a la canasta."))
    r$por_comercio |>
      mutate(
        Cobertura = sprintf("%d / %d productos", tiene, necesarios),
        `Total canasta (COP)` = ifelse(is.na(total), "Incompleta (faltan productos)", fmt_cop(total))
      ) |>
      select(Comercio = comercio, Cobertura, `Total canasta (COP)`)
  }, striped = TRUE, hover = TRUE, width = "100%")

  output$tabla_canasta_minimo <- renderTable({
    r <- canasta_res()
    validate(need(!is.null(r), "Agrega al menos un producto comparable a la canasta."))
    r$minimo |>
      mutate(
        Cantidad = as.integer(cantidad),
        `Precio mínimo (COP)` = fmt_cop(precio_minimo),
        `Subtotal (COP)` = fmt_cop(subtotal)
      ) |>
      select(
        Producto = producto,
        Cantidad,
        `Comercio más barato` = comercio_mas_barato,
        `Precio mínimo (COP)`,
        `Subtotal (COP)`
      )
  }, striped = TRUE, hover = TRUE, width = "100%")

  # ---------------- Actualizacion y estado ----------------
  output$resultado_actualizacion_ui <- renderUI({
    res <- rv$ultimo_msg
    if (is.null(res)) return(NULL)
    if (!isTRUE(res$ok)) {
      return(div(
        class = "alert alert-danger",
        icon("circle-xmark"),
        strong(" Error durante la actualización: "), res$error,
        br(), "Puedes usar el modo sin conexión con las copias guardadas en ", code("raw/"), "."
      ))
    }
    df <- res$resumen
    fallidas <- df[df$estado == "fallida", , drop = FALSE]
    ya_proc <- df[df$estado == "ya procesada", , drop = FALSE]
    aviso_extra <- if (nrow(fallidas) > 0) {
      div(class = "alert alert-warning mt-2 mb-0",
          icon("triangle-exclamation"),
          sprintf(" %d comercio(s) fallaron (%s). Revisa el motivo en la tabla de estado inferior; puedes reprocesar desde raw/ en modo sin conexión.",
                  nrow(fallidas), paste(fallidas$comercio, collapse = ", ")))
    } else if (nrow(ya_proc) == nrow(df)) {
      div(class = "alert alert-info mt-2 mb-0",
          icon("circle-info"),
          " Esta fecha de raw/ ya se encontraba procesada en la base; no se duplicaron observaciones.")
    } else {
      NULL
    }
    card(
      card_header(
        paste0("Resultado de la actualización (",
               if (identical(res$modo, "offline")) paste("sin conexión:", res$fecha_dir) else "en línea",
               ")")
      ),
      card_body(
        tableOutput("tabla_res_tarea"),
        aviso_extra
      )
    )
  })

  output$tabla_res_tarea <- renderTable({
    res <- rv$ultimo_msg
    req(res, isTRUE(res$ok))
    res$resumen
  }, striped = TRUE, hover = TRUE, width = "100%")

  output$tabla_resumen_act <- renderTable({
    rv$version
    df <- resumen_actualizacion(con)
    validate(need(nrow(df) > 0, "Se requieren al menos dos corridas para calcular el resumen de cambios."))
    df |>
      rename(
        Comercio = comercio,
        `Productos recolectados` = recolectados,
        `Productos nuevos` = nuevos,
        `Con cambio de precio` = cambio_precio,
        `No observados` = no_observados
      )
  }, striped = TRUE, hover = TRUE, width = "100%")

  output$tabla_ultima_ejecucion <- renderTable({
    rv$version
    ue <- ultima_ejecucion(con)
    validate(need(nrow(ue) > 0, "No hay ejecuciones registradas."))
    ue |>
      mutate(
        `Fecha inicio` = substr(inicio, 1, 19),
        `Total sitio` = ifelse(is.na(total_sitio), "Sin dato", as.character(total_sitio)),
        Detalle = limpiar_ansi(detalle)
      ) |>
      select(
        Comercio = comercio,
        `Fecha inicio`,
        Estado = estado,
        Extraídos = n_registros,
        `Total sitio`,
        Detalle
      )
  }, striped = TRUE, hover = TRUE, width = "100%")
}

shinyApp(ui, server)
