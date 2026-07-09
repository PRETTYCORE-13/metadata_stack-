defmodule MetadataApp.MotorEstadosAdmin do
  @moduledoc """
  CRUD administrativo de Estados/Transiciones/Reglas del Motor de Estados.

  Distinto de `MetadataApp.StateEngine` (que es runtime: ejecuta
  transiciones sobre registros) — este módulo solo escribe/lee la
  definición del autómata (`meta_schema_estados/transiciones/transicion_reglas`),
  pensado para armarse paso a paso desde la API en vez de por seeds.
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.{Estado, Transicion, TransicionRegla, TransicionEvento}

  # --- Estados ---------------------------------------------------------------

  def listar_estados(meta_schema_header_id) do
    from(e in Estado,
      where: e.meta_schema_header_id == ^meta_schema_header_id and is_nil(e.delete_guid),
      order_by: e.orden
    )
    |> Repo.all()
  end

  def crear_estado(attrs) do
    %Estado{}
    |> Estado.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  # Todo o nada: ver crear_transiciones/1.
  def crear_estados(lista_attrs) do
    Repo.transaction(fn ->
      Enum.map(lista_attrs, fn attrs ->
        case crear_estado(attrs) do
          {:ok, estado} -> estado
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  # --- Transiciones ------------------------------------------------------------

  def listar_transiciones(meta_schema_header_id) do
    from(t in Transicion,
      where: t.meta_schema_header_id == ^meta_schema_header_id and is_nil(t.delete_guid),
      preload: [reglas: ^reglas_query()]
    )
    |> Repo.all()
  end

  def crear_transicion(attrs) do
    %Transicion{}
    |> Transicion.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  # Todo o nada: si una transición de la lista falla, ninguna queda creada
  # (evita dejar el autómata a medio armar por un typo en la N-ésima).
  def crear_transiciones(lista_attrs) do
    Repo.transaction(fn ->
      Enum.map(lista_attrs, fn attrs ->
        case crear_transicion(attrs) do
          {:ok, transicion} -> transicion
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  # --- Reglas ------------------------------------------------------------------

  def listar_reglas(transicion_id) do
    transicion_id
    |> reglas_de_transicion_query()
    |> Repo.all()
  end

  def crear_regla(attrs) do
    %TransicionRegla{}
    |> TransicionRegla.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  # Todo o nada: ver crear_transiciones/1.
  def crear_reglas(lista_attrs) do
    Repo.transaction(fn ->
      Enum.map(lista_attrs, fn attrs ->
        case crear_regla(attrs) do
          {:ok, regla} -> regla
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  # --- Historial / borrado total -----------------------------------------------

  # Cuántas filas tiene cada tabla del motor para este header — usado por
  # CatalogoAdminController.impacto para avisar qué se va a llevar puesto un
  # borrado total, antes de que el usuario confirme.
  def contar_escenario(meta_schema_header_id) do
    transicion_ids =
      from(t in Transicion, where: t.meta_schema_header_id == ^meta_schema_header_id, select: t.id)
      |> Repo.all()

    %{
      estados: Repo.aggregate(from(e in Estado, where: e.meta_schema_header_id == ^meta_schema_header_id), :count),
      transiciones: length(transicion_ids),
      reglas: Repo.aggregate(from(r in TransicionRegla, where: r.transicion_id in ^transicion_ids), :count),
      eventos: Repo.aggregate(from(ev in TransicionEvento, where: ev.meta_schema_header_id == ^meta_schema_header_id), :count)
    }
  end

  # meta_schema_transicion_eventos usa on_delete: :restrict A PROPÓSITO
  # (protege el historial del uso normal — ver comentario en su migración).
  # Esto lo puentea deliberadamente: solo se llama desde un borrado total ya
  # confirmado explícitamente por el usuario repitiendo el nombre de tabla
  # (ver CatalogoGenerador.eliminar/2), nunca desde el ciclo normal del motor.
  def purgar_historial(meta_schema_header_id) do
    from(ev in TransicionEvento, where: ev.meta_schema_header_id == ^meta_schema_header_id)
    |> Repo.delete_all()

    :ok
  end

  defp reglas_query, do: from(r in TransicionRegla, where: is_nil(r.delete_guid), order_by: r.orden)

  defp reglas_de_transicion_query(transicion_id) do
    from r in TransicionRegla,
      where: r.transicion_id == ^transicion_id and is_nil(r.delete_guid),
      order_by: r.orden
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
