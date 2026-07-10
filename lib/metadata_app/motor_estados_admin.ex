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
  alias MetadataApp.MetaSchemaContext
  alias MetadataApp.MetaSchema.{Estado, Transicion, TransicionRegla, TransicionEvento}

  # Vocabulario cerrado de reglas (ver StateEngine.Reglas.{Pre,Post}):
  # nombre -> {tipo esperado, [parámetros requeridos]}. Única fuente de
  # verdad para validar_motor/1 — si el vocabulario real cambia, actualizar
  # acá también (no hay forma de derivarlo automáticamente de Pre/Post
  # porque son funciones con pattern matching, no datos introspectables).
  @vocabulario %{
    "campos_requeridos" => {"pre", ["campos"]},
    "campo_cumple" => {"pre", ["campo", "operador", "valor"]},
    "sin_relacionados" => {"pre", ["entidad", "campo_relacion"]},
    "requiere_rol" => {"pre", ["rol"]},
    "dato_en_contexto" => {"pre", ["dato"]},
    "estampar_valor" => {"post", ["campo", "valor"]},
    "mutar_relacionados" => {"post", ["entidad", "campo_relacion", "cambio"]},
    "notificar" => {"post", ["destinatario", "plantilla"]}
  }

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

  # --- Validación estructural del autómata ("¿esto va a funcionar?") -----------

  # Chequea el grafo entero de un catálogo (estados/transiciones/reglas) SIN
  # ejecutar nada — errores de configuración (typos en nombres de regla,
  # tipo pre/post equivocado, parámetros faltantes, estados de otro
  # catálogo, estados inalcanzables) se agarran acá, no cuando un cliente
  # real dispara la transición y el motor explota con un error interno.
  @spec validar_motor(String.t()) :: {:ok, map()} | {:error, String.t()}
  def validar_motor(catalogo) do
    case MetaSchemaContext.obtener_header_por_nombre(catalogo) do
      nil ->
        {:error, "catálogo no encontrado: #{catalogo}"}

      header ->
        estados = listar_estados(header.id)
        transiciones = listar_transiciones(header.id)

        problemas =
          []
          |> validar_estados_ajenos(transiciones, estados)
          |> validar_alta_o_inicial(estados, transiciones)
          |> validar_estados_huerfanos(estados, transiciones)
          |> validar_reglas(transiciones)
          |> Enum.reverse()

        {:ok,
         %{
           catalogo: catalogo,
           valido?: not Enum.any?(problemas, &(&1.severidad == :error)),
           problemas: problemas
         }}
    end
  end

  defp validar_estados_ajenos(problemas, transiciones, estados) do
    ids_propios = MapSet.new(estados, & &1.id)

    Enum.reduce(transiciones, problemas, fn t, acc ->
      ajenos =
        [t.estado_origen_id, t.estado_destino_id]
        |> Enum.reject(&is_nil/1)
        |> Enum.reject(&MapSet.member?(ids_propios, &1))

      case ajenos do
        [] ->
          acc

        _ ->
          [
            problema(
              :error,
              "transición \"#{t.accion}\" (id #{t.id}) referencia estado(s) que no son de este catálogo: #{inspect(ajenos)}"
            )
            | acc
          ]
      end
    end)
  end

  defp validar_alta_o_inicial(problemas, [], _transiciones), do: problemas

  defp validar_alta_o_inicial(problemas, estados, transiciones) do
    tiene_inicial? = Enum.any?(estados, & &1.es_inicial)
    tiene_alta? = Enum.any?(transiciones, &(&1.accion == "alta" and is_nil(&1.estado_origen_id)))

    if tiene_inicial? or tiene_alta? do
      problemas
    else
      [
        problema(
          :advertencia,
          "hay estados definidos pero ninguno es inicial y no existe una transición \"alta\" — los registros nuevos van a nacer sin estado_id"
        )
        | problemas
      ]
    end
  end

  defp validar_estados_huerfanos(problemas, estados, transiciones) do
    destinos = MapSet.new(transiciones, & &1.estado_destino_id)

    Enum.reduce(estados, problemas, fn e, acc ->
      if e.es_inicial or MapSet.member?(destinos, e.id) do
        acc
      else
        [
          problema(:advertencia, "el estado \"#{e.nombre}\" (id #{e.id}) es inalcanzable — ninguna transición lleva ahí y no es inicial")
          | acc
        ]
      end
    end)
  end

  defp validar_reglas(problemas, transiciones) do
    Enum.reduce(transiciones, problemas, fn t, acc ->
      Enum.reduce(t.reglas, acc, &validar_regla(&2, t, &1))
    end)
  end

  defp validar_regla(problemas, transicion, regla) do
    case Map.get(@vocabulario, regla.regla) do
      nil ->
        [
          problema(:error, "transición \"#{transicion.accion}\": la regla \"#{regla.regla}\" no existe en el vocabulario del motor")
          | problemas
        ]

      {tipo_esperado, params_requeridos} ->
        problemas
        |> validar_tipo_regla(transicion, regla, tipo_esperado)
        |> validar_params_regla(transicion, regla, params_requeridos)
    end
  end

  defp validar_tipo_regla(problemas, transicion, regla, tipo_esperado) do
    if regla.tipo == tipo_esperado do
      problemas
    else
      [
        problema(
          :error,
          "transición \"#{transicion.accion}\": la regla \"#{regla.regla}\" está configurada como \"#{regla.tipo}\" pero solo existe como \"#{tipo_esperado}\" — nunca va a ejecutarse, o va a romper con un error interno"
        )
        | problemas
      ]
    end
  end

  defp validar_params_regla(problemas, transicion, regla, requeridos) do
    faltantes = Enum.reject(requeridos, &Map.has_key?(regla.params, &1))

    case faltantes do
      [] ->
        problemas

      _ ->
        [
          problema(
            :error,
            "transición \"#{transicion.accion}\": a la regla \"#{regla.regla}\" le falta(n) parámetro(s): #{Enum.join(faltantes, ", ")}"
          )
          | problemas
        ]
    end
  end

  defp problema(severidad, mensaje), do: %{severidad: severidad, mensaje: mensaje}

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
