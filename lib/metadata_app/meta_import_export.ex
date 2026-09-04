defmodule MetadataApp.MetaImportExport do
  @moduledoc """
  Lógica de importación de metadata (catálogos + autómata) SIN ninguna
  dependencia de `Mix` — extraída de `mix meta.import`/`mix motor.import`
  (2026-07-23) porque `MetadataApp.Release` (que corre en un release de
  producción, donde `Mix` no existe) también necesita invocarla — ver
  `rel/overlays/bin/import_meta`, usado por `.github/workflows/bc-deploy.yml`
  para poblar `meta_schema_header`/`detail`/`estados`/`transiciones` de un
  BC recién desplegado (la migración crea la TABLA física; esto es lo que
  falta para que el catálogo exista como Business Context real).

  Cada función devuelve una lista de mensajes de texto en vez de escribir
  directo — el caller (un Mix.Task vía `Mix.shell().info/1`, o un release
  script vía `IO.puts/1`) decide cómo mostrarlos.
  """

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

  @doc "Importa cada `*.meta.json` de `dir` — crea el Header+Detalles si el catálogo no existe todavía; si ya existe, sincroniza campos nuevos que no tenía."
  def importar_meta(dir \\ "priv/repo/catalogos") do
    # Maestros antes que detalles: un detalle trae "schema_encabezado_catalogo"
    # (el NOMBRE de su maestro, ver MetaSchemaContext.exportar_header/2) que
    # hay que resolver a un id local -- si el maestro todavía no se importó
    # (ej. orden alfabético del directorio, donde "..._det" < "..._enc"),
    # no hay id que resolver todavía. Sin multinivel (un detalle nunca es
    # maestro de otro), dos pasadas alcanzan.
    {sin_maestro, con_maestro} =
      dir
      |> leer_json(".meta.json")
      |> Enum.split_with(&is_nil(&1["schema_encabezado_catalogo"]))

    Enum.map(sin_maestro ++ con_maestro, &importar_contexto/1)
  end

  defp importar_contexto(contexto) do
    nombre = contexto["schema_context_name"]

    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        case resolver_encabezado(contexto) do
          {:error, mensaje} ->
            raise "Error importando #{nombre}: #{mensaje}"

          {:ok, contexto} ->
            case MetaSchemaContext.crear_header_con_detalles(contexto) do
              {:ok, {_header, _detalles}} -> "+ #{nombre}: creado"
              {:error, motivo} -> raise "Error importando #{nombre}: #{inspect(motivo)}"
            end
        end

      existente ->
        cambios =
          Enum.reject(
            [
              if(sincronizar_icono(existente, contexto["schema_context_icono"]), do: "ícono actualizado"),
              case sincronizar_detalles_nuevos(existente, contexto["detalles"] || []) do
                [] -> nil
                campos -> "campo(s) nuevo(s) sincronizado(s): #{Enum.join(campos, ", ")}"
              end,
              case sincronizar_etiquetas_campos(existente, contexto["detalles"] || []) do
                [] -> nil
                campos -> "etiqueta(s) actualizada(s): #{Enum.join(campos, ", ")}"
              end,
              case sincronizar_obligatorio_campos(existente, contexto["detalles"] || []) do
                [] -> nil
                campos -> "obligatoriedad actualizada: #{Enum.join(campos, ", ")}"
              end,
              case sincronizar_parametros_y_totales(existente, contexto["detalles"] || []) do
                [] -> nil
                campos -> "parámetro(s)/total(es) actualizado(s): #{Enum.join(campos, ", ")}"
              end,
              if(sincronizar_cargar_todos_por_default(existente, contexto["cargar_todos_por_default"]),
                do: "\"traer todo por default\" actualizado"
              ),
              case sincronizar_columnas_estructurales(existente, contexto) do
                [] -> nil
                campos -> "columnas estructurales actualizadas: #{Enum.join(campos, ", ")}"
              end,
              if(
                sincronizar_transaccional(
                  existente,
                  contexto["schema_es_transaccional"],
                  contexto["codigo_trn"]
                ),
                do: "TRN activado (código #{contexto["codigo_trn"]})"
              )
            ],
            &is_nil/1
          )

        case cambios do
          [] -> "= #{nombre}: ya existía, sin cambios"
          cambios -> "~ #{nombre}: ya existía, #{Enum.join(cambios, "; ")}"
        end
    end
  end

  # Igual que sincronizar_detalles_nuevos/2 pero para el ícono del propio
  # header: sin esto, cambiar el ícono de un BC ya publicado y volver a
  # publicar no lo actualizaba (importar_contexto/1 solo creaba o dejaba
  # intacto). `false` en el chequeo de igualdad cubre tanto "no cambió"
  # como "el bundle no trae ícono" (nil), sin tocar la BD innecesariamente.
  defp sincronizar_icono(_header, nil), do: false

  defp sincronizar_icono(%{schema_context_icono: mismo}, mismo), do: false

  defp sincronizar_icono(header, icono_nuevo) do
    case MetaSchemaContext.actualizar_header(header, %{"schema_context_icono" => icono_nuevo}) do
      {:ok, _header} ->
        true

      {:error, changeset} ->
        raise "Error sincronizando ícono de #{header.schema_context_name}: #{inspect(changeset.errors)}"
    end
  end

  # "Traer todos los registros y columnas apenas se abre la tabla" (2026-08-04)
  # -- mismo criterio que sincronizar_icono/2: es un flag que sólo cambia
  # cómo arranca el GET genérico, no toca estructura ni datos, así que es
  # seguro sobreescribirlo con lo que diga el bundle. `nil` cubre bundles
  # exportados antes de que este campo existiera.
  defp sincronizar_cargar_todos_por_default(_header, nil), do: false

  defp sincronizar_cargar_todos_por_default(%{cargar_todos_por_default: mismo}, mismo), do: false

  defp sincronizar_cargar_todos_por_default(header, nuevo_valor) do
    case MetaSchemaContext.actualizar_header(header, %{"cargar_todos_por_default" => nuevo_valor}) do
      {:ok, _header} ->
        true

      {:error, changeset} ->
        raise "Error sincronizando \"cargar_todos_por_default\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
    end
  end

  # Get View → columnas estructurales (ID/Estado/TRN, 2026-08-06; Empresa/
  # Sucursal/Almacén/Unidad de venta sumadas 2026-08-13, bug operacional
  # encontrado en vivo: se agregaron esas 4 columnas de Alcance de Datos a
  # Get View pero se olvidó sumarlas acá -- el bundle nunca las llevaba,
  # así que tras un deploy quedaban en su default `true` (todas visibles)
  # sin importar lo que el admin hubiera configurado) -- mismo criterio
  # que sincronizar_cargar_todos_por_default/2: es puro flag de
  # presentación, no toca la columna física ni corre migración, seguro
  # sobreescribirlo a ciegas. Todas juntas en una sola función porque son
  # la misma categoría de cambio (nada estructural), a diferencia de
  # separarlos como sincronizar_etiquetas_campos/sincronizar_obligatorio_campos
  # (esos sí son por-campo, con su propia lista de "cuáles cambiaron").
  defp sincronizar_columnas_estructurales(header, contexto) do
    campos = [
      {:mostrar_id_en_tabla, "mostrar_id_en_tabla", "ID"},
      {:mostrar_estado_en_tabla, "mostrar_estado_en_tabla", "Estado"},
      {:mostrar_trn_en_tabla, "mostrar_trn_en_tabla", "TRN"},
      {:mostrar_empresa_en_tabla, "mostrar_empresa_en_tabla", "Empresa"},
      {:mostrar_branch_en_tabla, "mostrar_branch_en_tabla", "Sucursal"},
      {:mostrar_inventory_location_en_tabla, "mostrar_inventory_location_en_tabla", "Almacén"},
      {:mostrar_sales_unit_en_tabla, "mostrar_sales_unit_en_tabla", "Unidad de venta"}
    ]

    # OJO: nunca "valor = Map.get(...)" como cláusula de un for -- Elixir
    # trata cualquier cláusula que no sea un generador como FILTRO por
    # veracidad, y estos valores son booleanos legítimamente `false` --
    # esa forma descartaba la iteración entera en silencio apenas el
    # nuevo valor fuera `false` (encontrado real, probado en vivo).
    cambios =
      campos
      |> Enum.map(fn {campo_atom, campo_json, etiqueta} -> {campo_atom, campo_json, etiqueta, Map.get(contexto, campo_json)} end)
      |> Enum.reject(fn {_atom, _json, _etiqueta, valor_nuevo} -> is_nil(valor_nuevo) end)
      |> Enum.filter(fn {campo_atom, _json, _etiqueta, valor_nuevo} -> Map.get(header, campo_atom) != valor_nuevo end)
      |> Enum.map(fn {_atom, campo_json, etiqueta, valor_nuevo} -> {campo_json, etiqueta, valor_nuevo} end)

    if cambios == [] do
      []
    else
      attrs = Map.new(cambios, fn {campo_json, _etiqueta, valor} -> {campo_json, valor} end)

      case MetaSchemaContext.actualizar_header(header, attrs) do
        {:ok, _header} ->
          Enum.map(cambios, fn {_campo_json, etiqueta, _valor} -> etiqueta end)

        {:error, changeset} ->
          raise "Error sincronizando columnas estructurales de #{header.schema_context_name}: #{inspect(changeset.errors)}"
      end
    end
  end

  # TRN (schema_es_transaccional + codigo_trn) -- bug real encontrado en
  # pty_gasto_diario y corregido ahí a mano vía migración porque el bundle
  # nunca los traía. A diferencia de los demás sync, nunca se "apaga": no
  # hay UI para desmarcar un catálogo como transaccional, y si el destino
  # ya tiene filas con trn/ulid asignado, revertir sería destructivo. Sólo
  # activa (false/nil -> true), nunca al revés.
  defp sincronizar_transaccional(%{schema_es_transaccional: true}, _es_transaccional_nuevo, _codigo_nuevo),
    do: false

  defp sincronizar_transaccional(_header, es_transaccional_nuevo, _codigo_nuevo)
       when es_transaccional_nuevo != true,
       do: false

  defp sincronizar_transaccional(header, true, codigo_nuevo) do
    case MetaSchemaContext.actualizar_header(header, %{
           "schema_es_transaccional" => true,
           "codigo_trn" => codigo_nuevo
         }) do
      {:ok, _header} ->
        true

      {:error, changeset} ->
        raise "Error sincronizando TRN de #{header.schema_context_name}: #{inspect(changeset.errors)}"
    end
  end

  # La tabla física de un campo agregado a un catálogo YA desplegado se
  # actualiza sola (la migración ADD COLUMN que arma
  # CatalogoGenerador.asegurar_campos_nuevos/1 viaja en el bundle igual que
  # cualquier otra migración, y bin/migrate la corre). Lo que faltaba era
  # esto: la metadata (meta_schema_detail) de un header que YA existe nunca
  # se actualizaba -- importar_contexto/1 solo sabía "crear todo" o "no
  # tocar nada". Sin esto, el campo nuevo funcionaba a nivel de API (el
  # schema Ecto compilado ya lo tiene) pero nunca aparecía en meta_campos,
  # así que Frontend no se enteraba de que existe. Mismo criterio que
  # CatalogoGenerador.asegurar_campos_nuevos/1 usa en local, aplicado acá
  # a la metadata en vez de a la columna física.
  defp sincronizar_detalles_nuevos(header, detalles_json) do
    existentes =
      header.schema_context_name
      |> MetaSchemaContext.listar_detalles()
      |> MapSet.new(& &1.schema_context_field)

    detalles_json
    |> Enum.reject(&MapSet.member?(existentes, &1["schema_context_field"]))
    |> Enum.map(fn detalle_attrs ->
      case MetaSchemaContext.agregar_detalle(header, detalle_attrs) do
        {:ok, detalle} ->
          detalle.schema_context_field

        {:error, changeset} ->
          raise "Error sincronizando campo \"#{detalle_attrs["schema_context_field"]}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
      end
    end)
  end

  # Etiqueta de un campo YA existente (2026-08-04, a pedido explícito) —
  # mismo criterio que sincronizar_icono/2: texto de presentación, sin
  # riesgo estructural. A propósito NO se generaliza a "sincronizar
  # cualquier propiedad" — tipo/longitud/catalogo (el destino de una
  # referencia) sí son estructurales, sobreescribirlos a ciegas podría
  # fallar un ALTER COLUMN o cambiar a qué apunta una FK ya usada por
  # datos reales en el destino. Solo toca campos que YA EXISTÍAN — uno
  # nuevo ya trae su etiqueta correcta desde sincronizar_detalles_nuevos/2.
  defp sincronizar_etiquetas_campos(header, detalles_json) do
    existentes =
      header.schema_context_name
      |> MetaSchemaContext.listar_detalles()
      |> Map.new(&{&1.schema_context_field, &1})

    detalles_json
    |> Enum.filter(&Map.has_key?(existentes, &1["schema_context_field"]))
    |> Enum.flat_map(fn detalle_json ->
      detalle = Map.fetch!(existentes, detalle_json["schema_context_field"])
      etiqueta_nueva = get_in(detalle_json, ["schema_context_properties", "etiqueta"])
      etiqueta_actual = get_in(detalle.schema_context_properties, ["etiqueta"])

      if etiqueta_nueva not in [nil, ""] and etiqueta_nueva != etiqueta_actual do
        props = Map.put(detalle.schema_context_properties, "etiqueta", etiqueta_nueva)

        case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
          {:ok, _detalle} ->
            [detalle.schema_context_field]

          {:error, changeset} ->
            raise "Error sincronizando etiqueta de \"#{detalle.schema_context_field}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
        end
      else
        []
      end
    end)
  end

  # "Obligatorio" (guardado como "opcional" en la metadata, ver
  # BcMotorLive.cambiar_obligatorio_campo/2) + "valor default forzoso" de
  # un campo YA existente (2026-08-05, a pedido explícito) — mismo
  # criterio que sincronizar_etiquetas_campos/2: es enforcement de nivel
  # APP nada más (validate_required del schema regenerado), nunca toca la
  # columna física ni corre ALTER COLUMN, así que sincronizarlo a ciegas
  # es seguro. El schema .ex bundleado ya sale regenerado con el valor
  # correcto desde "mix gen.catalogos" (parte de motor.publicar, corre
  # ANTES de armar el bundle) — esto solo mantiene meta_schema_detail (la
  # metadata, no el código ya compilado) al día con lo que se publicó.
  defp sincronizar_obligatorio_campos(header, detalles_json) do
    existentes =
      header.schema_context_name
      |> MetaSchemaContext.listar_detalles()
      |> Map.new(&{&1.schema_context_field, &1})

    detalles_json
    |> Enum.filter(&Map.has_key?(existentes, &1["schema_context_field"]))
    |> Enum.flat_map(fn detalle_json ->
      detalle = Map.fetch!(existentes, detalle_json["schema_context_field"])
      opcional_nuevo = get_in(detalle_json, ["schema_context_properties", "opcional"])
      valor_default_nuevo = get_in(detalle_json, ["schema_context_properties", "valor_default"])
      opcional_actual = get_in(detalle.schema_context_properties, ["opcional"])
      valor_default_actual = get_in(detalle.schema_context_properties, ["valor_default"])

      if opcional_nuevo != opcional_actual or valor_default_nuevo != valor_default_actual do
        props =
          detalle.schema_context_properties
          |> Map.put("opcional", opcional_nuevo == true)
          |> Map.put("valor_default", valor_default_nuevo)

        case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
          {:ok, _detalle} ->
            [detalle.schema_context_field]

          {:error, changeset} ->
            raise "Error sincronizando obligatoriedad de \"#{detalle.schema_context_field}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
        end
      else
        []
      end
    end)
  end

  # "Parámetros y Totales" (SPEC-SYS-0209202601, commit 426347b): es_parametro/
  # defaults/acotado/agregacion_activa/total_general_activo/total_pagina_activo
  # de un campo YA existente nunca se sincronizaban -- mismo bug que ya se
  # corrigió para columnas estructurales/ícono: republicar un catálogo que ya
  # estaba en producción, agregando estas propiedades a un campo viejo, las
  # dejaba mudas en meta_schema_detail (Frontend seguía viendo la config
  # vieja aunque el deploy "pasara bien"). Mismo criterio que
  # sincronizar_columnas_estructurales/2: son flags de presentación/
  # comportamiento del Get/UI, nunca tocan la columna física, seguro
  # sobreescribirlos a ciegas con lo que traiga el bundle. Usa Map.has_key?
  # en vez de comparar contra nil -- son booleanos legítimamente `false`
  # (mismo gotcha ya documentado arriba en columnas estructurales).
  @propiedades_parametros_totales ~w(acotado agregacion_activa defaults es_parametro total_general_activo total_pagina_activo)

  defp sincronizar_parametros_y_totales(header, detalles_json) do
    existentes =
      header.schema_context_name
      |> MetaSchemaContext.listar_detalles()
      |> Map.new(&{&1.schema_context_field, &1})

    detalles_json
    |> Enum.filter(&Map.has_key?(existentes, &1["schema_context_field"]))
    |> Enum.flat_map(fn detalle_json ->
      detalle = Map.fetch!(existentes, detalle_json["schema_context_field"])
      props_nuevas = detalle_json["schema_context_properties"] || %{}

      cambios =
        @propiedades_parametros_totales
        |> Enum.filter(&Map.has_key?(props_nuevas, &1))
        |> Enum.filter(&(Map.get(props_nuevas, &1) != Map.get(detalle.schema_context_properties, &1)))

      if cambios == [] do
        []
      else
        props =
          Enum.reduce(cambios, detalle.schema_context_properties, fn campo, acc ->
            Map.put(acc, campo, Map.get(props_nuevas, campo))
          end)

        case MetaSchemaContext.actualizar_detalle(detalle, %{"schema_context_properties" => props}) do
          {:ok, _detalle} ->
            [detalle.schema_context_field]

          {:error, changeset} ->
            raise "Error sincronizando parámetros/totales de \"#{detalle.schema_context_field}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
        end
      end
    end)
  end

  defp resolver_encabezado(%{"schema_encabezado_catalogo" => nombre_maestro} = contexto)
       when not is_nil(nombre_maestro) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre_maestro) do
      nil -> {:error, "su maestro \"#{nombre_maestro}\" no existe -- ¿faltó incluirlo en el bundle?"}
      maestro -> {:ok, Map.put(contexto, "schema_encabezado_id", maestro.id)}
    end
  end

  defp resolver_encabezado(contexto), do: {:ok, contexto}

  @doc "Importa cada `*.motor.json` de `dir` — recrea estados/transiciones resolviendo toda referencia por NOMBRE, no por id. Idempotente."
  def importar_motor(dir \\ "priv/repo/catalogos") do
    dir
    |> leer_json(".motor.json")
    |> Enum.flat_map(&importar_catalogo_motor/1)
  end

  defp importar_catalogo_motor(%{"catalogo" => nombre} = datos) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      nil ->
        ["- #{nombre}: catálogo no encontrado, saltado (¿faltó importar_meta antes?)"]

      header ->
        {estados_por_nombre, mensajes_estados} = importar_estados(header, datos["estados"] || [])
        mensajes_transiciones = importar_transiciones(header, datos["transiciones"] || [], estados_por_nombre)
        mensajes_estados ++ mensajes_transiciones
    end
  end

  defp importar_estados(header, lista) do
    existentes = header.id |> MetaEstadosAdmin.listar_estados() |> Map.new(&{&1.nombre, &1})

    Enum.reduce(lista, {existentes, []}, fn attrs, {acc, mensajes} ->
      nombre = attrs["nombre"]

      if Map.has_key?(acc, nombre) do
        {acc, mensajes ++ ["= #{header.schema_context_name} estado \"#{nombre}\": ya existía"]}
      else
        atributos = %{
          "meta_schema_header_id" => header.id,
          "nombre" => nombre,
          "orden" => attrs["orden"],
          "es_inicial" => attrs["es_inicial"] || false,
          "color" => attrs["color"],
          "icono" => attrs["icono"],
          "empresa_id" => attrs["empresa_id"]
        }

        case MetaEstadosAdmin.crear_estado_importado(atributos) do
          {:ok, estado} ->
            {Map.put(acc, nombre, estado), mensajes ++ ["+ #{header.schema_context_name} estado \"#{nombre}\": creado"]}

          {:error, changeset} ->
            raise "Error importando estado \"#{nombre}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
        end
      end
    end)
  end

  defp importar_transiciones(header, lista, estados_por_nombre) do
    {_acc, mensajes} =
      Enum.reduce(lista, {MetaEstadosAdmin.listar_transiciones(header.id), []}, fn attrs, {acc, mensajes} ->
        origen_id = resolver_estado_id(attrs["estado_origen"], estados_por_nombre)
        destino_id = resolver_estado_id(attrs["estado_destino"], estados_por_nombre)

        case Enum.find(acc, &(&1.accion == attrs["accion"] and &1.estado_origen_id == origen_id)) do
          nil ->
            crear_transicion(header, attrs, origen_id, destino_id, acc, mensajes)

          transicion ->
            actualizar_transicion_si_cambio(header, transicion, attrs, destino_id, acc, mensajes)
        end
      end)

    mensajes
  end

  # A diferencia de importar_estados/2 (que deja el estado existente
  # intacto), acá SÍ conviene actualizar si cambió: campos_editables/
  # estado_destino son configuración (no hay pérdida de datos al
  # pisarlos, a diferencia de borrar un campo de meta_schema_detail) --
  # sin esto, "más validaciones en el autómata" sobre una transición que
  # ya existe por nombre nunca se propagaba al reimportar (ver
  # docs/roadmap.md #14).
  defp actualizar_transicion_si_cambio(header, transicion, attrs, destino_id, acc, mensajes) do
    campos_editables_nuevos = attrs["campos_editables"] || []

    if transicion.estado_destino_id == destino_id and transicion.campos_editables == campos_editables_nuevos and
         transicion.etiqueta == attrs["etiqueta"] do
      {acc, mensajes ++ ["= #{header.schema_context_name} transición \"#{attrs["accion"]}\": ya existía, sin cambios"]}
    else
      cambios = %{
        "etiqueta" => attrs["etiqueta"],
        "estado_destino_id" => destino_id,
        "campos_editables" => campos_editables_nuevos
      }

      case MetaEstadosAdmin.actualizar_transicion(transicion, cambios) do
        {:ok, actualizada} ->
          {reemplazar(acc, transicion, actualizada), mensajes ++ ["~ #{header.schema_context_name} transición \"#{attrs["accion"]}\": actualizada"]}

        {:error, changeset} ->
          raise "Error actualizando transición \"#{attrs["accion"]}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
      end
    end
  end

  defp reemplazar(lista, viejo, nuevo) do
    Enum.map(lista, fn t -> if t.id == viejo.id, do: nuevo, else: t end)
  end

  # Reglas PRE/POST (rediseño 2026-07-21) ya no viajan en el JSON de
  # transiciones — son código por catálogo, ver MetaReglasCodigo. Si el
  # JSON importado es de una versión vieja y todavía trae "reglas" por
  # transición, se ignora a propósito.
  defp crear_transicion(header, attrs, origen_id, destino_id, acumulado, mensajes) do
    atributos = %{
      "meta_schema_header_id" => header.id,
      "accion" => attrs["accion"],
      "etiqueta" => attrs["etiqueta"],
      "estado_origen_id" => origen_id,
      "estado_destino_id" => destino_id,
      "empresa_id" => attrs["empresa_id"],
      "campos_editables" => attrs["campos_editables"] || []
    }

    case MetaEstadosAdmin.crear_transicion(atributos) do
      {:ok, transicion} ->
        {[transicion | acumulado], mensajes ++ ["+ #{header.schema_context_name} transición \"#{attrs["accion"]}\": creada"]}

      {:error, changeset} ->
        raise "Error importando transición \"#{attrs["accion"]}\" de #{header.schema_context_name}: #{inspect(changeset.errors)}"
    end
  end

  defp resolver_estado_id(nil, _estados_por_nombre), do: nil

  defp resolver_estado_id(nombre, estados_por_nombre) do
    case Map.fetch(estados_por_nombre, nombre) do
      {:ok, estado} -> estado.id
      :error -> raise "Estado \"#{nombre}\" no encontrado — ¿faltó en la lista de estados del JSON?"
    end
  end

  # Directorio ausente = cero archivos, no un error (ver mix meta.import) —
  # estado normal de un checkout/release sin ningún BC desplegado todavía.
  defp leer_json(dir, sufijo) do
    nombres = if File.dir?(dir), do: dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, sufijo)), else: []

    nombres
    |> Enum.sort()
    |> Enum.map(&(dir |> Path.join(&1) |> File.read!() |> Jason.decode!()))
  end
end
