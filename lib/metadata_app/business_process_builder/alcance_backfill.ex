defmodule MetadataApp.BusinessProcessBuilder.AlcanceBackfill do
  @moduledoc """
  Fase 6b del modelo de Alcance de Datos (2026-08-11) — backfill al
  activar `alcance_habilitado` en un catálogo que YA tiene filas. Ver la
  nota larga en `CatalogoGenerico.aplicar_where_de_alcance/4`: una fila
  con la columna de alcance en `NULL` queda visible para cualquiera
  (mismo comportamiento que tenía el catálogo ANTES de activar el flag) —
  este módulo achica ese universo backfillendo lo único que SÍ se puede
  inferir de datos ya existentes: `creado_por_id`, desde
  `meta_schema_auditoria` (evento "alta"). `branch_id`/`sales_unit_id`/
  `inventory_id` no tienen equivalente — ningún dato de hoy dice a qué
  sucursal/unidad de venta/ubicación pertenecía un registro creado antes
  de que esas columnas existieran, así que se quedan `NULL` a propósito,
  para que un admin las corrija a mano si hace falta.
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.Auditoria

  @doc """
  Backfillea `creado_por_id` en las filas vivas de `schema_mod` que
  todavía lo tienen `nil`, usando el `usuario_id` del evento "alta" en
  auditoría cuando existe (no siempre lo tiene — el threadeo de
  `contexto` en `MetaAuditoria.registrar/6` no cubre todavía cada call
  site, es un límite conocido y aceptado, ver moduledoc de
  `MetaAuditoria`). Best-effort, nunca falla el toggle: sin columna
  `creado_por_id` en el catálogo, no-op.
  """
  def backfillear_creado_por(schema_mod) do
    if :creado_por_id in schema_mod.__schema__(:fields) do
      catalogo = schema_mod.__schema__(:source)

      altas_con_usuario =
        from(a in Auditoria,
          where: a.bc == ^catalogo and a.operacion == "alta" and not is_nil(a.usuario_id),
          select: {a.entidad_id, a.usuario_id}
        )
        |> Repo.all()

      Enum.reduce(altas_con_usuario, 0, fn {entidad_id, usuario_id}, actualizadas ->
        {n, _} =
          from(r in schema_mod, where: r.id == ^entidad_id and is_nil(field(r, :creado_por_id)))
          |> Repo.update_all(set: [creado_por_id: usuario_id])

        actualizadas + n
      end)
    else
      0
    end
  end
end
