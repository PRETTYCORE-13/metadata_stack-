defmodule MetadataApp.SeedMasterdata do
  @moduledoc """
  Lógica reusable de `mix seed.vaciar`/`seed.cargar`/`seed.reset`
  (`SPEC-TEST-1509202601`) — herramienta de developer mode para
  reiniciar y repoblar catálogos `pty_*`/`demo100_*` de prueba. Los
  mix tasks son capas finas de CLI (parseo de args, `Mix.shell()`);
  toda la lógica de negocio vive acá, para poder testearla con
  ExUnit sin pasar por `Mix.Task.run/1`.

  Nunca toca nada que no sea `pty_*`/`demo100_*` — `validar_catalogo/1`
  es el guardrail que lo garantiza, y se llama ANTES de cualquier otra
  cosa en los tres tasks.
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @prefijos_desarrollo ["pty_", "demo100_"]
  @carpeta_fixtures "priv/repo/seed_masterdata"

  @doc """
  `:ok` si `catalogo` empieza con un prefijo de desarrollo
  (`pty_`/`demo100_`); `{:error, mensaje}` para cualquier otro nombre
  — nunca se ejecuta nada de esta herramienta contra una tabla que no
  pase esto, sin excepción (R5).
  """
  def validar_catalogo(catalogo) when is_binary(catalogo) do
    if Enum.any?(@prefijos_desarrollo, &String.starts_with?(catalogo, &1)) do
      :ok
    else
      {:error,
       "\"#{catalogo}\" no es un catálogo de desarrollo (prefijo pty_/demo100_) -- " <>
         "esta herramienta nunca toca otra cosa."}
    end
  end

  @doc """
  Todos los catálogos de desarrollo vivos (`pty_*`/`demo100_*`, header
  sin `delete_guid`) — usado por `--todos` en los tres tasks (R4).

  `schema_context_type == 1` a propósito: excluye carpetas (tipo 2) y
  Consultas (tipo 3) — ninguna de las dos tiene tabla física propia,
  un `TRUNCATE` sobre ellas no tendría sentido (ni objetivo). El
  filtro de prefijo se hace en Elixir con `validar_catalogo/1` (una
  sola fuente de verdad de "qué cuenta como catálogo de desarrollo",
  en vez de repetir el patrón LIKE acá aparte).
  """
  def listar_catalogos_desarrollo do
    from(h in Header,
      where: is_nil(h.delete_guid) and h.schema_context_type == 1,
      order_by: [asc: h.schema_context_name],
      select: h.schema_context_name
    )
    |> Repo.all()
    |> Enum.filter(&(validar_catalogo(&1) == :ok))
  end

  @doc """
  Grafo de dependencias por llave foránea REAL de Postgres entre las
  tablas de `catalogos` — nunca por metadata declarada
  (`MetaSchemaContext.listar_dependientes/1` solo ve un campo
  "referencia" cuyo `catalogo` configurado es EXACTAMENTE el nombre
  del catálogo; un campo "referencia a meta_schema_header" genérico
  -- ej. `documento` en `pty_folio_perfiles`, `tipo_transaccion` en
  `pty_subtipos_transaccion` -- queda invisible ahí pero tiene una FK
  real que SÍ rompe un `TRUNCATE`/`DELETE` sin importar la metadata;
  hallazgo real de esta misma sesión, ver `design.md` §1).

  Devuelve `%{tabla => MapSet.new(tablas_referenciadas)}` con una
  entrada por CADA tabla de `catalogos` (incluidas las que no tienen
  ninguna dependencia, mapeadas a `MapSet.new()`) — `orden_topologico/1`
  espera el grafo completo, no solo los nodos con aristas. Acotado a
  FKs donde AMBOS extremos están dentro de `catalogos`: una FK hacia
  una tabla fuera del conjunto no es problema de esta herramienta,
  esa tabla no se va a tocar.
  """
  def grafo_dependencias(catalogos) when is_list(catalogos) do
    base = Map.new(catalogos, &{&1, MapSet.new()})

    %{rows: filas} =
      Repo.query!(
        """
        SELECT tc.table_name AS dependiente, ccu.table_name AS referenciada
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
        JOIN information_schema.constraint_column_usage ccu
          ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema
        WHERE tc.constraint_type = 'FOREIGN KEY'
          AND tc.table_name = ANY($1)
          AND ccu.table_name = ANY($1)
          AND tc.table_name <> ccu.table_name
        """,
        [catalogos]
      )

    Enum.reduce(filas, base, fn [dependiente, referenciada], grafo ->
      Map.update(grafo, dependiente, MapSet.new([referenciada]), &MapSet.put(&1, referenciada))
    end)
  end

  @doc """
  Orden topológico (Kahn) del grafo de `grafo_dependencias/1`, en el
  sentido pedido:

  - `:carga` — dependencias primero: si A referencia a B, B sale
    antes que A (R12 — un catálogo referenciado existe antes de que
    lo referencien).
  - `:borrado` — el inverso exacto: A (quien referencia) antes que B
    (a quien referencian) (R2 — nunca se vacía una tabla todavía
    referenciada por otra que no se vació).

  `{:error, :ciclo, [tablas_involucradas]}` si el grafo no es
  acíclico — no hay una respuesta automática correcta a un ciclo real
  de FKs, se reporta para que el developer lo resuelva a mano.
  """
  def orden_topologico(grafo, sentido) when sentido in [:carga, :borrado] do
    # "contador[nodo]" = cuántos OTROS nodos del conjunto todavía lo
    # referencian (cuántas veces aparece en el grafo[X] de otro X).
    # Un nodo con contador 0 significa "ya nadie pendiente lo
    # referencia" -- seguro para BORRAR ya. Kahn sacando primero los
    # de contador 0 produce, tal cual, el orden de :borrado (quien
    # referencia sale antes que a quien referencia). Para :carga
    # (dependencias primero) alcanza con invertir ese resultado --
    # más simple que invertir las aristas y repetir el algoritmo.
    contador =
      Enum.reduce(grafo, Map.new(grafo, fn {nodo, _} -> {nodo, 0} end), fn {_nodo, referenciadas}, contador ->
        Enum.reduce(referenciadas, contador, fn referenciada, contador -> Map.update(contador, referenciada, 1, &(&1 + 1)) end)
      end)

    resultado = kahn(grafo, contador, [])

    case resultado do
      {:ok, orden_borrado} ->
        case sentido do
          :borrado -> {:ok, orden_borrado}
          :carga -> {:ok, Enum.reverse(orden_borrado)}
        end

      {:error, :ciclo, contador_final} ->
        # Lo que Kahn no pudo sacar de la cola (contador > 0 al
        # atascarse) es justo el subconjunto en el ciclo (o dependiente
        # de él) -- más útil para el developer que solo decir "hay un
        # ciclo" a secas.
        restantes = contador_final |> Enum.filter(fn {_n, c} -> c > 0 end) |> Enum.map(&elem(&1, 0))
        {:error, :ciclo, restantes}
    end
  end

  # nodo con contador 0 = nadie (dentro del conjunto) lo referencia
  # todavía sin resolver -- puede salir ya. Al sacarlo, se le resta 1
  # al contador de todo lo que ese nodo referencia (grafo[nodo]).
  defp kahn(grafo, _contador, orden) when map_size(grafo) == length(orden), do: {:ok, Enum.reverse(orden)}

  defp kahn(grafo, contador, orden) do
    case Enum.find(contador, fn {nodo, c} -> c == 0 and nodo not in orden end) do
      nil ->
        {:error, :ciclo, contador}

      {nodo, _} ->
        referenciadas = Map.fetch!(grafo, nodo)
        contador = Enum.reduce(referenciadas, contador, fn referenciada, contador -> Map.update!(contador, referenciada, &(&1 - 1)) end)
        kahn(grafo, contador, [nodo | orden])
    end
  end

  @doc """
  Resuelve un campo tipo "referencia" (`props` = las
  `schema_context_properties` de ESE campo, con `"catalogo"` y
  opcionalmente `"campo_visualizacion"`/`"campos_acompanamiento"`) al
  id de la fila del catálogo destino cuya etiqueta resuelta sea
  exactamente `valor` — el texto natural que el developer escribió en
  el fixture (R11).

  Reusa `CatalogoGenerico.opciones_referencia/1` — la MISMA función
  que arma el picker real de un campo "referencia" en la UI — así el
  texto que hay que escribir en el fixture es EXACTAMENTE el mismo
  que se vería tipeado en el combo real, sin reinventar el formateo
  (`campo_visualizacion` con sus 4 modos, o `campos_acompanamiento`
  como fallback, o `"#id"` como último recurso).

  `{:error, mensaje}` en dos casos:
    - el catálogo destino no tiene NINGUNA fila cuya etiqueta resuelta
      sea igual a `valor` (typo, o el catálogo destino todavía no se
      cargó en esta corrida).
    - el catálogo destino no tiene `campo_visualizacion` NI
      `campos_acompanamiento` configurado -- TODAS sus etiquetas caen
      al fallback `"#id"`, que un fixture nunca puede escribir de
      forma estable entre corridas (R11) -- error proactivo, no
      "no encontrado" a secas.
  """
  def resolver_referencia(props, valor) when is_binary(valor) do
    opciones = CatalogoGenerico.opciones_referencia(props)

    if opciones != [] and Enum.all?(opciones, fn {_id, etiqueta} -> etiqueta_sin_configurar?(etiqueta) end) do
      {:error,
       "\"#{props["catalogo"]}\" no tiene campo_visualizacion ni campos_acompanamiento configurado -- " <>
         "no se puede referenciar por valor natural desde un fixture, configuralo primero en BC Motor (Configuración → el campo \"referencia\" correspondiente)."}
    else
      case Enum.find(opciones, fn {_id, etiqueta} -> etiqueta == valor end) do
        {id, _etiqueta} -> {:ok, id}
        nil -> {:error, "no se encontró \"#{valor}\" en \"#{props["catalogo"]}\" -- ¿ya se cargó ese catálogo en esta corrida?"}
      end
    end
  end

  # Valor no-texto en un campo "referencia" del fixture (ej. un id
  # numérico escrito por error, o `nil` en un campo opcional que el
  # developer dejó explícito en vez de omitirlo) -- mensaje claro en
  # vez de un FunctionClauseError críptico. `nil` pasa derecho (mismo
  # criterio que un campo cualquiera vacío, ver resolver_attrs/2) --
  # el resto se rechaza: R11 prohíbe referenciar por id.
  def resolver_referencia(_props, nil), do: {:ok, nil}

  def resolver_referencia(props, valor) do
    {:error,
     "campo \"#{props["catalogo"]}\" -- el valor de un campo \"referencia\" en el fixture tiene que ser " <>
       "texto (el valor natural del registro destino), nunca un id ni otra cosa: #{inspect(valor)}"}
  end

  defp etiqueta_sin_configurar?(etiqueta), do: Regex.match?(~r/^#\d+$/, etiqueta)

  # --- Fase 2: fixtures y carga atómica (R9-R13) -----------------------------

  @doc "Path del fixture de `catalogo` -- `priv/repo/seed_masterdata/<catalogo>.exs`."
  def ruta_fixture(catalogo), do: Path.join(@carpeta_fixtures, "#{catalogo}.exs")

  @doc "`true` si existe un archivo de fixture para `catalogo` -- usado por `--todos` para filtrar antes de calcular el grafo (solo importan los catálogos que de verdad se van a cargar)."
  def fixture_existe?(catalogo), do: File.exists?(ruta_fixture(catalogo))

  @doc """
  Lee y evalúa el fixture de `catalogo` — `{:ok, [mapa, ...]}` o
  `{:error, mensaje}` si no existe, no evalúa a una lista, o el
  archivo tiene un error de sintaxis/runtime (ej. typo en Elixir
  válido pero que revienta al evaluar).
  """
  def leer_fixture(catalogo) do
    path = ruta_fixture(catalogo)

    if File.exists?(path) do
      case Code.eval_file(path) do
        {lista, _bindings} when is_list(lista) -> {:ok, lista}
        {otro, _bindings} -> {:error, "#{path} no evalúa a una lista (evaluó a #{inspect(otro)})"}
      end
    else
      {:error, "no existe #{path}"}
    end
  rescue
    e -> {:error, "error evaluando #{ruta_fixture(catalogo)}: #{Exception.message(e)}"}
  end

  @doc """
  Carga TODOS los catálogos de `catalogos_en_orden` (ya ordenados —
  ver `orden_topologico/2` `:carga` — dependencias primero) de forma
  ATÓMICA (R13): una única `Repo.transaction/1` para toda la corrida,
  registro por registro, catálogo por catálogo. El primer
  `{:error, _}` (fixture inválido, referencia no resuelta, o
  `CatalogoGenerico.crear/2` rechazado por una regla de negocio)
  dispara `Repo.rollback/1` con el detalle exacto — nada de esa
  corrida sobrevive, sin importar cuánto ya se hubiera creado.

  Cada registro pasa por `CatalogoGenerico.crear/2` con `scope: :sistema`
  (el sentinel de `Autenticacion.Scope` para "código interno sin
  usuario humano", ver `scope.ex`) — el mismo camino real de alta que
  `POST /api/:tabla` (R10): TRN, folio, motor de estados y reglas
  PRE/POST corren igual que para un alta real, `crear/2` resuelve
  sola la transición de alta configurada (`crear_con_attrs_preparados/5`
  en `catalogo_generico.ex`) — este módulo no la vuelve a buscar.

  `{:ok, registros_creados}` (en orden) o `{:error, mensaje}`.
  """
  def cargar(catalogos_en_orden) do
    case armar_trabajos(catalogos_en_orden) do
      {:error, _mensaje} = error ->
        error

      {:ok, trabajos} ->
        Repo.transaction(fn ->
          Enum.reduce(trabajos, [], fn {catalogo, indice, registro}, creados ->
            case crear_uno(catalogo, registro) do
              {:ok, item} -> [item | creados]
              {:error, motivo} -> Repo.rollback("#{catalogo}[#{indice}]: #{formatear_motivo(motivo)}")
            end
          end)
          |> Enum.reverse()
        end)
    end
  end

  # Arma la lista plana de {catalogo, indice, registro} ANTES de abrir
  # la transacción -- un fixture con un error de lectura (sintaxis, no
  # evalúa a lista) se reporta sin haber tocado la base para nada.
  defp armar_trabajos(catalogos_en_orden) do
    Enum.reduce_while(catalogos_en_orden, {:ok, []}, fn catalogo, {:ok, acc} ->
      case leer_fixture(catalogo) do
        {:ok, registros} ->
          nuevos = registros |> Enum.with_index(1) |> Enum.map(fn {r, i} -> {catalogo, i, r} end)
          {:cont, {:ok, acc ++ nuevos}}

        {:error, mensaje} ->
          {:halt, {:error, "fixture de \"#{catalogo}\": #{mensaje}"}}
      end
    end)
  end

  defp crear_uno(catalogo, registro_bruto) do
    schema_mod = MetaSchemaContext.modulo_por_nombre(catalogo)
    detalles = MetaSchemaContext.listar_detalles(catalogo)

    with {:ok, attrs} <- resolver_attrs(detalles, registro_bruto) do
      CatalogoGenerico.crear(schema_mod, :sistema, attrs)
    end
  end

  defp resolver_attrs(detalles, registro_bruto) do
    Enum.reduce_while(registro_bruto, {:ok, %{}}, fn {campo, valor}, {:ok, acc} ->
      case detalle_de_campo(detalles, campo) do
        %{schema_context_properties: %{"tipo" => "referencia"} = props} ->
          case resolver_referencia(props, valor) do
            {:ok, id} -> {:cont, {:ok, Map.put(acc, campo, id)}}
            {:error, mensaje} -> {:halt, {:error, "campo \"#{campo}\": #{mensaje}"}}
          end

        _otro ->
          {:cont, {:ok, Map.put(acc, campo, valor)}}
      end
    end)
  end

  defp detalle_de_campo(detalles, campo), do: Enum.find(detalles, &(&1.schema_context_field == campo))

  defp formatear_motivo(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Enum.map_join("; ", fn {campo, mensajes} -> "#{campo} #{Enum.join(mensajes, ", ")}" end)
  end

  defp formatear_motivo(otro), do: inspect(otro)
end
