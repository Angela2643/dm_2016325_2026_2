# app_ui.R - Interfaz de la aplicación (solo la UI; la lógica está en app_server.R).
# Layout con bslib (Clase 11): page_navbar + sidebar de filtros + tarjetas.
#
# Este archivo termina con el objeto "ui" para que app.R lo reciba con
#   ui <- source("app_ui.R", local = TRUE)$value

tema <- bslib::bs_theme(version = 5, bootswatch = "flatly", primary = "#1d4ed8")

# Los filtros. Las opciones (comercios, marcas, etc.) se llenan desde la base
# en el server con update*Input().
panel_filtros <- bslib::sidebar(
  id = "panel_filtros", width = 330, open = "desktop", title = "Filtros",
  
  selectInput("f_ejecuciones", "Ejecución (fecha de consulta)",
              choices = NULL, multiple = TRUE),
  helpText("Si no elige ninguna ejecución se usan todas."),
  selectInput("f_comercios", "Comercio", choices = NULL, multiple = TRUE),
  selectInput("f_subcategorias", "Subcategoría", choices = NULL, multiple = TRUE),
  selectizeInput("f_marcas", "Marca", choices = NULL, multiple = TRUE),
  sliderInput("f_precio", "Precio (COP)", min = 0, max = 100000,
              value = c(0, 100000), step = 500, pre = "$ ", sep = "."),
  checkboxInput("f_promo", "Solo promociones", value = FALSE),
  checkboxInput("f_comparables", "Solo productos comparables", value = FALSE),
  textInput("f_busqueda", "Buscar en el nombre del anuncio",
            placeholder = "Ej.: cereal, gansito"),
  actionButton("f_limpiar", "Limpiar filtros", class = "btn-outline-secondary btn-sm"),
  helpText("Precios en pesos colombianos (COP), tal como aparecían en cada",
           "comercio en el momento de la consulta.")
)

# Nota: los menús desplegables NO van dentro de bslib::card(): la tarjeta recorta
# (overflow) la lista de opciones y solo se ve una. Por eso usan un div simple.

# Una tarjeta de indicador: título (con unidad), valor y el periodo al que corresponde.
indicador <- function(id, titulo, tema_color = "primary") {
  bslib::value_box(
    title = titulo,
    value = textOutput(id),
    textOutput(paste0(id, "_nota")),
    theme = tema_color
  )
}

