# tests/test_taller2.R - Pruebas automáticas (Módulo 7).
# Usan datos pequeños y una base temporal: nunca la base de la entrega ni los sitios.
#
# Ejecutar desde taller_2/ con un solo comando:
#   Rscript -e 'testthat::test_dir("tests")'

library(testthat)

options(testthat.use_colours = FALSE)

options(taller2.ejecutar = FALSE)
# test_dir() corre desde tests/; se sube a taller_2/ para cargar los módulos.
raiz <- if (file.exists("../sql_consult.R")) ".." else "."
for (f in c("validacion.R", "scraper.R", "db.R", "sql_consult.R")) {
  source(file.path(raiz, f), encoding = "UTF-8", local = FALSE)
}

# ---- Utilidades de las pruebas --------------------------------------------

# Una observación mínima ya preparada (columnas de preparar_observaciones()).
obs <- function(comercio, titulo, precio, subcategoria = "cereales",
                hora = "2026-11-01T10:00:00-0500", marca = "ZUCARITAS",
                gramos = 610, unidades = 1) {
  crudo <- tibble::tibble(
    titulo = titulo, precio_texto = paste("$", precio), precio = precio,
    precio_previo_texto = NA_character_, precio_previo = NA_real_,
    marca_producto = marca, tiene_descuento = FALSE, descuento_pct = NA_real_,
    consulta = subcategoria, pagina = comercio, hora_consulta = hora,
    pagina_consulta = "https://ejemplo.test/s?q=cereales",
    gramos = gramos, unidades = unidades, archivo_raw = "raw/x.html")
  preparar_observaciones(crudo)
}

# Base temporal con el esquema, el catálogo y una ejecución creada.
base_temporal <- function() {
  ruta <- tempfile(fileext = ".sqlite")
  con <- abrir_con(ruta)
  crear_esquema(con)
  sembrar_presentaciones(con)
  con
}

nueva_ejecucion <- function(con, sufijo, fecha) {
  e <- obtener_o_crear_ejecucion(con, sufijo, "offline")
  DBI::dbExecute(con, "UPDATE ejecuciones SET fecha_consulta = ? WHERE id_ejecucion = ?",
                 params = list(fecha, e$id))
  e$id
}

# Inserta una observación comparable de Zucaritas (P02) y la marca.
poner <- function(con, id_ej, comercio, precio, titulo = "Cereal ZUCARITAS hojuelas (610 gr)",
                  hora = "2026-11-01T10:00:00-0500") {
  o <- obs(comercio, titulo, precio, hora = hora)
  insertar_observaciones(con, o, id_ej)
  marcar_comparables(con, id_ej)
}

# ---- 1. Conversión de precios en texto a número ---------------------------

test_that("limpiar_precio convierte texto colombiano a número", {
  expect_equal(limpiar_precio("$ 12.900"), 12900)
  expect_equal(limpiar_precio("$ 1.234.500"), 1234500)
  expect_equal(limpiar_precio("$ 12.900,50"), 12900.5)
  expect_true(is.na(limpiar_precio(NA_character_)))
})

# ---- 2. Normalización de unidades -----------------------------------------

test_that("normalizar_contenido pasa gramos por unidad (c/u) a contenido total", {
  r <- normalizar_contenido(
    titulo   = c("Ponque Gansito 6Und 37g c/u", "Cereal ZUCARITAS (610 gr)",
                 "Galletas x3und", "Producto sin datos"),
    gramos   = c(37, 610, NA, NA),
    unidades = c(6, 1, 3, 1))
  expect_equal(r$contenido_total, c(222, 610, 3, NA))
  expect_equal(r$unidad_medida, c("g", "g", "unidad", NA))
})

# ---- 3. Ahorro con empates ------------------------------------------------

test_that("el ahorro con empates en el mínimo lista todos los comercios empatados", {
  con <- base_temporal(); on.exit(cerrar_con(con))
  id <- nueva_ejecucion(con, "2", "2026-11-01")
  poner(con, id, "Carulla", 19990)
  poner(con, id, "Exito",   19990)
  poner(con, id, "Jumbo",   28900)

  a <- db_ahorro_presentaciones(con, id)
  expect_equal(a$precio_min, 19990)
  expect_equal(a$precio_max, 28900)
  expect_equal(a$ahorro_cop, 8910)
  expect_equal(a$ahorro_pct, 30.8)
  expect_equal(a$n_comercios_en_minimo, 2)
  expect_equal(a$comercios_menor_precio, "Carulla, Exito")
})

# ---- 4. Insertar dos veces la misma ejecución -----------------------------

