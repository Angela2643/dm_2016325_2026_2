# app.R - Archivo principal. Solo llama a la configuración, a la UI y al server
# (Clase 11: arquitectura ui + server + shinyApp).
#
# Ejecutar desde la carpeta taller_2/:
#   shiny::runApp()
#
# Estructura:
#   global.R      paquetes, configuración y módulos
#   app_ui.R      interfaz
#   app_server.R  lógica reactiva
#   db.R, sql_consult.R, scraper.R, validacion.R, graficos.R   módulos

library(shiny)

source("global.R", encoding = "UTF-8")

ui     <- source("app_ui.R",     local = TRUE, encoding = "UTF-8")$value
server <- source("app_server.R", local = TRUE, encoding = "UTF-8")$value

shinyApp(ui, server)