ui <- bslib::page_navbar(
  title = "Comparador de precios · Alimentos y snacks",
  id = "navegacion",
  theme = tema,
  sidebar = panel_filtros,
  fillable = FALSE,
  
  # ---- Resumen --------------------------------------------------------------
  bslib::nav_panel(
    "Resumen",
    uiOutput("aviso_base"),
    bslib::layout_column_wrap(
      width = "230px",
      indicador("kpi_ejec", "Última ejecución (fecha)"),
      indicador("kpi_estado", "Estado de la última ejecución", "secondary"),
      indicador("kpi_obs", "Observaciones (filtro actual)", "secondary"),
      indicador("kpi_mediana", "Mediana del precio (COP)"),
      indicador("kpi_promo", "Productos en promoción (%)", "secondary"),
      indicador("kpi_ahorro", "Ahorro máximo entre comercios (COP)", "success"),
      indicador("kpi_cambios", "Cambios de precio (última ejecución)", "warning")
    ),
    bslib::layout_columns(
      col_widths = c(6, 6),
      bslib::card(bslib::card_header("Productos y observaciones por comercio"),
                  tableOutput("tabla_comercio")),
      bslib::card(bslib::card_header("Mediana del precio por subcategoría (COP)"),
                  tableOutput("tabla_mediana"))
    ),
    bslib::layout_columns(
      col_widths = c(6, 6),
      bslib::card(bslib::card_header("Distribución de precios por comercio"),
                  highcharter::highchartOutput("g_distribucion", height = "380px")),
      bslib::card(bslib::card_header("¿Dónde sale más barata la canasta de 8 productos?"),
                  highcharter::highchartOutput("g_canasta", height = "380px"))
    )
  ),
  
  # ---- Series de precio -----------------------------------------------------
  bslib::nav_panel(
    "Series de precio",
    div(
      class = "p-3 mb-3 border rounded bg-light",
      bslib::layout_columns(
        col_widths = c(6, 6),
        selectInput("producto", "Producto comparable", choices = NULL, width = "100%"),
        radioButtons("unidad_precio", "Precio por unidad de contenido",
                     choices = c("COP por 100 g" = "g100",
                                 "COP por unidad del empaque" = "und"),
                     inline = TRUE)
      )
    ),
    bslib::layout_columns(
      col_widths = c(6, 6),
      bslib::card(bslib::card_header("Precio del empaque a lo largo de las ejecuciones"),
                  highcharter::highchartOutput("g_precio", height = "400px")),
      bslib::card(bslib::card_header("Precio por unidad de contenido"),
                  highcharter::highchartOutput("g_unitario", height = "400px"))
    ),
    helpText("Cada punto es una ejecución del scraper; el eje muestra su fecha.",
             "Los precios son del momento de la captura y pueden incluir promociones.")
  ),
  
  # ---- Cambios de precio ----------------------------------------------------
  bslib::nav_panel(
    "Cambios de precio",
    div(
      class = "p-3 mb-3 border rounded bg-light",
      bslib::layout_columns(
        col_widths = c(4, 4, 4),
        selectInput("cmb_a", "Ejecución anterior", choices = NULL),
        selectInput("cmb_b", "Ejecución nueva", choices = NULL),
        numericInput("cmb_umbral", "Resaltar variaciones de al menos (%)",
                     value = 10, min = 0, max = 100, step = 1)
      ),
      textOutput("cmb_resumen")
    ),
    bslib::card(DT::dataTableOutput("tabla_cambios")),
    helpText("Se compara el mismo anuncio (mismo comercio y mismo nombre).",
             "«No observado» significa que el anuncio no apareció en la segunda",
             "ejecución; no quiere decir que esté agotado ni retirado.")
  ),
  
  # ---- Canasta --------------------------------------------------------------
  bslib::nav_panel(
    "Canasta",
    bslib::layout_columns(
      col_widths = c(4, 8),
      div(
        class = "p-3 border rounded bg-light",
        h5("Arme su canasta"),
        selectInput("cb_ejec", "Precios de la ejecución", choices = NULL),
        selectizeInput("cb_prod", "Productos comparables", choices = NULL, multiple = TRUE),
        uiOutput("cb_cantidades")
      ),
      bslib::card(
        bslib::card_header("Costo por comercio (COP)"),
        tableOutput("tabla_canasta"),
        bslib::layout_column_wrap(
          width = "200px",
          bslib::value_box("Mejor comercio único (COP)", textOutput("cb_unico"),
                           textOutput("cb_unico_nota"), theme = "secondary"),
          bslib::value_box("Comprando cada producto donde es más barato (COP)",
                           textOutput("cb_mixto"), theme = "primary"),
          bslib::value_box("Ahorro frente al mejor comercio único (COP)",
                           textOutput("cb_ahorro"), textOutput("cb_ahorro_nota"),
                           theme = "success")
        ),
        tableOutput("tabla_mixta"),
        helpText("El resultado NO incluye costos de envío, mínimos de compra ni las",
                 "condiciones de las promociones. Si a un comercio le falta algún",
                 "producto elegido, no se muestra un total incompleto.")
      )
    )
  ),
  
  # ---- Datos ----------------------------------------------------------------
  bslib::nav_panel(
    "Datos",
    bslib::card(
      bslib::card_header(
        "Productos filtrados",
        downloadButton("descargar_csv", "Descargar CSV", class = "btn-success btn-sm")
      ),
      DT::dataTableOutput("tabla_datos")
    ),
    helpText("El enlace lleva a la búsqueda del comercio donde apareció el anuncio.",
             "Precio unitario: COP por g (o por unidad cuando solo hay unidades).")
  ),
  
  # ---- Actualizar -----------------------------------------------------------
  bslib::nav_panel(
    "Actualizar",
    uiOutput("aviso_scraping"),
    bslib::card(
      bslib::card_header("Actualizar los precios"),
      p("«Actualizar precios» consulta los comercios con el scraper, valida los datos",
        "y agrega una ejecución nueva a la base. «Sin conexión» reprocesa las copias",
        "guardadas en raw/ y no duplica ejecuciones ya registradas."),
      bslib::layout_column_wrap(
        width = "250px",
        bslib::input_task_button("actualizar", "Actualizar precios (en línea)"),
        bslib::input_task_button("offline", "Reprocesar raw/ (sin conexión)",
                                 label_busy = "Procesando...", type = "secondary")
      ),
      textOutput("mensaje_actualizacion"),
      tableOutput("resumen_actualizacion")
    ),
    bslib::card(
      bslib::card_header("Ejecuciones registradas"),
      tableOutput("tabla_ejecuciones")
    ),
    helpText("En las plataformas gratuitas los cambios hechos a la base se pierden",
             "cuando la aplicación se reinicia. La actualización en línea funciona",
             "al ejecutar la aplicación en el computador local.")
  )
)

ui
