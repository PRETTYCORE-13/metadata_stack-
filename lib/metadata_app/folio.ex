defmodule MetadataApp.Folio do
  @moduledoc """
  Asigna folio de negocio (NDT, ver `MetadataApp.NDT.Numbering`) a un
  registro recién creado, si su catálogo lo requiere (`requiere_folio`
  en `meta_schema_header`) — mismo rol y mismo punto de enganche que
  `MetadataApp.TRN` (corre justo después, ver
  `CatalogoGenerico.crear_con_attrs_preparados/5`), pero agnóstico de
  `Scope`: en vez de recibir el scope de quien crea (no llega hasta acá,
  ver la nota de `crear_con_attrs_preparados/5`), resuelve la
  Organización directamente del registro ya insertado, vía
  `branch_id -> Branch.empresa_id`.

  Esto SIEMPRE es posible porque `requiere_folio: true` exige
  `alcance_habilitado: true` (ver `Header.validar_requiere_folio/1`), y
  un catálogo con Alcance de Datos activo garantiza `branch_id` presente
  en cualquier alta (`CatalogoGenerico.validar_jerarquia_requerida_en_attrs/2`)
  — la única excepción es una alta con `scope: :sistema` que no haya
  pasado `branch_id` a mano, caso en el que se rechaza con
  `{:error, :organizacion_no_resuelta}` en vez de crear un documento sin
  folio quien lo necesitaba.
  """

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.Branch
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.NDT.Numbering

  def asignar_si_configurado({:error, _} = error), do: error

  def asignar_si_configurado({:ok, registro}) do
    catalogo = registro.__struct__.__schema__(:source)
    header = MetaSchemaContext.obtener_header_por_nombre(catalogo)

    if header && header.requiere_folio do
      asignar(registro, header)
    else
      {:ok, registro}
    end
  end

  defp asignar(registro, header) do
    branch_id = Map.get(registro, :branch_id)

    with {:ok, empresa_id} <- resolver_empresa(branch_id),
         {:ok, %{folio: folio}} <- pedir_folio(header, empresa_id, branch_id, registro) do
      registro |> Ecto.Changeset.change(%{folio: folio}) |> Repo.update()
    end
  end

  defp pedir_folio(header, empresa_id, branch_id, registro) do
    Numbering.next(
      meta_schema_header_id: header.id,
      empresa_id: empresa_id,
      branch_id: branch_id,
      trn: Map.get(registro, :trn),
      entity_id: registro.id,
      # Retry seguro ante un timeout/reintento del caller de crear/2: el
      # mismo registro (ya con id asignado) nunca pide dos folios.
      idempotency_key: "entidad-#{registro.id}"
    )
  end

  defp resolver_empresa(nil), do: {:error, :organizacion_no_resuelta}

  defp resolver_empresa(branch_id) do
    case Repo.get(Branch, branch_id) do
      %Branch{empresa_id: empresa_id} -> {:ok, empresa_id}
      nil -> {:error, :sucursal_no_encontrada}
    end
  end
end
