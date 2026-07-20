defmodule MetadataApp.MetaEstadosAdmin do
  @moduledoc """
  CRUD administrativo de Estados/Transiciones/Reglas del Motor de Estados.

  Distinto de `MetadataApp.MetaStateEngine` (que es runtime: ejecuta
  transiciones sobre registros) — este módulo solo escribe/lee la
  definición del autómata (`meta_schema_estados/transiciones/transicion_reglas`),
  pensado para armarse paso a paso desde la API en vez de por seeds.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
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

  # Accessor público — BcMotorLive lo usa para armar el formulario dinámico
  # de "agregar regla" (opciones + parámetros exactos por regla), sin
  # duplicar esta lista en el LiveView.
  def vocabulario, do: @vocabulario

  # Sentinel literal que `mix motor.reglas.andamiar` escribe en cada stub
  # generado (ver lib/mix/tasks/motor.reglas.andamiar.ex) — un módulo de
  # negocio que compila y expone la función correcta pasa el chequeo
  # estructural de validar_regla_de_negocio/4 aunque el cuerpo siga siendo
  # el no-op del andamiaje. Buscar este string es la única forma barata de
  # distinguir "completo" de "stub sin tocar" sin ejecutar el módulo.
  @marcador_stub "# ESCRIBA SUS REGLAS AQUI"

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

  def actualizar_estado(%Estado{} = estado, attrs) do
    estado
    |> Estado.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  # Soft-delete (no Repo.delete): meta_schema_transiciones.estado_origen_id/
  # estado_destino_id tienen on_delete: :delete_all — un borrado físico acá
  # arrastraría en cascada TODAS las transiciones que lo usan (y por ende
  # sus reglas, mismo on_delete en transicion_reglas.transicion_id). Además
  # se bloquea de entrada si hay una transición activa que lo referencia —
  # mismo criterio ya usado para no dejar borrar una carpeta de BC List con
  # hijos: mejor un mensaje claro acá que un estado "fantasma" que
  # validar_motor recién detecta después como transición huérfana.
  def eliminar_estado(%Estado{} = estado) do
    if estado_referenciado?(estado.id) do
      {:error, :tiene_transiciones}
    else
      estado
      |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
      |> Repo.update()
    end
  end

  defp estado_referenciado?(estado_id) do
    from(t in Transicion,
      where: is_nil(t.delete_guid) and (t.estado_origen_id == ^estado_id or t.estado_destino_id == ^estado_id)
    )
    |> Repo.exists?()
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

  def actualizar_transicion(%Transicion{} = transicion, attrs) do
    transicion
    |> Transicion.changeset(attrs)
    |> validar_campos_editables()
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  # Soft-delete, y a diferencia de eliminar_estado/1 acá SÍ cascadea a sus
  # propias reglas — una TransicionRegla no es una entidad compartida entre
  # varias transiciones (a diferencia de un Estado, que sí puede ser
  # origen/destino de muchas), es hija exclusiva: no tiene sentido dejarla
  # viva colgando de una transición borrada. Todo o nada en una sola
  # transacción (mismo criterio que crear_transiciones/1).
  def eliminar_transicion(%Transicion{} = transicion) do
    Repo.transaction(fn ->
      reglas_activas = listar_reglas(transicion.id)

      Enum.each(reglas_activas, fn regla ->
        case eliminar_regla(regla) do
          {:ok, _} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

      transicion
      |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
      |> Repo.update()
      |> case do
        {:ok, transicion} -> transicion
        {:error, changeset} -> Repo.rollback(changeset)
      end
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

  def actualizar_regla(%TransicionRegla{} = regla, attrs) do
    regla
    |> TransicionRegla.changeset(attrs)
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
  end

  # Hoja del árbol (nada referencia una TransicionRegla) — soft-delete
  # directo, sin guardas de hijos.
  def eliminar_regla(%TransicionRegla{} = regla) do
    regla
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  # --- Creación atómica completa (wizard "Nuevo Business Process") -------------

  # Crea Contexto+Campos+Estados+Transiciones+Reglas en una única transacción
  # — todo o nada. Pensado para el wizard completo: mientras no estén las 4
  # piezas, no se persiste NADA (decisión explícita del usuario, más
  # estricta que completitud/1, que hoy considera válido un catálogo sin
  # ninguna regla). La generación de la tabla física (CatalogoGenerador) NO
  # entra acá a propósito — no es reversible por Ecto (migración + archivo
  # en disco + compile), así que corre aparte, best-effort, después de que
  # esta transacción ya haya confirmado.
  #
  # Espera:
  #   %{
  #     "header" => %{...mismo shape que MetaSchemaContext.crear_header_con_detalles/1, con "detalles" => [...]},
  #     "estados" => [%{"nombre" =>, "orden" =>, "es_inicial" =>, "color" =>, "icono" =>}, ...],
  #     "transiciones" => [
  #       %{"accion" =>, "etiqueta" =>, "estado_origen" => nombre_o_nil, "estado_destino" => nombre,
  #         "campos_editables" => [...], "reglas" => [%{"tipo" =>, "regla" =>, "params" =>, "orden" =>, "transaccional" =>}, ...]}
  #     ]
  #   }
  #
  # estado_origen/estado_destino se resuelven por NOMBRE, no por id — los
  # estados recién se están creando en esta misma llamada, mismo criterio ya
  # usado por `mix motor.import` para el autómata completo (ahí sin
  # atomicidad real entre pasos; acá sí, vía Ecto.Multi).
  #
  # Devuelve {:ok, %{header:, detalles:, estados:, transiciones:}} |
  # {:error, motivo} (guarda de completitud, antes de tocar la base) |
  # {:error, paso_fallido, valor, cambios_previos} (falla de Multi).
  def crear_proceso_completo(%{"header" => header_attrs, "estados" => estados_attrs, "transiciones" => transiciones_attrs}) do
    case validar_completo(header_attrs, estados_attrs, transiciones_attrs) do
      :ok ->
        Multi.new()
        |> Multi.run(:header, fn repo, _cambios -> insertar_header(repo, header_attrs) end)
        |> Multi.run(:detalles, fn repo, %{header: header} ->
          insertar_detalles(repo, header, header_attrs["detalles"] || [])
        end)
        |> Multi.run(:estados, fn repo, %{header: header} -> insertar_estados(repo, header, estados_attrs) end)
        |> Multi.run(:transiciones, fn repo, %{header: header, estados: estados_por_nombre} ->
          insertar_transiciones(repo, header, transiciones_attrs, estados_por_nombre)
        end)
        |> Repo.transaction()

      {:error, _motivo} = error ->
        error
    end
  end

  # Mismo criterio que validar_alta_o_inicial/2 (más abajo, para autómatas ya
  # guardados): un estado inicial O una transición de alta cualquiera de las
  # dos alcanza, no hace falta exigir literalmente "alta" si ya hay inicial.
  defp validar_completo(header_attrs, estados_attrs, transiciones_attrs) do
    detalles = header_attrs["detalles"] || []
    reglas_totales = Enum.flat_map(transiciones_attrs, &(&1["reglas"] || []))
    tiene_inicial? = Enum.any?(estados_attrs, & &1["es_inicial"])
    tiene_alta? = Enum.any?(transiciones_attrs, &(&1["accion"] == "alta" and &1["estado_origen"] in [nil, ""]))

    cond do
      detalles == [] -> {:error, "hace falta al menos un campo"}
      estados_attrs == [] -> {:error, "hace falta al menos un estado"}
      not (tiene_inicial? or tiene_alta?) -> {:error, "hace falta un estado inicial o una transición de alta"}
      reglas_totales == [] -> {:error, "hace falta al menos una regla (pre o post) en alguna transición"}
      true -> :ok
    end
  end

  defp insertar_header(repo, header_attrs) do
    header_attrs
    |> Map.drop(["detalles"])
    |> then(&Header.changeset(%Header{}, &1))
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> repo.insert()
  end

  defp insertar_detalles(repo, header, detalles_attrs) do
    insertar_todo_o_nada(detalles_attrs, fn detalle_attrs ->
      detalle_attrs
      |> Map.put("meta_schema_header_id", header.id)
      |> then(&Detail.changeset(%Detail{}, &1))
      |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
      |> repo.insert()
    end)
  end

  defp insertar_estados(repo, header, estados_attrs) do
    resultado =
      insertar_todo_o_nada(estados_attrs, fn estado_attrs ->
        estado_attrs
        |> Map.put("meta_schema_header_id", header.id)
        |> then(&Estado.changeset(%Estado{}, &1))
        |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
        |> repo.insert()
      end)

    case resultado do
      {:ok, estados} -> {:ok, Map.new(estados, &{&1.nombre, &1})}
      error -> error
    end
  end

  defp insertar_transiciones(repo, header, transiciones_attrs, estados_por_nombre) do
    resultado =
      Enum.reduce_while(transiciones_attrs, {:ok, []}, fn t_attrs, {:ok, acc} ->
        with {:ok, origen_id} <- resolver_estado_id(t_attrs["estado_origen"], estados_por_nombre),
             {:ok, destino_id} <- resolver_estado_id(t_attrs["estado_destino"], estados_por_nombre),
             {:ok, transicion} <- insertar_una_transicion(repo, header, t_attrs, origen_id, destino_id),
             {:ok, _reglas} <- insertar_reglas(repo, transicion, t_attrs["reglas"] || []) do
          {:cont, {:ok, [transicion | acc]}}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)

    case resultado do
      {:ok, transiciones} -> {:ok, Enum.reverse(transiciones)}
      error -> error
    end
  end

  defp insertar_una_transicion(repo, header, t_attrs, origen_id, destino_id) do
    atributos = %{
      "meta_schema_header_id" => header.id,
      "accion" => t_attrs["accion"],
      "etiqueta" => t_attrs["etiqueta"],
      "estado_origen_id" => origen_id,
      "estado_destino_id" => destino_id,
      "empresa_id" => t_attrs["empresa_id"],
      "campos_editables" => t_attrs["campos_editables"] || []
    }

    %Transicion{}
    |> Transicion.changeset(atributos)
    |> validar_campos_editables()
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> repo.insert()
  end

  defp resolver_estado_id(nil, _mapa), do: {:ok, nil}
  defp resolver_estado_id("", _mapa), do: {:ok, nil}

  defp resolver_estado_id(nombre, mapa) do
    case Map.fetch(mapa, nombre) do
      {:ok, estado} -> {:ok, estado.id}
      :error -> {:error, "estado \"#{nombre}\" no está en la lista de estados"}
    end
  end

  defp insertar_reglas(repo, transicion, reglas_attrs) do
    insertar_todo_o_nada(reglas_attrs, fn regla_attrs ->
      regla_attrs
      |> Map.put("transicion_id", transicion.id)
      |> then(&TransicionRegla.changeset(%TransicionRegla{}, &1))
      |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
      |> repo.insert()
    end)
  end

  # Inserta una lista todo-o-nada dentro de un paso de Multi.run — alcanza
  # con devolver {:error, _} en el primer fallo, Ecto.Multi ya se encarga
  # del rollback de toda la transacción (a diferencia de crear_header_con_detalles/1,
  # acá no hace falta Repo.rollback manual).
  defp insertar_todo_o_nada(lista, fun_insertar) do
    resultado =
      Enum.reduce_while(lista, {:ok, []}, fn item, {:ok, acc} ->
        case fun_insertar.(item) do
          {:ok, insertado} -> {:cont, {:ok, [insertado | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case resultado do
      {:ok, insertados} -> {:ok, Enum.reverse(insertados)}
      error -> error
    end
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

  # --- Completitud del ciclo ("¿esto está terminado?") -------------------------

  # Checklist del ciclo completo de un Business Context: distinto de
  # validar_motor/1 (que dice "¿esto va a funcionar sin romperse?") — esto
  # dice "¿esto está terminado, o todavía es un borrador/andamiaje?".
  # completo?/1 exige, además de la estructura sana, que NINGUNA regla de
  # negocio siga siendo un stub sin completar — es la pregunta que
  # validar_motor deliberadamente no contesta (una regla stub es
  # estructuralmente válida: compila y expone la función correcta).
  @spec completitud(String.t()) :: {:ok, map()} | {:error, String.t()}
  def completitud(catalogo) do
    case MetaSchemaContext.obtener_header_por_nombre(catalogo) do
      nil ->
        {:error, "catálogo no encontrado: #{catalogo}"}

      header ->
        detalles = MetaSchemaContext.listar_detalles(catalogo)
        estados = listar_estados(header.id)
        transiciones = listar_transiciones(header.id)

        tiene_alta_o_inicial? =
          Enum.any?(estados, & &1.es_inicial) or
            Enum.any?(transiciones, &(&1.accion == "alta" and is_nil(&1.estado_origen_id)))

        self_loops =
          Enum.filter(transiciones, &(not is_nil(&1.estado_origen_id) and &1.estado_origen_id == &1.estado_destino_id))

        self_loops_sin_campos = Enum.count(self_loops, &(&1.campos_editables == []))

        reglas = Enum.flat_map(transiciones, & &1.reglas)
        {reglas_cerradas, reglas_negocio} = Enum.split_with(reglas, &Map.has_key?(@vocabulario, &1.regla))
        reglas_negocio_stub = Enum.count(reglas_negocio, &stub_sin_completar?(catalogo, &1.regla))

        tiene_campos? = detalles != []
        tiene_estados? = estados != []
        self_loops_ok? = self_loops_sin_campos == 0

        {:ok,
         %{
           catalogo: catalogo,
           tiene_campos: tiene_campos?,
           tiene_estados: tiene_estados?,
           tiene_alta_o_inicial: tiene_alta_o_inicial?,
           transiciones_self_loop: length(self_loops),
           transiciones_self_loop_sin_campos_editables: self_loops_sin_campos,
           reglas: %{
             total: length(reglas),
             vocabulario_cerrado: length(reglas_cerradas),
             negocio_completas: length(reglas_negocio) - reglas_negocio_stub,
             negocio_stub: reglas_negocio_stub
           },
           completo?:
             tiene_campos? and tiene_estados? and tiene_alta_o_inicial? and self_loops_ok? and
               reglas_negocio_stub == 0
         }}
    end
  end

  # --- Validación estructural del autómata ("¿esto va a funcionar?") -----------

  # Chequeo estructural: "¿esto va a funcionar sin romperse?" — distinto de
  # completitud/1 ("¿esto está terminado?"). Errores de configuración (typos
  # en nombres de regla, tipo pre/post equivocado, parámetros faltantes,
  # estados de otro catálogo, estados inalcanzables) se agarran acá, no
  # cuando un cliente real dispara la transición y el motor explota con un
  # error interno.
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

      stub_sin_completar?(catalogo, regla.regla) ->
        [
          problema(
            :advertencia,
            "transición \"#{transicion.accion}\": la regla \"#{regla.regla}\" sigue siendo un stub de andamiaje sin completar (#{ruta_regla_negocio(catalogo, regla.regla)})"
          )
          | problemas
        ]

      true ->
        problemas
    end
  end

  def ruta_regla_negocio(catalogo, regla),
    do: Path.join(["lib", "metadata_app", "meta_business_process", "reglas", catalogo, "#{regla}.ex"])

  def stub_sin_completar?(catalogo, regla) do
    ruta = ruta_regla_negocio(catalogo, regla)
    File.exists?(ruta) and String.contains?(File.read!(ruta), @marcador_stub)
  end

  # --- Andamiaje de reglas de negocio (compartido entre BcMotorLive y
  # Mix.Tasks.Motor.Reglas.Andamiar) ------------------------------------------

  # Genera (si no existe) el stub de una regla de negocio para UNA
  # transición y UN tipo puntual, y la engancha — mismo comportamiento que
  # `mix motor.reglas.andamiar`, pero acotado a una sola transición/tipo en
  # vez de recorrer todo el catálogo, para poder ofrecerlo como una acción
  # de un click desde la UI. Vive acá (no en el Mix.Task) porque un Mix.Task
  # no está pensado para invocarse desde un proceso de la app ya corriendo
  # (BcMotorLive lo llama en caliente) — el Mix.Task pasa a ser un wrapper
  # fino sobre esto para el uso por consola.
  #
  # Devuelve {:error, :ya_tiene_regla} si la transición ya tiene una regla
  # de ese tipo (con el nombre que sea) — no la reemplaza ni agrega una
  # segunda, mismo invariante que el Mix.Task.
  @spec andamiar_regla_negocio(String.t(), Transicion.t(), String.t()) ::
          {:ok, %{creado?: boolean(), ruta: String.t(), regla: String.t()}} | {:error, :ya_tiene_regla}
  def andamiar_regla_negocio(catalogo, %Transicion{} = transicion, tipo) when tipo in ["pre", "post"] do
    reglas_actuales = listar_reglas(transicion.id)

    if Enum.any?(reglas_actuales, &(&1.tipo == tipo)) do
      {:error, :ya_tiene_regla}
    else
      nombre_regla = "#{transicion.accion}_#{tipo}"
      ruta = ruta_regla_negocio(catalogo, nombre_regla)
      creado? = escribir_stub_si_no_existe(ruta, catalogo, nombre_regla, tipo)

      case crear_regla(%{"transicion_id" => transicion.id, "tipo" => tipo, "regla" => nombre_regla, "orden" => 0}) do
        {:ok, _regla} -> {:ok, %{creado?: creado?, ruta: ruta, regla: nombre_regla}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp escribir_stub_si_no_existe(ruta, catalogo, nombre_regla, "pre") do
    if File.exists?(ruta) do
      false
    else
      File.mkdir_p!(Path.dirname(ruta))

      File.write!(ruta, """
      defmodule MetadataApp.MetaBusinessProcess.Reglas.#{Macro.camelize(catalogo)}.#{Macro.camelize(nombre_regla)} do
        @behaviour MetadataApp.MetaStateEngine.ReglaPre

        @impl true
        def evaluar(_registro, _contexto, _params) do
          # ESCRIBA SUS REGLAS AQUI
          :ok
        end
      end
      """)

      true
    end
  end

  defp escribir_stub_si_no_existe(ruta, catalogo, nombre_regla, "post") do
    if File.exists?(ruta) do
      false
    else
      File.mkdir_p!(Path.dirname(ruta))

      File.write!(ruta, """
      defmodule MetadataApp.MetaBusinessProcess.Reglas.#{Macro.camelize(catalogo)}.#{Macro.camelize(nombre_regla)} do
        @behaviour MetadataApp.MetaStateEngine.ReglaPost

        @impl true
        def ejecutar(_registro, _contexto, _params, _repo) do
          # ESCRIBA SUS REGLAS AQUI
          {:ok, :sin_cambios}
        end
      end
      """)

      true
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

  # --- Export --------------------------------------------------------------

  # Exporta el autómata de ESTE header a <dir>/<catalogo>.motor.json —
  # compartido entre `mix motor.export` (recorre todos) y el botón
  # "Guardar BC" de BcMotorLive (uno solo). nil si el catálogo no adoptó
  # el motor (sin estados) — no le corresponde archivo, mismo criterio
  # que ya usaba el Mix.Task.
  def exportar_header(header, dir \\ "priv/repo/catalogos") do
    estados = listar_estados(header.id)

    if estados == [] do
      nil
    else
      File.mkdir_p!(dir)
      transiciones = listar_transiciones(header.id)
      nombres_por_id = Map.new(estados, &{&1.id, &1.nombre})

      contenido =
        Jason.encode!(
          %{
            catalogo: header.schema_context_name,
            estados: Enum.map(estados, &exportar_estado/1),
            transiciones: Enum.map(transiciones, &exportar_transicion(&1, nombres_por_id))
          },
          pretty: true
        )

      File.write!(Path.join(dir, "#{header.schema_context_name}.motor.json"), contenido)
      header.schema_context_name
    end
  end

  defp exportar_estado(e) do
    %{nombre: e.nombre, orden: e.orden, es_inicial: e.es_inicial, color: e.color, icono: e.icono, empresa_id: e.empresa_id}
  end

  # estado_origen puede ser nil (transición de "alta" — el registro
  # todavía no existe, ver MetaSchema.Transicion).
  defp exportar_transicion(t, nombres_por_id) do
    %{
      accion: t.accion,
      etiqueta: t.etiqueta,
      empresa_id: t.empresa_id,
      estado_origen: t.estado_origen_id && Map.fetch!(nombres_por_id, t.estado_origen_id),
      estado_destino: Map.fetch!(nombres_por_id, t.estado_destino_id),
      campos_editables: t.campos_editables,
      reglas: Enum.map(t.reglas, &exportar_regla/1)
    }
  end

  defp exportar_regla(r) do
    %{tipo: r.tipo, regla: r.regla, params: r.params, orden: r.orden, transaccional: r.transaccional}
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
