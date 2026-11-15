library(testthat)
library(DBI)
library(RSQLite)

source("../validacion.R")
source("../scraper.R")
source("../db.R")

# Helper: crea una base temporal minima con el esquema completo del Taller 2
crear_db_prueba <- function() {
  ruta <- tempfile(fileext = ".sqlite")
  con <- dbConnect(SQLite(), ruta)
  crear_esquema(con)
  dbExecute(con, "INSERT INTO comercios (id, nombre) VALUES (1, 'Farmatodo'), (2, 'Colsubsidio'), (3, 'Farmacias Pasteur')")
  list(ruta = ruta, con = con)
}

test_that("1. Convierte precios en texto a numero COP correctamente", {
  expect_equal(limpiar_precio("$ 12.900"), 12900)
  expect_equal(limpiar_precio("12,900"), 12900)
  expect_equal(limpiar_precio("$ 1.299.900"), 1299900)
  expect_equal(limpiar_precio("12.900,50"), 12900.50)
  expect_equal(limpiar_precio("62559.00"), 62559)
  expect_true(is.na(limpiar_precio("")))
  expect_true(is.na(limpiar_precio(NA_character_)))
})

test_that("2. Normaliza unidades a mL y g descartando concentraciones", {
  r <- extraer_contenido(c("Systane Ultra 10 ml", "Gotas 1 L", "Gel oftálmico 5 gr", "Solución 4 mg/ml frasco x 15 ml"))
  expect_equal(r$valor, c(10, 1000, 5, 15))
  expect_equal(r$unidad, c("mL", "mL", "g", "mL"))
})