test_that("insertar dos veces la misma ejecución no duplica observaciones", {
  con <- base_temporal(); on.exit(cerrar_con(con))
  id <- nueva_ejecucion(con, "2", "2026-11-01")
  o <- rbind(obs("Carulla", "Cereal ZUCARITAS (610 gr)", 19990),
             obs("Exito",   "Cereal ZUCARITAS (610 gr)", 19990))

  expect_equal(insertar_observaciones(con, o, id), 2)
  expect_equal(insertar_observaciones(con, o, id), 0)   # segunda vez: nada nuevo
  n <- DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM productos")$n
  expect_equal(n, 2)

  # Una ejecución con la misma clave se reutiliza, no se crea otra.
  expect_false(obtener_o_crear_ejecucion(con, "2", "offline")$nueva)
})

# ---- 5. Detección de cambios de precio ------------------------------------

test_that("db_cambios detecta subió, bajó, igual, nuevo y no observado", {
  con <- base_temporal(); on.exit(cerrar_con(con))
  id1 <- nueva_ejecucion(con, "",  "2026-10-10")
  id2 <- nueva_ejecucion(con, "2", "2026-11-11")

  insertar_observaciones(con, rbind(
    obs("Carulla", "Producto A", 1000), obs("Carulla", "Producto B", 2000),
    obs("Carulla", "Producto C", 3000), obs("Carulla", "Producto D", 4000)), id1)
  insertar_observaciones(con, rbind(
    obs("Carulla", "Producto A", 1200),   # sube 20 %
    obs("Carulla", "Producto B", 1900),   # baja 5 %
    obs("Carulla", "Producto C", 3000),   # igual
    obs("Carulla", "Producto E", 500)),   # nuevo (D no aparece)
    id2)

  d <- db_cambios(con, id1, id2, umbral_pct = 10)
  estado <- setNames(d$estado, d$titulo)
  expect_equal(estado[["Producto A"]], "subió")
  expect_equal(estado[["Producto B"]], "bajó")
  expect_equal(estado[["Producto C"]], "igual")
  expect_equal(estado[["Producto D"]], "no observado")
  expect_equal(estado[["Producto E"]], "nuevo")
  expect_equal(d$cambio_pct[d$titulo == "Producto A"], 20)
  expect_equal(d$cambio_cop[d$titulo == "Producto B"], -100)
  # Solo A (20 %) supera el umbral de 10 %.
  expect_equal(d$titulo[d$variacion_grande == 1], "Producto A")
})

# ---- 6. La canasta no se calcula si falta un producto ---------------------

test_that("la canasta no se calcula cuando a un comercio le falta un producto", {
  con <- base_temporal(); on.exit(cerrar_con(con))
  id <- nueva_ejecucion(con, "2", "2026-11-01")
  # P02 (Zucaritas) en los dos comercios; P05 (Froot Loops) solo en Carulla.
  poner(con, id, "Carulla", 19990)
  poner(con, id, "Exito",   20500)
  o <- obs("Carulla", "Cereal FROOT LOOPS mezcla (450 gr)", 28900,
           marca = "FROOT LOOPS", gramos = 450)
  insertar_observaciones(con, o, id); marcar_comparables(con, id)

  ids <- c("P02", "P05"); cant <- c(1, 1)
  tot <- db_canasta(con, id, ids, cant)
  expect_equal(tot$total_cop[tot$comercio == "Carulla"], 19990 + 28900)
  expect_true(is.na(tot$total_cop[tot$comercio == "Exito"]))      # le falta P05
  expect_equal(tot$n_encontrados[tot$comercio == "Exito"], 1)

  # Con un producto que ningún comercio tiene, tampoco hay total mixto.
  r <- resumen_canasta(db_canasta(con, id, c("P02", "P08"), c(1, 1)),
                       db_canasta_mixta(con, id, c("P02", "P08"), c(1, 1)), 2)
  expect_true(is.na(r$mixto))
  expect_true(is.na(r$mejor_unico))
})

test_that("la compra mixta usa la cantidad elegida y el mejor precio", {
  con <- base_temporal(); on.exit(cerrar_con(con))
  id <- nueva_ejecucion(con, "2", "2026-11-01")
  poner(con, id, "Carulla", 19990)
  poner(con, id, "Jumbo",   28900)
  m <- db_canasta_mixta(con, id, "P02", 3)
  expect_equal(m$subtotal_cop, 3 * 19990)
  expect_equal(m$comercios_menor_precio, "Carulla")
})

# ---- 7. Validación antes de insertar --------------------------------------

test_that("la validación rechaza precios no válidos y duplicados, con su motivo", {
  o <- rbind(
    obs("Carulla", "Producto A", 1000),
    obs("Carulla", "Producto B", 0),          # precio cero
    obs("Carulla", "Producto C", NA_real_),   # precio no numérico
    obs("Carulla", "Producto A", 1000))       # duplicado de A
  v <- validar_observaciones(o)
  expect_equal(nrow(v$validas), 1)
  expect_equal(sort(v$rechazadas$motivo),
               sort(c("precio menor o igual a cero", "precio no numérico",
                      "observación duplicada en la misma ejecución")))
})

