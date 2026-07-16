defmodule MetadataApp.MetaEstadosAdmin do
  @moduledoc """
  CRUD administrativo de Estados/Transiciones/Reglas del Motor de Estados.

  Distinto de `MetadataApp.MetaStateEngine` (que es runtime: ejecuta
  transiciones sobre registros) — este módulo solo escribe/lee la
  definición del autómata (`meta_schema_estados/transiciones/transicion_reglas`),
  pensado para armarse paso a paso desde la API en vez de por seeds.
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaStateEngine.Reglas
  alias MetadataApp.MetaSchema.{Estado, Transicion, TransicionRegla, TransicionEvento}

  # Vocabulario cerrado de reglas (ver MetaStateEngine.Reglas.{Pre,Post}):
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
      order_by: [asc: e.orden, asc: e.id]
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
      order_by: [asc: t.accion, asc: t.id],
      preload: [reglas: ^reglas_query()]
    )
    |> Repo.all()
  end

  def crear_transicion(attrs) do
    %Transicion{}
    |> Transicion.changeset(attrs)
    |> validar_campos_editables()
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  # campos_editables reemplaza a la convención vieja editable_en (ver
  # migración 20260716190000): en vez de un whitelist por estado escondido
  # en meta_schema_detail.schema_context_properties, cada transición declara
  # los suyos. Valida acá (no en Transicion.changeset/2) porque necesita
  # Repo — los schemas de este proyecto se mantienen sin acceso a datos,
  # igual que Estado/Header/Detail.
  defp validar_campos_editables(changeset) do
    Ecto.Changeset.validate_change(changeset, :campos_editables, fn :campos_editables, campos ->
      case campos do
        [] ->
          []

        _ ->
          case Ecto.Changeset.get_field(changeset, :meta_schema_header_id) do
            nil ->
              []

            header_id ->
              case Repo.get(Header, header_id) do
                nil ->
                  []

                header ->
                  campos_validos =
                    header.schema_context_name
                    |> MetaSchemaContext.listar_detalles()
                    |> MapSet.new(& &1.schema_context_field)

                  desconocidos = Enum.reject(campos, &MapSet.member?(campos_validos, &1))

                  case desconocidos do
                    [] ->
                      []

                    _ ->
                      [{:campos_editables, "campo(s) inexistente(s) en el catálogo: #{Enum.join(desconocidos, ", ")}"}]
                  end
              end
          end
      end
    end)
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
          |> validar_campos_editables_vacios(transiciones)
          |> validar_reglas(transiciones, catalogo)
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

  # Self-loop (guardar-style: mismo estado origen y destino) sin
  # campos_editables configurados es el gotcha que ya se dio en la práctica
  # (pty_aly_marcas) — acá queda visible ANTES de que un PUT real explote
  # con "no editable en el estado actual".
  defp validar_campos_editables_vacios(problemas, transiciones) do
    Enum.reduce(transiciones, problemas, fn t, acc ->
      self_loop? = not is_nil(t.estado_origen_id) and t.estado_origen_id == t.estado_destino_id

      if self_loop? and t.campos_editables == [] do
        [
          problema(
            :advertencia,
            "transición \"#{t.accion}\" (id #{t.id}) es un self-loop sin campos_editables — cualquier intento de editar por acá va a fallar"
          )
          | acc
        ]
      else
        acc
      end
    end)
  end

  defp validar_reglas(problemas, transiciones, catalogo) do
    Enum.reduce(transiciones, problemas, fn t, acc ->
      Enum.reduce(t.reglas, acc, &validar_regla(&2, t, &1, catalogo))
    end)
  end

  defp validar_regla(problemas, transicion, regla, catalogo) do
    case Map.get(@vocabulario, regla.regla) do
      nil ->
        validar_regla_de_negocio(problemas, transicion, regla, catalogo)

      {tipo_esperado, params_requeridos} ->
        problemas
        |> validar_tipo_regla(transicion, regla, tipo_esperado)
        |> validar_params_regla(transicion, regla, params_requeridos)
    end
  end

  # No está en el vocabulario cerrado — puede ser un módulo de negocio
  # (convención MetadataApp.MetaBusinessProcess.Reglas.<Catalogo>.<Regla>, ver Reglas.modulo_negocio/2).
  # No se puede validar el CONTENIDO de un módulo Elixir libre sin
  # ejecutarlo — esto solo confirma que existe y que implementa la función
  # correcta, el mismo chequeo que corre el motor de verdad al despachar.
  defp validar_regla_de_negocio(problemas, transicion, regla, catalogo) do
    modulo = Reglas.modulo_negocio(catalogo, regla.regla)
    {funcion, aridad} = if regla.tipo == "post", do: {:ejecutar, 4}, else: {:evaluar, 3}

    cond do
      not Code.ensure_loaded?(modulo) ->
        [
          problema(
            :error,
            "transición \"#{transicion.accion}\": la regla \"#{regla.regla}\" no existe en el vocabulario del motor ni como módulo de negocio (se esperaba #{inspect(modulo)})"
          )
          | problemas
        ]

      not function_exported?(modulo, funcion, aridad) ->
        [
          problema(:error, "transición \"#{transicion.accion}\": el módulo #{inspect(modulo)} existe pero no implementa #{funcion}/#{aridad}")
          | problemas
        ]

      true ->
        problemas
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
  # (ver BusinessProcessBuilder.CatalogoGenerador.eliminar/2), nunca desde el ciclo normal del motor.
  def purgar_historial(meta_schema_header_id) do
    from(ev in TransicionEvento, where: ev.meta_schema_header_id == ^meta_schema_header_id)
    |> Repo.delete_all()

    :ok
  end

  defp reglas_query, do: from(r in TransicionRegla, where: is_nil(r.delete_guid), order_by: [asc: r.orden, asc: r.id])

  defp reglas_de_transicion_query(transicion_id) do
    from r in TransicionRegla,
      where: r.transicion_id == ^transicion_id and is_nil(r.delete_guid),
      order_by: [asc: r.orden, asc: r.id]
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