test_that("3. Calcula el ahorro entre comercios manejando empates en el minimo", {
  bd <- crear_db_prueba()
  on.exit({ dbDisconnect(bd$con); unlink(bd$ruta) }, add = TRUE)

  dbExecute(bd$con, "INSERT INTO productos (id, nombre, contenido_valor, contenido_unidad) VALUES (1, 'Gotas X 10 mL', 10, 'mL')")
  dbExecute(bd$con, "INSERT INTO ejecuciones (id, inicio, comercio_id, n_registros, total_sitio, estado) VALUES
    ('20261111T100000_farmatodo',   '2026-11-11T10:00:00-05:00', 1, 1, 1, 'completa'),
    ('20261111T100000_colsubsidio', '2026-11-11T10:00:00-05:00', 2, 1, 1, 'completa'),
    ('20261111T100000_pasteur',     '2026-11-11T10:00:00-05:00', 3, 1, 1, 'completa')")
  dbExecute(bd$con, "INSERT INTO anuncios (id, comercio_id, sku, nombre_original, incluido, producto_id, comparable) VALUES
    (1, 1, 'F1', 'Gotas X 10 mL', 1, 1, 1),
    (2, 2, 'C1', 'Gotas X 10 mL', 1, 1, 1),
    (3, 3, 'P1', 'Gotas X 10 mL', 1, 1, 1)")
  dbExecute(bd$con, "INSERT INTO observaciones (ejecucion_id, anuncio_id, precio, promocion, disponible, fecha_consulta, estado_disponibilidad) VALUES
    ('20261111T100000_farmatodo',   1, 50000, 0, 1, '2026-11-11T10:00:00-05:00', 'disponible'),
    ('20261111T100000_colsubsidio', 2, 50000, 0, 1, '2026-11-11T10:00:00-05:00', 'disponible'),
    ('20261111T100000_pasteur',     3, 60000, 0, 1, '2026-11-11T10:00:00-05:00', 'disponible')")

  ah <- ahorro_comparables(bd$con, "20261111T100000")
  expect_equal(nrow(ah), 1)
  expect_equal(ah$pmin, 50000)
  expect_equal(ah$pmax, 60000)
  expect_equal(ah$ahorro_cop, 10000)
  expect_equal(ah$ahorro_pct, 16.7)
  expect_true(grepl("Farmatodo", ah$mas_barato) && grepl("Colsubsidio", ah$mas_barato))
})

test_that("4. Insertar dos veces la misma ejecucion no duplica observaciones", {
  bd <- crear_db_prueba()
  on.exit({ dbDisconnect(bd$con); unlink(bd$ruta) }, add = TRUE)

  fc <- "2026-11-11T12:00:00-05:00"
  ej <- "20261111T120000_farmatodo"
  dbExecute(bd$con, "INSERT INTO ejecuciones (id, inicio, comercio_id, n_registros, total_sitio, estado) VALUES (?, ?, 1, 1, 1, 'completa')",
            params = list(ej, fc))

  df <- tibble::tibble(
    sku = "SKU1", nombre_original = "Systane 10 mL", marca_original = "Alcon",
    descripcion_original = "Gotas", url = "https://ejemplo.com/1",
    categoria_sitio = "Ocular", precio = 55000, precio_lista = NA_real_,
    promocion = 0L, disponible = 1L, marca_comercial = "Alcon",
    principio_activo = NA_character_, concentracion = NA_character_,
    presentacion = "10 mL", registro_invima = NA_character_
  ) |> estandarizar()

  insertar_resultados(bd$con, df, comercio_id = 1L, ejecucion_id = ej, fecha_consulta = fc, validas = df)
  insertar_resultados(bd$con, df, comercio_id = 1L, ejecucion_id = ej, fecha_consulta = fc, validas = df)

  n_obs <- dbGetQuery(bd$con, "SELECT COUNT(*) AS n FROM observaciones")$n
  expect_equal(n_obs, 1L)
})

test_that("5. Detecta cambios de precio (subio, bajo, nuevo, dejo de observarse) y umbral", {
  bd <- crear_db_prueba()
  on.exit({ dbDisconnect(bd$con); unlink(bd$ruta) }, add = TRUE)

  dbExecute(bd$con, "INSERT INTO ejecuciones (id, inicio, comercio_id, n_registros, estado) VALUES
    ('20261010T100000_farmatodo', '2026-10-10T10:00:00-05:00', 1, 3, 'completa'),
    ('20261111T100000_farmatodo', '2026-11-11T10:00:00-05:00', 1, 3, 'completa')")
  dbExecute(bd$con, "INSERT INTO anuncios (id, comercio_id, sku, nombre_original, marca_estandar, incluido) VALUES
    (1, 1, 'A1', 'Producto Sube',  'MarcaA', 1),
    (2, 1, 'A2', 'Producto Baja',  'MarcaB', 1),
    (3, 1, 'A3', 'Producto Viejo', 'MarcaC', 1),
    (4, 1, 'A4', 'Producto Nuevo', 'MarcaD', 1)")
  dbExecute(bd$con, "INSERT INTO observaciones (ejecucion_id, anuncio_id, precio, disponible, fecha_consulta, estado_disponibilidad) VALUES
    ('20261010T100000_farmatodo', 1, 10000, 1, '2026-10-10T10:00:00-05:00', 'disponible'),
    ('20261010T100000_farmatodo', 2, 20000, 1, '2026-10-10T10:00:00-05:00', 'disponible'),
    ('20261010T100000_farmatodo', 3, 15000, 1, '2026-10-10T10:00:00-05:00', 'disponible'),
    ('20261111T100000_farmatodo', 1, 12000, 1, '2026-11-11T10:00:00-05:00', 'disponible'),
    ('20261111T100000_farmatodo', 2, 19500, 1, '2026-11-11T10:00:00-05:00', 'disponible'),
    ('20261111T100000_farmatodo', 4, 30000, 1, '2026-11-11T10:00:00-05:00', 'disponible')")

  cm <- cambios_precio(bd$con, "20261010T100000", "20261111T100000", umbral_pct = 5)
  expect_equal(cm$tipo[cm$producto == "Producto Sube"], "subio")
  expect_equal(cm$cambio_cop[cm$producto == "Producto Sube"], 2000)
  expect_equal(cm$variacion_grande[cm$producto == "Producto Sube"], 1L)
  expect_equal(cm$tipo[cm$producto == "Producto Baja"], "bajo")
  expect_equal(cm$variacion_grande[cm$producto == "Producto Baja"], 0L)
  expect_equal(cm$tipo[cm$producto == "Producto Nuevo"], "nuevo")
  expect_equal(cm$tipo[cm$producto == "Producto Viejo"], "dejo de observarse")
})

test_that("6. La canasta no devuelve total en comercios donde falta algun producto", {
  bd <- crear_db_prueba()
  on.exit({ dbDisconnect(bd$con); unlink(bd$ruta) }, add = TRUE)

  dbExecute(bd$con, "INSERT INTO productos (id, nombre, contenido_valor, contenido_unidad) VALUES
    (1, 'Prod 1', 10, 'mL'),
    (2, 'Prod 2', 10, 'mL')")
  dbExecute(bd$con, "INSERT INTO anuncios (id, comercio_id, sku, nombre_original, incluido, producto_id, comparable) VALUES
    (1, 1, 'F1', 'Prod 1', 1, 1, 1),
    (2, 1, 'F2', 'Prod 2', 1, 2, 1),
    (3, 2, 'C1', 'Prod 1', 1, 1, 1)")
  dbExecute(bd$con, "INSERT INTO ejecuciones (id, inicio, comercio_id, n_registros, estado) VALUES
    ('20261111T100000_farmatodo',   '2026-11-11T10:00:00-05:00', 1, 2, 'completa'),
    ('20261111T100000_colsubsidio', '2026-11-11T10:00:00-05:00', 2, 1, 'parcial')")
  dbExecute(bd$con, "INSERT INTO observaciones (ejecucion_id, anuncio_id, precio, disponible, fecha_consulta, estado_disponibilidad) VALUES
    ('20261111T100000_farmatodo',   1, 40000, 1, '2026-11-11T10:00:00-05:00', 'disponible'),
    ('20261111T100000_farmatodo',   2, 50000, 1, '2026-11-11T10:00:00-05:00', 'disponible'),
    ('20261111T100000_colsubsidio', 3, 35000, 1, '2026-11-11T10:00:00-05:00', 'disponible')")

  items <- data.frame(producto_id = c(1L, 2L), cantidad = c(1, 2))
  res <- resultado_canasta(bd$con, items, "20261111T100000")

  expect_equal(res$por_comercio$total[res$por_comercio$comercio == "Farmatodo"], 140000)
  expect_true(is.na(res$por_comercio$total[res$por_comercio$comercio == "Colsubsidio"]))
  expect_true(is.na(res$por_comercio$total[res$por_comercio$comercio == "Farmacias Pasteur"]))
  expect_true("Prod 2" %in% res$faltantes$producto_faltante[res$faltantes$comercio == "Colsubsidio"])
  expect_equal(res$costo_minimo, 135000)
  expect_equal(res$ahorro_cop, 5000)
})

test_that("7. La validacion rechaza precios no positivos, URL ausente y duplicados", {
  df <- tibble::tibble(
    sku = c("S1", "S1", "S2", "S3"),
    nombre_original = c("Ok", "Dup", "SinPrecio", "SinUrl"),
    url = c("https://x.co/1", "https://x.co/1", "https://x.co/2", NA_character_),
    precio = c(10000, 10000, 0, 15000),
    disponible = c(1L, 1L, 0L, 1L)
  )
  v <- validar_observaciones(df, "Farmatodo", "2026-11-11T10:00:00-05:00")
  expect_equal(nrow(v$validas), 1L)
  expect_equal(nrow(v$rechazadas), 3L)
  expect_true(any(grepl("duplicada", v$rechazadas$motivo)))
  expect_true(any(grepl("precio ausente", v$rechazadas$motivo)))
  expect_true(any(grepl("URL ausente", v$rechazadas$motivo)))
})

test_that("8. La validacion de busqueda limita longitud y elimina caracteres peligrosos", {
  expect_equal(validar_busqueda("systane%; DROP TABLE 'x'"), "systane DROP TABLE x")
  largo <- paste(rep("a", 100), collapse = "")
  expect_equal(nchar(validar_busqueda(largo)), LONGITUD_MAX_BUSQUEDA)
})
