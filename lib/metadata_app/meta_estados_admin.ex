defmodule MetadataApp.MetaEstadosAdmin do
  @moduledoc """
  CRUD administrativo de Estados/Transiciones del Motor de Estados.

  Distinto de `MetadataApp.MetaStateEngine` (que es runtime: ejecuta
  transiciones sobre registros) — este módulo solo escribe/lee la
  definición del autómata (`meta_schema_estados/transiciones`), pensado
  para armarse paso a paso desde la API en vez de por seeds.

  Las reglas PRE/POST (rediseño 2026-07-21) ya no viven acá — son código
  por catálogo, ver `MetadataApp.MetaReglasCodigo`.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaSchema.{Estado, Transicion, TransicionEvento}
  alias MetadataApp.MetaReglasCodigo

  # --- Estados ---------------------------------------------------------------

  def listar_estados(meta_schema_header_id) do
    from(e in Estado,
      where: e.meta_schema_header_id == ^meta_schema_header_id and is_nil(e.delete_guid),
      order_by: [asc: e.orden, asc: e.id]
    )
    |> Repo.all()
  end

  # El PRIMER estado real de un catálogo siempre nace marcado inicial —
  # sin importar qué haya tildado el usuario en el form, no queda a su
  # criterio (agregado 2026-07-21, pedido explícito). Evita el estado
  # intermedio inválido "hay estados pero ninguno es inicial" que
  # validar_motor/1 ya reportaba como advertencia — ahora es
  # estructuralmente imposible llegar ahí desde esta pantalla.
  def crear_estado(attrs) do
    attrs
    |> forzar_inicial_si_es_el_primero()
    |> insertar_estado()
  end

  # mix motor.import reproduce un export ya generado desde una base donde
  # el invariante de arriba ya se cumplía — forzarlo de nuevo acá podría
  # divergir en el caso raro de que el orden de exportación no coincida
  # con cuál estado es_inicial en el archivo. Import siempre pasa por
  # acá, nunca por crear_estado/1.
  def crear_estado_importado(attrs), do: insertar_estado(attrs)

  defp insertar_estado(attrs) do
    %Estado{}
    |> Estado.changeset(attrs)
    |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
    |> Repo.insert()
  end

  defp forzar_inicial_si_es_el_primero(attrs) do
    header_id = Map.get(attrs, "meta_schema_header_id")

    if header_id && not tiene_algun_estado?(header_id) do
      Map.put(attrs, "es_inicial", true)
    else
      attrs
    end
  end

  defp tiene_algun_estado?(header_id) do
    Repo.exists?(from e in Estado, where: e.meta_schema_header_id == ^header_id and is_nil(e.delete_guid))
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
      order_by: [asc: t.accion, asc: t.id]
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
                  # Fase 3 (R4): además de los campos propios del catálogo de
                  # esta transición, acepta los de cualquiera de sus
                  # catálogos DETALLE — así una transición del maestro puede
                  # declarar editables campos de sus renglones, sin choque
                  # de nombres porque schema_context_field ya viene
                  # prefijado por tabla.
                  campos_validos =
                    [header | MetaSchemaContext.listar_catalogos_detalle(header.id)]
                    |> Enum.flat_map(fn h -> h.schema_context_name |> MetaSchemaContext.listar_detalles() |> Enum.map(& &1.schema_context_field) end)
                    |> MapSet.new()

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

  # Soft-delete simple — ya no cascadea a reglas (rediseño 2026-07-21): las
  # reglas son código por catálogo, no filas hijas de la transición.
  def eliminar_transicion(%Transicion{} = transicion) do
    transicion
    |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
    |> Repo.update()
  end

  # --- Creación atómica completa (wizard "Nuevo Business Process") -------------

  # Crea Contexto+Campos+Estados+Transiciones en una única transacción —
  # todo o nada. Pensado para el wizard completo: mientras no estén las 3
  # piezas, no se persiste NADA. La generación de la tabla física
  # (CatalogoGenerador) NO entra acá a propósito — no es reversible por
  # Ecto (migración + archivo en disco + compile), así que corre aparte,
  # best-effort, después de que esta transacción ya haya confirmado.
  #
  # Ya NO exige "al menos una regla" (rediseño 2026-07-21): las reglas
  # PRE/POST son código a nivel catálogo (ver MetaReglasCodigo), no algo
  # que se pueda armar junto con la transición en este mismo paso — el
  # catálogo tiene que existir primero para que el generador de stub sepa
  # qué transiciones tiene.
  #
  # Espera:
  #   %{
  #     "header" => %{...mismo shape que MetaSchemaContext.crear_header_con_detalles/1, con "detalles" => [...]},
  #     "estados" => [%{"nombre" =>, "orden" =>, "es_inicial" =>, "color" =>, "icono" =>}, ...],
  #     "transiciones" => [
  #       %{"accion" =>, "etiqueta" =>, "estado_origen" => nombre_o_nil, "estado_destino" => nombre,
  #         "campos_editables" => [...]}
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
  #
  # Catálogo Maestro-Detalle (R3): un catálogo marcado "detalle de" (schema_encabezado_id
  # seteado) NUNCA usa sus propios estados/transiciones — el renglón nace
  # con el estado del maestro y se mueve solo cuando el maestro ejecuta una
  # transición compartida (ver MetaStateEngine.ejecutar_transicion/4). Exigirle
  # estados acá sería forzar a definir algo que el motor jamás va a leer.
  defp validar_completo(header_attrs, estados_attrs, transiciones_attrs) do
    detalles = header_attrs["detalles"] || []
    es_detalle? = header_attrs["schema_encabezado_id"] != nil
    tiene_inicial? = Enum.any?(estados_attrs, & &1["es_inicial"])
    tiene_alta? = Enum.any?(transiciones_attrs, &(&1["accion"] == "alta" and &1["estado_origen"] in [nil, ""]))

    cond do
      detalles == [] -> {:error, "hace falta al menos un campo"}
      es_detalle? -> :ok
      estados_attrs == [] -> {:error, "hace falta al menos un estado"}
      not (tiene_inicial? or tiene_alta?) -> {:error, "hace falta un estado inicial o una transición de alta"}
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
             {:ok, transicion} <- insertar_una_transicion(repo, header, t_attrs, origen_id, destino_id) do
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
  # borrado total, antes de que el usuario confirme. "reglas" cuenta
  # meta_schema_reglas_codigo (rediseño 2026-07-21, a lo sumo 2 filas: pre y
  # post) — la tabla vieja meta_schema_transicion_reglas ya no la llena
  # nadie, seguir contando ahí siempre daría 0 aunque el catálogo tenga
  # código de negocio real que se pierde con el borrado.
  def contar_escenario(meta_schema_header_id) do
    %{
      estados: Repo.aggregate(from(e in Estado, where: e.meta_schema_header_id == ^meta_schema_header_id), :count),
      transiciones: Repo.aggregate(from(t in Transicion, where: t.meta_schema_header_id == ^meta_schema_header_id), :count),
      reglas:
        Repo.aggregate(
          from(r in MetadataApp.MetaSchema.ReglaCodigo,
            where: r.meta_schema_header_id == ^meta_schema_header_id and is_nil(r.delete_guid)
          ),
          :count
        ),
      eventos: Repo.aggregate(from(ev in TransicionEvento, where: ev.meta_schema_header_id == ^meta_schema_header_id), :count)
    }
  end

  # --- Completitud del ciclo ("¿esto está terminado?") -------------------------

  # Checklist del ciclo completo de un Business Context: distinto de
  # validar_motor/1 (que dice "¿esto va a funcionar sin romperse?") — esto
  # dice "¿esto está terminado, o todavía es un borrador/andamiaje?".
  # Reglas PRE/POST (rediseño 2026-07-21) NO son obligatorias — si nunca se
  # generó código para el catálogo, no cuenta en contra de completo?. Si SÍ
  # se generó pero sigue siendo el stub sin tocar, ahí sí cuenta (empezado
  # pero sin terminar).
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

        pre_pendiente? = MetaReglasCodigo.pendiente?(header.id, "pre")
        post_pendiente? = MetaReglasCodigo.pendiente?(header.id, "post")

        tiene_campos? = detalles != []
        tiene_estados? = estados != []
        self_loops_ok? = self_loops_sin_campos == 0
        # Catálogo Maestro-Detalle (R3): un catálogo detalle nunca tiene
        # autómata propio — mismo criterio que validar_completo/3 (creación
        # vía wizard), acá para el gate de "Guardar BC" de un catálogo ya
        # existente. Sin esto, quedaba bloqueado para siempre (nunca puede
        # cumplir tiene_estados?/tiene_alta_o_inicial?, que no le aplican).
        es_detalle? = header.schema_encabezado_id != nil

        completo? =
          if es_detalle? do
            tiene_campos? and not pre_pendiente? and not post_pendiente?
          else
            tiene_campos? and tiene_estados? and tiene_alta_o_inicial? and self_loops_ok? and
              not pre_pendiente? and not post_pendiente?
          end

        {:ok,
         %{
           catalogo: catalogo,
           es_detalle: es_detalle?,
           tiene_campos: tiene_campos?,
           tiene_estados: tiene_estados?,
           tiene_alta_o_inicial: tiene_alta_o_inicial?,
           transiciones_self_loop: length(self_loops),
           transiciones_self_loop_sin_campos_editables: self_loops_sin_campos,
           reglas: %{
             pre_pendiente: pre_pendiente?,
             post_pendiente: post_pendiente?
           },
           completo?: completo?
         }}
    end
  end

  # Gate único de "¿este BC está listo para desplegar?" — mismo criterio
  # que antes vivía como puede_guardar_bc?/3 dentro de BcMotorLive (botón
  # "Guardar BC", retirado de ahí el 2026-07-23 y movido a "Despliegue" en
  # BcListLive). Completo (completitud/1) + estructuralmente válido
  # (validar_motor/1) + código de reglas sin error de sintaxis + en dev/
  # test, ya compilado (en producción no hay compilador, sin_compilar?/1
  # da false ahí siempre).
  def puede_desplegar?(catalogo) do
    case MetaSchemaContext.obtener_header_por_nombre(catalogo) do
      nil ->
        false

      header ->
        with {:ok, completitud} <- completitud(catalogo),
             {:ok, validacion} <- validar_motor(catalogo) do
          completitud.completo? and validacion.valido? and
            not MetaReglasCodigo.con_error_sintaxis?(header) and
            not MetaReglasCodigo.sin_compilar?(header)
        else
          _ -> false
        end
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
          |> validar_reglas_codigo(header, transiciones)
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

  # Advertencia (no error — el código puede ser correcto igual sin cubrir
  # una transición nueva) si el catálogo ya tiene código pre/post pero le
  # falta un `case` para alguna transición real — ver
  # MetaReglasCodigo.transiciones_sin_case/3. Si el catálogo nunca generó
  # código todavía, no hay nada que advertir (reglas no son obligatorias).
  defp validar_reglas_codigo(problemas, header, transiciones) do
    problemas
    |> validar_reglas_codigo_tipo(header, transiciones, "pre")
    |> validar_reglas_codigo_tipo(header, transiciones, "post")
  end

  defp validar_reglas_codigo_tipo(problemas, header, transiciones, tipo) do
    problemas
    |> validar_case_faltante(header, transiciones, tipo)
    |> validar_reglas_sin_compilar(header, tipo)
  end

  defp validar_case_faltante(problemas, header, transiciones, tipo) do
    case MetaReglasCodigo.transiciones_sin_case(header.id, tipo, transiciones) do
      [] ->
        problemas

      faltantes ->
        [
          problema(:advertencia, "código #{tipo} sin case para: #{Enum.join(faltantes, ", ")}")
          | problemas
        ]
    end
  end

  # Solo aplica en dev/test (compilar_disponible?) — en producción no hay
  # ".ex" en disco hasta que se hace git+deploy, así que comparar contra
  # disco ahí daría falso positivo en TODO catálogo con reglas, siempre.
  defp validar_reglas_sin_compilar(problemas, header, tipo) do
    if MetaReglasCodigo.compilar_disponible?() and not MetaReglasCodigo.sincronizado?(header, tipo) do
      [
        problema(:advertencia, "código #{tipo} tiene cambios guardados sin compilar — el motor todavía corre la versión anterior")
        | problemas
      ]
    else
      problemas
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
  # todavía no existe, ver MetaSchema.Transicion). "reglas" queda vacío a
  # propósito (compatibilidad de forma con el .motor.json viejo) — el
  # código PRE/POST ya no vive acá, ver MetaReglasCodigo.
  defp exportar_transicion(t, nombres_por_id) do
    %{
      accion: t.accion,
      etiqueta: t.etiqueta,
      empresa_id: t.empresa_id,
      estado_origen: t.estado_origen_id && Map.fetch!(nombres_por_id, t.estado_origen_id),
      estado_destino: Map.fetch!(nombres_por_id, t.estado_destino_id),
      campos_editables: t.campos_editables,
      reglas: []
    }
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
