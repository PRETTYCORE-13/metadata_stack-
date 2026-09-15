defmodule MetadataApp.Repo.Migrations.RenombrarCamposHistoricoConPrefijo do
  use Ecto.Migration

  # Corrección real (2026-09-15, a pedido explícito -- "cuando creaste
  # el catálogo debieron crearse con el nombre del catálogo + el nombre
  # del campo"): todo campo de negocio de un catálogo real en este
  # sistema se nombra "<catalogo>_<campo>" (ver pty_lista_precios_descripcion,
  # meta_fixture_cliente_nombre, etc.) -- el catálogo "historico" se
  # había creado sin ese prefijo. Se renombra la columna física
  # (RENAME COLUMN, preserva cualquier dato -- la tabla estaba vacía en
  # el momento de este fix, pero el mecanismo es igual de seguro con
  # filas reales) para cada uno de los 36 campos que todavía le
  # faltaba el prefijo (los otros 2 -- historico_pzaliq/historico_pedcted_desc1
  # -- ya se habían creado bien, a mano, después de borrar los
  # originales con el tipo de dato equivocado).
  @renombres [
    {:sysudn_codigo_k, :historico_sysudn_codigo_k},
    {:empleado, :historico_empleado},
    {:preventa, :historico_preventa},
    {:liquid_referencia, :historico_liquid_referencia},
    {:liquid_fechaent, :historico_liquid_fechaent},
    {:facdoc_referencia, :historico_facdoc_referencia},
    {:pedcte_referencia, :historico_pedcte_referencia},
    {:vtarut_codigo_k, :historico_vtarut_codigo_k},
    {:systts_codigo_k, :historico_systts_codigo_k},
    {:cred, :historico_cred},
    {:ctecli_fechaalta, :historico_ctecli_fechaalta},
    {:ctecli_rfc, :historico_ctecli_rfc},
    {:ctecli_codigo_k, :historico_ctecli_codigo_k},
    {:ctedir_codigo_k, :historico_ctedir_codigo_k},
    {:ctecli_dencomercia, :historico_ctecli_dencomercia},
    {:cadena, :historico_cadena},
    {:tipo, :historico_tipo},
    {:canal, :historico_canal},
    {:paquete, :historico_paquete},
    {:frecuencia, :historico_frecuencia},
    {:pround_codigo_k, :historico_pround_codigo_k},
    {:produc_codigo_k, :historico_produc_codigo_k},
    {:produc_descripcion, :historico_produc_descripcion},
    {:marca, :historico_marca},
    {:presentacion, :historico_presentacion},
    {:sabor, :historico_sabor},
    {:fabricante, :historico_fabricante},
    {:segmento, :historico_segmento},
    {:linea, :historico_linea},
    {:pzaprev, :historico_pzaprev},
    {:vtaprev, :historico_vtaprev},
    {:vtaliq, :historico_vtaliq},
    {:map_x, :historico_map_x},
    {:map_y, :historico_map_y},
    {:rechazo, :historico_rechazo},
    {:descuento, :historico_descuento}
  ]

  def up do
    for {viejo, nuevo} <- @renombres do
      rename table(:historico), viejo, to: nuevo
    end
  end

  def down do
    for {viejo, nuevo} <- @renombres do
      rename table(:historico), nuevo, to: viejo
    end
  end
end
