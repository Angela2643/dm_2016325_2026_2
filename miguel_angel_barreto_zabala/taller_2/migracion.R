# migracion.R -- lleva la base del Taller 1 al esquema del Taller 2 y REGISTRA cada correccion
# en la tabla 'correcciones' (no se borra ninguna observacion).
# Uso (en la consola, con scraper.R ya cargado):   source("migracion.R"); migrar_base()
# Es idempotente: se puede ejecutar varias veces sin duplicar correcciones.

migrar_base <- function(db = DB_PATH) {
  con <- dbConnect(SQLite(), db); on.exit(dbDisconnect(con))
  crear_esquema(con)      # agrega las tablas, columnas, indices y vistas que falten
  ahora <- iso_ahora()
  ins <- "INSERT INTO correcciones (fecha, tabla, registro_id, campo, valor_anterior, valor_nuevo, motivo) "

  dbBegin(con)
  tryCatch({
    # 1) Farmatodo: la disponibilidad se leyo mal (hasStock) y quedo en 0 en todas las observaciones.
    #    El listado se pidio con outofstore:false, o sea que el sitio las mostraba como disponibles.
    donde <- "FROM observaciones o JOIN anuncios a ON a.id = o.anuncio_id
              JOIN comercios c ON c.id = a.comercio_id
              WHERE c.nombre = 'Farmatodo' AND o.disponible = 0
                AND substr(o.ejecucion_id, 1, 15) < '20261111T000000'"
    dbExecute(con, paste0(ins, "SELECT ?, 'observaciones', o.id, 'disponible', '0', '1', ? ", donde),
              params = list(ahora, "Error de lectura del campo hasStock de Farmatodo: el listado solo muestra productos no agotados (outofstore = false)"))
    dbExecute(con, paste("UPDATE observaciones SET disponible = 1 WHERE id IN (SELECT o.id", donde, ")"))

    # 2) Observaciones sin precio valido (productos agotados sin precio): se marcan como
    #    descartadas, no se borran.
    donde2 <- "FROM observaciones o WHERE o.descartada = 0 AND (o.precio IS NULL OR o.precio <= 0)"
    dbExecute(con, paste0(ins, "SELECT ?, 'observaciones', o.id, 'descartada', '0', '1', ? ", donde2),
              params = list(ahora, "Observacion sin precio numerico mayor que cero: se descarta del analisis de precios (se conserva como evidencia)"))
    dbExecute(con, "UPDATE observaciones SET descartada = 1,
        motivo_descarte = CASE WHEN disponible = 0 THEN 'precio ausente (agotado segun el sitio)'
                               ELSE 'precio ausente o no positivo' END
        WHERE descartada = 0 AND (precio IS NULL OR precio <= 0)")

    # 3) Estado de disponibilidad de cada observacion: disponible / agotado / sin_dato
    dbExecute(con, "UPDATE observaciones SET estado_disponibilidad =
        CASE WHEN disponible IS NULL THEN 'sin_dato' WHEN disponible = 1 THEN 'disponible'
             ELSE 'agotado' END
        WHERE estado_disponibilidad IS NULL")

    # 4) Total declarado por Pasteur en la corrida del 2026-11-11: el scraper no lo leyo, pero se
    #    verifico a mano (62 articulos en la pagina de la coleccion y 62 productos en products.json).
    donde4 <- "FROM ejecuciones WHERE id LIKE '%\\_pasteur' ESCAPE '\\' AND total_sitio IS NULL
               AND estado = 'completa' AND substr(id, 1, 15) >= '20261111T000000'"
    dbExecute(con, paste0(ins, "SELECT ?, 'ejecuciones', id, 'total_sitio', NULL, '62', ? ", donde4),
              params = list(ahora, "Total declarado por el sitio verificado manualmente el 2026-11-11 (62 articulos); el scraper no lo habia leido"))
    dbExecute(con, paste("UPDATE ejecuciones SET total_sitio = 62 WHERE id IN (SELECT id", donde4, ")"))

    # 5) Contenido de Otirilin (Farmatodo): el patron tomaba "1 g" de la concentracion en vez de 13 mL
    otir <- dbGetQuery(con, "SELECT id, contenido_valor, contenido_unidad FROM anuncios
                             WHERE nombre_original LIKE 'Otirilin%'")
    if (nrow(otir) == 1 && identical(otir$contenido_unidad, "mL")) {
      ya <- dbGetQuery(con, "SELECT COUNT(*) n FROM correcciones
                             WHERE tabla = 'anuncios' AND registro_id = ? AND campo = 'contenido'",
                       params = list(as.character(otir$id)))$n
      if (ya == 0)
        dbExecute(con, paste0(ins, "VALUES (?,?,?,?,?,?,?)"),
                  params = list(ahora, "anuncios", as.character(otir$id), "contenido", "1 g",
                                paste(otir$contenido_valor, "mL"),
                                "El patron de contenido tomo la concentracion (4g/1g) en vez del volumen del envase; ahora toma la ultima medida del texto"))
    }
    # 6) Corridas intermedias del mismo dia: las copias crudas solo conservan la ultima corrida de
    #    cada dia, asi que las anteriores no se pueden verificar. Se marcan como descartadas.
    ejec <- dbGetQuery(con, "SELECT id, substr(id, 1, 15) AS corrida FROM ejecuciones")
    ult_dia <- tapply(ejec$corrida, substr(ejec$corrida, 1, 8), max)
    inter <- ejec[!(ejec$corrida %in% ult_dia), ]
    for (i in seq_len(nrow(inter))) {
      n <- dbGetQuery(con, "SELECT COUNT(*) n FROM observaciones WHERE ejecucion_id = ? AND descartada = 0",
                      params = list(inter$id[i]))$n
      if (n > 0) {
        dbExecute(con, paste0(ins, "VALUES (?,?,?,?,?,?,?)"),
                  params = list(ahora, "ejecuciones", inter$id[i], "observaciones",
                                paste(n, "validas"), "descartadas",
                                "Corrida intermedia del mismo dia: su copia cruda fue sobrescrita; para el analisis solo se conserva la ultima corrida de cada dia"))
        dbExecute(con, "UPDATE observaciones SET descartada = 1,
                          motivo_descarte = 'corrida intermedia del mismo dia (copia cruda sobrescrita)'
                        WHERE ejecucion_id = ? AND descartada = 0", params = list(inter$id[i]))
      }
    }
    dbCommit(con)
  }, error = function(e) { try(dbRollback(con), silent = TRUE); stop(e) })

  dbGetQuery(con, "SELECT tabla, campo, COUNT(*) AS n FROM correcciones GROUP BY tabla, campo ORDER BY n DESC")
}
