defmodule MetadataApp.Repo.Migrations.IndiceUnicoParametroPorPerfil do
  use Ecto.Migration

  @moduledoc """
  SPEC-ADN-2209202601, R6: el índice compuesto que genera el motor por
  catálogo detalle cubre encabezado_id + TODOS los campos de negocio
  juntos (encabezado_id, parametro, valor) -- no bloquea dos renglones
  con el MISMO parametro y valor DISTINTO dentro del mismo Perfil
  (verificado real: se insertó sin error). Un catálogo detalle nunca
  corre reglas PRE al insertar un renglón nuevo (hallazgo de esta spec,
  ver 02.design.md §5.2) -- por eso esto tiene que ser un índice real
  de Postgres, no una regla de negocio. Parcial (`WHERE delete_guid IS
  NULL`), mismo criterio que `meta_schema_estados_un_inicial_index`
  para no bloquear contra filas dadas de baja.
  """

  def change do
    create unique_index(:pty_config_perfilesdet, [:encabezado_id, :pty_config_perfilesdet_parametro],
             name: :pty_config_perfilesdet_parametro_unico_index,
             where: "delete_guid IS NULL"
           )
  end
end
