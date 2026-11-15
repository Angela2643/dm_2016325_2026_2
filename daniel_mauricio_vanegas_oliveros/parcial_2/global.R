# global.R - Se ejecuta una sola vez al iniciar la app (Clase 11: global.R).
# Carga paquetes, configuración y los módulos de la aplicación.
#
# Los módulos scraper.R y sql_consult.R también se pueden ejecutar como script
# (Rscript scraper.R / Rscript sql_consult.R). Dentro de la app solo se quieren
# sus funciones, por eso se apaga la opción de ejecución automática.

options(taller2.ejecutar = FALSE)

# ---- 1. Paquetes ----------------------------------------------------------

library(shiny)
library(bslib)
library(DT)
library(highcharter)
library(DBI)
library(RSQLite)
library(dplyr)
library(tibble)
library(stringr)
library(readr)
library(promises)
library(future)

# Las actualizaciones corren en un proceso aparte para no bloquear la app
# (Anexo B: ExtendedTask + future_promise).
plan(multisession)

# ---- 2. Configuración -----------------------------------------------------

# Un color fijo por comercio en toda la aplicación (Módulo 5).
COLORES <- c(Carulla = "#7CB342", Exito = "#E0B400", Jumbo = "#1B8A3A")

# Formato colombiano en los gráficos de highcharter: 12.900,5
opciones_hc <- getOption("highcharter.lang")
opciones_hc$decimalPoint <- ","
opciones_hc$thousandsSep <- "."
options(highcharter.lang = opciones_hc)

# ---- 3. Módulos -----------------------------------------------------------

source("validacion.R", encoding = "UTF-8")
source("scraper.R", encoding = "UTF-8")
source("db.R", encoding = "UTF-8")
source("sql_consult.R", encoding = "UTF-8")
source("graficos.R", encoding = "UTF-8")

# Si la base no existe (por ejemplo, un despliegue nuevo), la app lo avisa en
# la interfaz en lugar de fallar con un error técnico.
BASE_DISPONIBLE <- file.exists(ruta_base())

# ¿Hay Chrome para hacer scraping en línea? Se revisa una sola vez al iniciar.
SCRAPING_DISPONIBLE <- scraper_disponible()
