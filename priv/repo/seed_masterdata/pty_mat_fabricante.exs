# priv/repo/seed_masterdata/<catalogo>.exs — fixture editable a mano
# de "mix seed.cargar" (SPEC-TEST-1509202601). Lista plana de mapas,
# una entrada por registro; las llaves son los campos de negocio
# reales del catálogo (ver meta_schema_detail) tal como los pediría
# un alta real -- nunca "id"/"estado_id"/TRN, eso lo pone el motor.
[
  %{"pty_mat_fabricante_descripcion" => "GENERICA"},
  %{"pty_mat_fabricante_descripcion" => "IMPORTADOS SA"}
]