test_that("las observaciones rechazadas no entran a la base", {
  con <- base_temporal(); on.exit(cerrar_con(con))
  id <- nueva_ejecucion(con, "2", "2026-11-01")
  res <- list(sitio = "Carulla", estado = "completa", errores = character(),
              datos = tibble::tibble(
                titulo = c("A", "B"), precio_texto = c("$ 1.000", "$ 0"),
                precio = c(1000, 0), precio_previo_texto = NA_character_,
                precio_previo = NA_real_, marca_producto = "X", tiene_descuento = FALSE,
                descuento_pct = NA_real_, consulta = "cereales", pagina = "Carulla",
                hora_consulta = "2026-11-01T10:00:00-0500",
                pagina_consulta = "https://ejemplo.test", gramos = 100, unidades = 1))
  r <- procesar_comercio(con, id, res)
  expect_equal(r$insertados, 1)
  expect_equal(r$rechazados, 1)
  expect_equal(DBI::dbGetQuery(con, "SELECT COUNT(*) AS n FROM rechazados")$n, 1)
})

# ---- 8. Seguridad: consultas parametrizadas -------------------------------

test_that("los filtros nunca pegan texto del usuario en la consulta", {
  f <- filtros_vacios()
  f$busqueda  <- "x'; DROP TABLE productos; --"
  f$comercios <- c("Carulla", "Exito")
  w <- construir_filtro(f)
  expect_false(grepl("DROP", w$sql))
  expect_false(grepl("Carulla", w$sql))
  expect_equal(lengths(gregexpr("\\?", w$sql)), length(w$params))
})

test_that("sanitizar_texto limita la longitud y quita caracteres no permitidos", {
  expect_equal(sanitizar_texto("cereal; DROP TABLE"), "cereal DROP TABLE")
  expect_equal(nchar(sanitizar_texto(strrep("a", 500))), 60)
  expect_equal(sanitizar_texto(NULL), "")
})

test_that("una búsqueda con texto malicioso no rompe ni borra la base", {
  con <- base_temporal(); on.exit(cerrar_con(con))
  id <- nueva_ejecucion(con, "2", "2026-11-01")
  poner(con, id, "Carulla", 19990)
  f <- filtros_vacios(); f$busqueda <- "zucaritas'; DROP TABLE productos; --"
  d <- db_productos(con, f)
  expect_s3_class(d, "data.frame")
  expect_true("productos" %in% DBI::dbListTables(con))
})

# ---- 9. Extracción desde una copia cruda ----------------------------------

test_that("extraer_desde_html lee precios, descuento, marca y gramos de la copia cruda", {
  arch <- file.path(raiz, "tests", "fixtures", "Carulla_cereales2.html")
  if (!file.exists(arch)) arch <- file.path("fixtures", "Carulla_cereales2.html")
  df <- extraer_desde_html(arch, "Carulla", "cereales", "2026-11-11T10:00:00-0500")
  expect_equal(nrow(df), 2)
  expect_equal(df$precio, c(19990, 12600))
  expect_equal(df$precio_previo, c(28900, NA))
  expect_equal(df$tiene_descuento, c(TRUE, FALSE))
  expect_equal(df$marca_producto, c("ZUCARITAS", "GANSITO"))
  expect_equal(df$gramos, c(610, 222))
  expect_equal(df$unidades, c(1, 6))

  p <- parsear_nombre_raw("raw/Carulla_barras_cereal2.html")
  expect_equal(p$sitio, "Carulla"); expect_equal(p$consulta, "barras_cereal")
  expect_equal(p$sufijo, "2")
  expect_equal(parsear_nombre_raw("Exito_frutos_secos.html")$sufijo, "")
})

# ---- 10. Reglas de comparables --------------------------------------------

test_that("el Chocoramo en paquete de 5 unidades no se marca como comparable", {
  con <- base_temporal(); on.exit(cerrar_con(con))
  id <- nueva_ejecucion(con, "2", "2026-11-01")
  insertar_observaciones(con, rbind(
    obs("Jumbo", "Ponque Chocoramo 5Und 65g c/u", 11990, subcategoria = "chocorramo",
        marca = "Chocorramo", gramos = 65, unidades = 5),
    obs("Jumbo", "Ponque Chocoramo 65g", 3280, subcategoria = "chocorramo",
        marca = "Chocorramo", gramos = 65, unidades = 1)), id)
  marcar_comparables(con, id)
  m <- DBI::dbGetQuery(con, "SELECT titulo, id_presentacion FROM productos WHERE comparable = 1")
  expect_equal(m$titulo, "Ponque Chocoramo 65g")
  expect_equal(m$id_presentacion, "P07")
})

