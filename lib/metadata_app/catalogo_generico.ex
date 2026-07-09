defmodule MetadataApp.CatalogoGenerico do
  alias MetadataApp.Repo
  import Ecto.Query

  def listar(schema_mod) do
    Repo.all(from(r in schema_mod, where: is_nil(r.delete_guid)))
  end

  def obtener!(schema_mod, id) do
    Repo.one!(from(r in schema_mod, where: r.id == ^id and is_nil(r.delete_guid)))
  end

  # Si el catálogo definió una transición "alta" (estado_origen_id nil, ver
  # StateEngine.transicion_alta/1), el nacimiento del registro pasa por el
  # mismo ciclo de reglas pre/post que cualquier transición — permite
  # prevalidar (campos_requeridos, requiere_rol, ...) o disparar efectos
  # (estampar_valor, notificar, ...) al crear, no solo al transicionar
  # después. Si el catálogo nunca definió esa transición (ej. pty_clientes
  # hoy), sigue el insert directo de siempre — 100% retrocompatible.
  def crear(schema_mod, attrs) do
    catalogo = schema_mod.__schema__(:source)

    case MetadataApp.StateEngine.transicion_alta(catalogo) do
      nil -> crear_simple(schema_mod, attrs)
      transicion -> MetadataApp.StateEngine.dar_de_alta(schema_mod, attrs, transicion, attrs)
    end
  end

  defp crear_simple(schema_mod, attrs) do
    catalogo = schema_mod.__schema__(:source)
    estado_inicial = MetadataApp.StateEngine.estado_inicial(catalogo)

    schema_mod
    |> struct()
    |> schema_mod.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> asignar_estado_inicial(estado_inicial)
    |> Repo.insert()
  end

  # Si el catálogo adoptó el motor de estados, todo registro nuevo nace en
  # su estado inicial — si no, no hay nada que asignar (estado_id queda nil,
  # como siempre para catálogos sin motor de estados).
  defp asignar_estado_inicial(changeset, nil), do: changeset

  defp asignar_estado_inicial(changeset, estado_inicial),
    do: Ecto.Changeset.change(changeset, %{estado_id: estado_inicial.id})

  # Crea varios registros del mismo catálogo en una sola transacción.
  # Si alguno falla, se revierten todos (todo o nada).
  def crear_muchos(schema_mod, lista_attrs) when is_list(lista_attrs) do
    Repo.transaction(fn ->
      Enum.map(lista_attrs, fn attrs ->
        case crear(schema_mod, attrs) do
          {:ok, registro} -> registro
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  def actualizar(registro, attrs) do
    schema_mod = registro.__struct__
    catalogo = schema_mod.__schema__(:source)
    editables = MetadataApp.StateEngine.campos_editables(catalogo, registro.estado_id)

    todos_los_campos =
      MetadataApp.MetaSchemaContext.listar_detalles(catalogo)
      |> Enum.map(& &1.schema_context_field)

    registro
    |> schema_mod.changeset(attrs)
    |> rechazar_no_editables(attrs, todos_los_campos, editables)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  # Rechaza explícitamente (error visible en el changeset, no ignorado en
  # silencio) cualquier intento de tocar un campo que no esté en la
  # whitelist de editables para el estado actual del registro. `estado_id`
  # se protege aparte porque no es un campo "de negocio" (no vive en
  # meta_schema_detail, así que nunca aparece en `todos_los_campos`) — el
  # único camino para cambiarlo es `StateEngine.ejecutar_transicion/3`.
  defp rechazar_no_editables(changeset, attrs, todos_los_campos, editables) do
    editables_set = MapSet.new(editables)
    protegidos = ["estado_id" | todos_los_campos]

    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in protegidos and &1 not in editables_set))
    |> Enum.reduce(changeset, fn campo, cs ->
      Ecto.Changeset.add_error(
        cs,
        String.to_existing_atom(campo),
        "no editable en el estado actual"
      )
    end)
  end

  def eliminar(registro) do
    registro
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  # estados_por_id: %{estado_id => nombre} (ver StateEngine.mapa_nombres_estados/1)
  # — opcional para no romper otros llamadores; sin él, o si el registro no
  # tiene estado_id asignado, no agrega estado_nombre.
  def serializar(registro, estados_por_id \\ %{}) do
    registro
    |> Map.from_struct()
    |> Map.drop([:__meta__, :insert_guid, :update_guid, :delete_guid])
    |> agregar_estado_nombre(estados_por_id)
  end

  defp agregar_estado_nombre(%{estado_id: nil} = mapa, _estados_por_id), do: mapa

  defp agregar_estado_nombre(%{estado_id: estado_id} = mapa, estados_por_id) do
    Map.put(mapa, :estado_nombre, Map.get(estados_por_id, estado_id))
  end

  defp agregar_estado_nombre(mapa, _estados_por_id), do: mapa

  # Valida que el valor de `campo` no exista ya como `campo_externo` en
  # `tabla_externa` (unicidad cross-catálogo). `tabla_externa` es un nombre de
  # tabla, no un módulo — se consulta sin schema Ecto compilado.
  def validar_unico_en(changeset, campo, tabla_externa, campo_externo) do
    case Ecto.Changeset.get_change(changeset, campo) do
      nil ->
        changeset

      valor ->
        campo_externo_atom = String.to_existing_atom(campo_externo)

        existe? =
          Repo.exists?(
            from t in tabla_externa,
              where: field(t, ^campo_externo_atom) == ^valor,
              where: is_nil(field(t, :delete_guid))
          )

        if existe? do
          Ecto.Changeset.add_error(changeset, campo, "ya existe en #{tabla_externa}")
        else
          changeset
        end
    end
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
