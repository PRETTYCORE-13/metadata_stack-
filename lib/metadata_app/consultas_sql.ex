defmodule MetadataApp.ConsultasSql do
  @moduledoc """
  Consulta SQL (`schema_context_type: 4`, SPEC-SYS-2509202601): un BC cuyo
  contenido es un SQL de solo lectura que se convierte en una vista de
  Postgres con el mismo nombre que el Header. Dos usos: "diccionario"
  (alimenta combos de campos referencia) y "consulta" (reporte de solo
  lectura).

  El nombre técnico siempre es `pty_sql_<slug>`: el prefijo `pty_` deja la
  migración de la vista fuera del repo compartido (`.gitignore`) y la mete
  en el paquete de `mix motor.publicar` (comodín `*<catalogo>*.exs` de
  `MetaPublicador`).
  """

  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.Permissions
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.MetaSchema.ConsultaSql
  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerador}

  @tipo 4
  @prefijo "pty_sql_"
  @largo_maximo 50
  @timeout_ms 5_000
  @filas_vista_previa 5
  @vista_validacion "_validacion_sql"
  # Nombre de columna utilizable como átomo (ver diseño §3): se valida al
  # guardar, así el número de átomos queda acotado a columnas reales.
  @formato_columna ~r/^[a-z_][a-z0-9_]{0,62}$/
  @columnas_alcance [
    {"branch_id", :branch_id, :branches_permitidos},
    {"sales_unit_id", :sales_unit_id, :sales_units_permitidas},
    {"inventory_id", :inventory_id, :inventory_locations_permitidas}
  ]

  def tipo, do: @tipo

  @doc """
  Nombre técnico a partir de la navegación (`/carpeta/slug`): cada
  segmento normalizado (minúsculas, sin acentos, solo `[a-z0-9_]`, sin
  empezar con número) y unidos con `_`, con el prefijo `pty_sql_`. `""` si
  la navegación no deja nada utilizable.
  """
  def nombre_desde_nav(nav) do
    sufijo =
      (nav || "")
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> Enum.map(&normalizar_segmento/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("_")

    if sufijo == "", do: "", else: String.slice(@prefijo <> sufijo, 0, @largo_maximo)
  end

  defp normalizar_segmento(valor) do
    valor
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.replace(~r/[^a-z0-9_]/, "")
    |> String.replace(~r/^[^a-z]+/, "")
  end

  @doc """
  Alta de una Consulta SQL: el Header (tipo 4, no visible) y su fila en
  `meta_schema_consulta_sql`, sin SQL todavía (se carga después desde el
  editor). `attrs`: `"etiqueta"`, `"nav"` y `"uso"`. `{:ok, {header,
  consulta_sql}}` o `{:error, mensaje}`.
  """
  def crear(attrs) do
    etiqueta = String.trim(attrs["etiqueta"] || "")
    nav = attrs["nav"] || ""
    nombre = nombre_desde_nav(nav)
    uso = attrs["uso"] || "diccionario"

    cond do
      etiqueta == "" or nombre == "" ->
        {:error, "Completa la etiqueta y la navegación antes de guardar."}

      uso not in ConsultaSql.usos() ->
        {:error, "El uso tiene que ser Diccionario o Consulta."}

      MetaSchemaContext.obtener_header_por_nav(nav) ->
        {:error, "Esa ruta ya la usa otro catálogo o carpeta."}

      MetaSchemaContext.obtener_header_por_nombre(nombre) ->
        {:error, "Ya existe un catálogo con el nombre técnico #{nombre}."}

      true ->
        insertar(%{
          "schema_context_name" => nombre,
          "schema_context_label" => etiqueta,
          "schema_context_nav" => nav,
          "schema_visible" => false,
          "schema_context_type" => @tipo,
          "detalles" => []
        }, uso)
    end
  end

  defp insertar(header_attrs, uso) do
    Repo.transaction(fn ->
      with {:ok, {header, _detalles}} <- MetaSchemaContext.crear_header_con_detalles(header_attrs),
           {:ok, consulta_sql} <-
             %ConsultaSql{}
             |> ConsultaSql.changeset(%{"meta_schema_header_id" => header.id, "uso" => uso})
             |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
             |> Repo.insert(),
           # Solo lectura (R22): su único permiso es "leer". Registrarlo
           # acá lo deja disponible para conceder en Roles; sin la fila, ni
           # el administrador lo ve (SPEC-SYS-2209202601).
           {:ok, _permiso} <- asegurar_permiso_leer(header.schema_context_name) do
        {header, consulta_sql}
      else
        {:error, %Ecto.Changeset{} = changeset} -> Repo.rollback(resumen_errores(changeset))
        {:error, motivo} -> Repo.rollback(inspect(motivo))
      end
    end)
  end

  defp asegurar_permiso_leer(nombre) do
    if Permissions.permiso_existe?(nombre, "leer"),
      do: {:ok, :existente},
      else: Permissions.crear_permiso(%{recurso: nombre, accion: "leer"})
  end

  def obtener_por_header_id(header_id) do
    Repo.one(from c in ConsultaSql, where: c.meta_schema_header_id == ^header_id and is_nil(c.delete_guid))
  end

  def obtener_por_catalogo(nombre) do
    case MetaSchemaContext.obtener_header_por_nombre(nombre) do
      %{schema_context_type: @tipo} = header -> obtener_por_header_id(header.id)
      _ -> nil
    end
  end

  # --- Validar y guardar el SQL (R6-R12) -------------------------------------

  @doc """
  Valida `sql` contra Postgres real sin dejar nada: lo convierte en una
  vista temporal dentro de una transacción que siempre se revierte.
  Postgres mismo rechaza varias sentencias (protocolo extendido),
  cualquier cosa que no sea una consulta de lectura, errores de sintaxis
  y tablas/columnas inexistentes; crear la vista no ejecuta el SQL.
  Después aplica las reglas de `uso` (R9, R19) y exige que sigan
  existiendo las columnas de `columnas_en_uso` (R11). `{:ok, columnas}`
  (`[%{"nombre", "tipo_pg", "tipo"}]`) o `{:error, mensaje}`.
  """
  def validar_sql(sql, uso, columnas_en_uso \\ []) do
    sql = limpiar_sql(sql)

    if sql == "" do
      {:error, "Escribe el SQL antes de guardar."}
    else
      with {:ok, columnas} <- columnas_de_sql(sql),
           :ok <- validar_nombres(columnas),
           :ok <- validar_uso(columnas, uso),
           :ok <- validar_columnas_en_uso(columnas, columnas_en_uso) do
        {:ok, columnas}
      end
    end
  end

  defp limpiar_sql(sql), do: (sql || "") |> String.trim() |> String.trim_trailing(";") |> String.trim()

  defp columnas_de_sql(sql) do
    resultado =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL statement_timeout = #{@timeout_ms}", [])

        case Repo.query("CREATE TEMP VIEW #{@vista_validacion} AS " <> sql, []) do
          {:ok, _} -> Repo.rollback({:ok, leer_columnas(@vista_validacion)})
          {:error, error} -> Repo.rollback({:error, mensaje_de_error(error)})
        end
      end)

    case resultado do
      {:error, {:ok, columnas}} -> {:ok, columnas}
      {:error, {:error, mensaje}} -> {:error, mensaje}
      {:error, otro} -> {:error, mensaje_de_error(otro)}
    end
  end

  # `::regclass` resuelve por search_path (incluye pg_temp), así nunca
  # confunde la vista temporal de esta sesión con la de otra conexión.
  defp leer_columnas(relacion) do
    Repo.query!(
      """
      SELECT a.attname, format_type(a.atttypid, a.atttypmod)
      FROM pg_attribute a
      WHERE a.attrelid = $1::text::regclass AND a.attnum > 0 AND NOT a.attisdropped
      ORDER BY a.attnum
      """,
      [relacion]
    ).rows
    |> Enum.map(fn [nombre, tipo_pg] -> %{"nombre" => nombre, "tipo_pg" => tipo_pg, "tipo" => tipo_simple(tipo_pg)} end)
  end

  defp tipo_simple(tipo_pg) do
    cond do
      tipo_pg in ~w(integer bigint smallint) -> "integer"
      String.starts_with?(tipo_pg, "numeric") or tipo_pg in ["real", "double precision"] -> "decimal"
      tipo_pg == "boolean" -> "boolean"
      tipo_pg == "date" -> "date"
      String.starts_with?(tipo_pg, "timestamp") -> "datetime"
      true -> "string"
    end
  end

  defp validar_nombres(columnas) do
    case Enum.find(columnas, &(not Regex.match?(@formato_columna, &1["nombre"]))) do
      nil -> :ok
      c -> {:error, "La columna «#{c["nombre"]}» no tiene un nombre válido: renómbrala con AS usando solo minúsculas, números y guion bajo."}
    end
  end

  defp validar_uso(columnas, "diccionario") do
    cond do
      not Enum.any?(columnas, &(&1["nombre"] == "id" and &1["tipo"] == "integer")) ->
        {:error, "Un Diccionario necesita una columna «id» de tipo entero (el registro que se guarda en el campo)."}

      length(columnas) < 2 ->
        {:error, "Un Diccionario necesita, además de «id», al menos una columna de descripción."}

      true ->
        :ok
    end
  end

  defp validar_uso([], _uso), do: {:error, "El SQL tiene que regresar al menos una columna."}
  defp validar_uso(_columnas, _uso), do: :ok

  defp validar_columnas_en_uso(columnas, en_uso) do
    nombres = MapSet.new(columnas, & &1["nombre"])

    case Enum.reject(en_uso, &MapSet.member?(nombres, &1)) do
      [] -> :ok
      faltantes -> {:error, "El SQL ya no regresa columnas que usan los campos que eligieron este Diccionario: #{Enum.join(faltantes, ", ")}."}
    end
  end

  @doc """
  Columnas del Diccionario `nombre` que usan hoy los campos referencia
  que lo eligieron (`id`, descripción y filtros/cascada con origen
  "diccionario") -- R11: una edición del SQL no puede quitarlas.
  """
  def columnas_en_uso(nombre) do
    nombre
    |> propiedades_de_campos_que_usan()
    |> Enum.flat_map(fn props ->
      dic = props["diccionario"] || %{}
      filtros = for f <- List.wrap(props["filtros_fijos"]), f["origen"] == "diccionario", do: f["campo"]
      deps = for d <- List.wrap(props["dependencias"]), d["origen"] == "diccionario", do: d["campo_remoto"]
      ["id" | List.wrap(dic["descripcion"])] ++ filtros ++ deps
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp propiedades_de_campos_que_usan(nombre) do
    from(d in MetadataApp.BusinessProcessBuilder.MetaSchema.Detail,
      where: is_nil(d.delete_guid) and fragment("?->'diccionario'->>'consulta' = ?", d.schema_context_properties, ^nombre),
      select: d.schema_context_properties
    )
    |> Repo.all()
  end

  @doc """
  Valida `sql`, genera y corre la migración de la vista y guarda la
  definición (R10). En secuencia y no en una sola transacción: correr
  Ecto.Migrator dentro de una transacción es frágil (bug real 2026-09-07,
  ver `BcMotorLive.transaccion_con_generador/2`) y la migración commitea
  por su cuenta de todos modos. Si la migración falla, se borra su
  archivo y no se toca la metadata. Solo donde se permite generar en
  caliente (dev/test), igual que los catálogos.
  """
  def guardar_sql(nombre, sql) do
    with :ok <- permitido_generar(),
         %ConsultaSql{} = consulta_sql <- obtener_por_catalogo(nombre) || {:error, "No existe la Consulta SQL #{nombre}."},
         {:ok, columnas} <- validar_sql(sql, consulta_sql.uso, columnas_en_uso(nombre)),
         :ok <- escribir_y_correr_migracion(nombre, limpiar_sql(sql)) do
      consulta_sql
      |> ConsultaSql.changeset(%{"sql" => limpiar_sql(sql), "columnas" => columnas})
      |> Ecto.Changeset.change(%{update_guid: generar_guid()})
      |> Repo.update()
      |> case do
        {:ok, actualizada} -> {:ok, actualizada}
        {:error, changeset} -> {:error, resumen_errores(changeset)}
      end
    end
  end

  defp permitido_generar do
    if Application.get_env(:metadata_app, :generar_catalogos_en_caliente, false),
      do: :ok,
      else: {:error, "Las Consultas SQL solo se editan en desarrollo y se publican con mix motor.publicar."}
  end

  defp escribir_y_correr_migracion(nombre, sql) do
    if vista_directa?() do
      Repo.query!("DROP VIEW IF EXISTS #{nombre}", [])
      Repo.query!("CREATE VIEW #{nombre} AS " <> sql, [])
      :ok
    else
      escribir_y_correr_archivo(nombre, sql)
    end
  end

  # Solo test (config/test.exs): la vista se crea dentro del sandbox, sin
  # archivo de migración ni Ecto.Migrator.
  defp vista_directa?, do: Application.get_env(:metadata_app, :consultas_sql_vista_directa, false)

  @doc """
  Ruta de la migración de una SQL View. El timestamp va también como
  sufijo del nombre: Ecto exige que el NOMBRE de cada migración (lo que
  sigue a la versión) sea único, y cada guardado del SQL genera una nueva
  (bug real 2026-09-25: el segundo guardado de la misma vista dejó dos
  `*_vista_pty_sql_x.exs` y `Phoenix.Ecto.CheckRepoStatus` tumbaba toda
  pantalla en dev). Mismo patrón que `crear_pty_x_<ts>` de los catálogos.
  """
  def ruta_migracion(accion, nombre, timestamp) when accion in ["vista", "eliminar_vista"],
    do: "priv/repo/migrations/#{timestamp}_#{accion}_#{nombre}_#{timestamp}.exs"

  defp escribir_y_correr_archivo(nombre, sql) do
    timestamp = CatalogoGenerador.timestamp_migracion()
    path = ruta_migracion("vista", nombre, timestamp)
    File.write!(path, contenido_migracion(nombre, sql, timestamp))

    try do
      CatalogoGenerador.correr_migraciones_pendientes()
      :ok
    rescue
      error ->
        File.rm(path)
        {:error, "No se pudo crear la vista: #{mensaje_de_error(error)}"}
    end
  end

  # `inspect/1` deja el SQL como un literal de string de Elixir válido
  # (escapa comillas, barras y `\#{`), así el texto del admin nunca se
  # interpreta como código dentro del archivo generado.
  defp contenido_migracion(nombre, sql, timestamp) do
    modulo = "VistaPtySql" <> Macro.camelize(String.replace_prefix(nombre, @prefijo, "")) <> timestamp

    """
    defmodule MetadataApp.Repo.Migrations.#{modulo} do
      use Ecto.Migration

      # Generada por MetadataApp.ConsultasSql.guardar_sql/2 (SPEC-SYS-2509202601).
      # DROP + CREATE (no CREATE OR REPLACE): este último no permite quitar ni
      # renombrar columnas.
      def up do
        execute "DROP VIEW IF EXISTS #{nombre}"
        execute #{inspect("CREATE VIEW #{nombre} AS " <> sql)}
      end

      def down, do: execute("DROP VIEW IF EXISTS #{nombre}")
    end
    """
  end

  # --- Ejecución segura (R13, R33) ------------------------------------------

  @doc """
  Corre `fun` (que lee de una vista `pty_sql_*`) con tiempo máximo y, si
  no hay una transacción abierta, en una transacción de solo lectura.
  Dentro de una transacción ya abierta (ej. la validación de un campo al
  guardar un registro) `SET TRANSACTION READ ONLY` no se puede, así que
  solo aplica el tiempo máximo y lo restaura al terminar. `{:ok,
  resultado}`, `{:error, :tiempo_excedido}` o `{:error, mensaje}`.
  """
  def ejecutar(fun) do
    if Repo.in_transaction?(), do: ejecutar_anidado(fun), else: ejecutar_solo_lectura(fun)
  end

  defp ejecutar_solo_lectura(fun) do
    Repo.transaction(fn ->
      Repo.query!("SET TRANSACTION READ ONLY", [])
      Repo.query!("SET LOCAL statement_timeout = #{@timeout_ms}", [])
      fun.()
    end)
  rescue
    error -> error_de_ejecucion(error)
  end

  defp ejecutar_anidado(fun) do
    [[anterior]] = Repo.query!("SHOW statement_timeout", []).rows
    Repo.query!("SET LOCAL statement_timeout = #{@timeout_ms}", [])

    try do
      {:ok, fun.()}
    rescue
      error -> error_de_ejecucion(error)
    after
      Repo.query("SET LOCAL statement_timeout = '#{anterior}'", [])
    end
  end

  defp error_de_ejecucion(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: {:error, :tiempo_excedido}
  defp error_de_ejecucion(error), do: {:error, mensaje_de_error(error)}

  @doc "Mensaje para pantalla de `{:error, motivo}` de `ejecutar/1`."
  def mensaje_ejecucion(:tiempo_excedido), do: "La consulta tardó más de #{div(@timeout_ms, 1000)} segundos y se canceló."
  def mensaje_ejecucion(mensaje) when is_binary(mensaje), do: mensaje

  @doc "Primeras 5 filas de la vista (R12), con la ejecución segura."
  def vista_previa(nombre) do
    vista = identificador!(nombre)

    ejecutar(fn -> Repo.query!("SELECT * FROM #{vista} LIMIT #{@filas_vista_previa}", []) end)
    |> case do
      {:ok, %{columns: columnas, rows: filas}} -> {:ok, %{columnas: columnas, filas: filas}}
      error -> error
    end
  end

  @doc """
  Átomo de una columna de la vista, para `field/2` de Ecto. Solo acepta
  nombres con el formato validado al guardar el SQL (`@formato_columna`),
  y en la práctica solo recibe nombres ya registrados en `columnas`: el
  número de átomos queda acotado a las columnas reales de las Consultas
  SQL. `String.to_atom/1` y no `to_existing_atom/1`, porque el átomo no
  sobrevive a un reinicio de la aplicación.
  """
  def atomo_columna(nombre) do
    if Regex.match?(@formato_columna, nombre),
      do: String.to_atom(nombre),
      else: raise(ArgumentError, "nombre de columna inválido: #{inspect(nombre)}")
  end

  # Solo nombres generados por nombre_desde_nav/1 llegan a un SQL armado
  # por la plataforma.
  defp identificador!(nombre) do
    if Regex.match?(~r/^pty_sql_[a-z0-9_]+$/, nombre), do: nombre, else: raise(ArgumentError, "nombre de vista inválido: #{inspect(nombre)}")
  end

  # --- Alcance de datos por columnas (R20, diseño §4) -----------------------

  @doc """
  Acota `query` (sobre la vista, binding `v`) por cada columna de control
  que exponga el SQL (`branch_id`, `sales_unit_id`, `inventory_id`) con
  las listas del `Scope`. Filas con esa columna en `NULL` quedan visibles
  (misma convención que `CatalogoGenerico`). El administrador no se acota
  (en los catálogos `alcance_tipo_efectivo/2` le da `:global`; sus listas
  son asignaciones explícitas y podrían venir vacías). Sin sesión: cero
  filas.
  """
  def alcance_por_columnas(query, nil, _columnas), do: from(v in query, where: false)

  def alcance_por_columnas(query, %Scope{} = scope, columnas) do
    if administrador?(scope) do
      query
    else
      nombres = MapSet.new(columnas, & &1["nombre"])

      Enum.reduce(@columnas_alcance, query, fn {columna, campo, lista}, acc ->
        if MapSet.member?(nombres, columna) do
          permitidos = Map.fetch!(scope, lista)
          from(v in acc, where: is_nil(field(v, ^campo)) or field(v, ^campo) in ^permitidos)
        else
          acc
        end
      end)
    end
  end

  @doc "Columnas de control de alcance que expone el SQL (para el aviso de R20)."
  def columnas_de_alcance(columnas) do
    nombres = MapSet.new(columnas, & &1["nombre"])
    for {columna, _campo, _lista} <- @columnas_alcance, MapSet.member?(nombres, columna), do: columna
  end

  defp administrador?(%Scope{usuario: %{id: usuario_id}, empresa_activa: %{id: empresa_id}}),
    do: Permissions.administrador?(usuario_id, empresa_id)

  defp administrador?(_scope), do: false

  # --- Quién usa el Diccionario y BC autorizados (R14-R18, R4, R30) --------

  @doc """
  Campos referencia que eligieron el Diccionario `nombre`:
  `[%{catalogo:, etiqueta_catalogo:, campo:, etiqueta:}]`, ordenados por
  catálogo. Una sola consulta JSONB sobre `meta_schema_detail`.
  """
  def campos_que_usan(nombre) do
    from(d in MetadataApp.BusinessProcessBuilder.MetaSchema.Detail,
      join: h in assoc(d, :header),
      where:
        is_nil(d.delete_guid) and is_nil(h.delete_guid) and
          fragment("?->'diccionario'->>'consulta' = ?", d.schema_context_properties, ^nombre),
      order_by: [h.schema_context_name, d.schema_context_field],
      select: %{
        catalogo: h.schema_context_name,
        etiqueta_catalogo: h.schema_context_label,
        campo: d.schema_context_field,
        etiqueta: fragment("?->>'etiqueta'", d.schema_context_properties)
      }
    )
    |> Repo.all()
  end

  @doc "Texto legible de `campos_que_usan/1` para mensajes de rechazo."
  def describir_usos(usos), do: Enum.map_join(usos, ", ", &"#{&1.etiqueta_catalogo} → #{&1.etiqueta || &1.campo}")

  @doc "Autoriza al catálogo `bc` (tipo 1) a usar el Diccionario `nombre` (R14)."
  def autorizar_bc(nombre, bc) do
    with %ConsultaSql{} = consulta_sql <- obtener_por_catalogo(nombre) || {:error, "No existe la Consulta SQL #{nombre}."},
         %{schema_context_type: 1} <- MetaSchemaContext.obtener_header_por_nombre(bc) || {:error, "El BC #{bc} no existe."} do
      actualizar_autorizados(consulta_sql, Enum.uniq(consulta_sql.bcs_autorizados ++ [bc]))
    else
      %{} -> {:error, "Solo se pueden autorizar catálogos (BC de negocio)."}
      error -> error
    end
  end

  @doc "Quita al catálogo `bc` de los autorizados, salvo que tenga campos usando el Diccionario (R17)."
  def desautorizar_bc(nombre, bc) do
    with %ConsultaSql{} = consulta_sql <- obtener_por_catalogo(nombre) || {:error, "No existe la Consulta SQL #{nombre}."} do
      case Enum.filter(campos_que_usan(nombre), &(&1.catalogo == bc)) do
        [] -> actualizar_autorizados(consulta_sql, List.delete(consulta_sql.bcs_autorizados, bc))
        usos -> {:error, "No se puede quitar: estos campos usan el Diccionario: #{describir_usos(usos)}."}
      end
    end
  end

  defp actualizar_autorizados(consulta_sql, lista) do
    consulta_sql
    |> ConsultaSql.changeset(%{"bcs_autorizados" => lista})
    |> Ecto.Changeset.change(%{update_guid: generar_guid()})
    |> Repo.update()
    |> case do
      {:ok, c} -> {:ok, c}
      {:error, changeset} -> {:error, resumen_errores(changeset)}
    end
  end

  @doc """
  R4: un Diccionario en uso no puede pasar a Consulta ni volverse visible
  (los campos lo perderían: solo los no visibles se ofrecen en Filtros).
  `:ok` o `{:error, mensaje}`.
  """
  def validar_cambio(nombre, nuevo_uso, nuevo_visible) do
    consulta_sql = obtener_por_catalogo(nombre)

    cambia? = consulta_sql && consulta_sql.uso == "diccionario" and (nuevo_uso == "consulta" or nuevo_visible == true)

    case cambia? && campos_que_usan(nombre) do
      usos when is_list(usos) and usos != [] ->
        {:error, "Este Diccionario lo usan campos (#{describir_usos(usos)}): no puede cambiar a Consulta ni volverse visible."}

      _ ->
        :ok
    end
  end

  @doc "Cambia el uso (R2), con la regla de R4."
  def cambiar_uso(nombre, uso) do
    header = MetaSchemaContext.obtener_header_por_nombre(nombre)

    with %ConsultaSql{} = consulta_sql <- obtener_por_catalogo(nombre) || {:error, "No existe la Consulta SQL #{nombre}."},
         :ok <- validar_cambio(nombre, uso, header.schema_visible),
         :ok <- validar_uso_con_columnas(consulta_sql, uso) do
      consulta_sql
      |> ConsultaSql.changeset(%{"uso" => uso})
      |> Ecto.Changeset.change(%{update_guid: generar_guid()})
      |> Repo.update()
      |> case do
        {:ok, c} -> {:ok, c}
        {:error, changeset} -> {:error, resumen_errores(changeset)}
      end
    end
  end

  # Pasar a Diccionario con un SQL ya guardado exige que ese SQL cumpla R9.
  defp validar_uso_con_columnas(%ConsultaSql{sql: nil}, _uso), do: :ok
  defp validar_uso_con_columnas(%ConsultaSql{columnas: columnas}, uso), do: validar_uso(columnas, uso)

  @doc """
  Elimina la Consulta SQL (R30): rechaza si algún campo la usa; si no,
  genera y corre la migración que quita la vista, y borra su fila y su
  encabezado.
  """
  def eliminar(nombre) do
    with :ok <- permitido_generar(),
         %ConsultaSql{} = consulta_sql <- obtener_por_catalogo(nombre) || {:error, "No existe la Consulta SQL #{nombre}."},
         [] <- campos_que_usan(nombre) do
      with :ok <- escribir_y_correr_migracion_baja(nombre) do
        header = MetaSchemaContext.obtener_header_por_nombre(nombre)

        Repo.transaction(fn ->
          Repo.delete!(consulta_sql)

          case MetaSchemaContext.eliminar_header(header) do
            :ok -> :ok
            {:error, motivo} -> Repo.rollback(motivo)
          end
        end)
        |> case do
          {:ok, :ok} -> :ok
          {:error, motivo} -> {:error, if(is_binary(motivo), do: motivo, else: inspect(motivo))}
        end
      end
    else
      usos when is_list(usos) -> {:error, "No se puede eliminar: estos campos usan el Diccionario: #{describir_usos(usos)}."}
      error -> error
    end
  end

  defp escribir_y_correr_migracion_baja(nombre) do
    if vista_directa?() do
      Repo.query!("DROP VIEW IF EXISTS #{nombre}", [])
      :ok
    else
      escribir_y_correr_archivo_baja(nombre)
    end
  end

  defp escribir_y_correr_archivo_baja(nombre) do
    timestamp = CatalogoGenerador.timestamp_migracion()
    path = ruta_migracion("eliminar_vista", nombre, timestamp)
    modulo = "EliminarVistaPtySql" <> Macro.camelize(String.replace_prefix(nombre, @prefijo, "")) <> timestamp

    File.write!(path, """
    defmodule MetadataApp.Repo.Migrations.#{modulo} do
      use Ecto.Migration

      # Generada por MetadataApp.ConsultasSql.eliminar/1 (SPEC-SYS-2509202601).
      def change, do: execute("DROP VIEW IF EXISTS #{nombre}", "SELECT 1")
    end
    """)

    try do
      CatalogoGenerador.correr_migraciones_pendientes()
      :ok
    rescue
      error ->
        File.rm(path)
        {:error, "No se pudo quitar la vista: #{mensaje_de_error(error)}"}
    end
  end

  # --- Publicación (R31-R32) ------------------------------------------------

  @doc "Bloque `%{consulta_sql: ...}` para el .meta.json de un header tipo 4; `%{}` para cualquier otro."
  def exportar_definicion(%{schema_context_type: @tipo, id: header_id}) do
    case obtener_por_header_id(header_id) do
      nil ->
        %{}

      c ->
        %{consulta_sql: %{uso: c.uso, sql: c.sql, columnas: c.columnas, bcs_autorizados: c.bcs_autorizados}}
    end
  end

  def exportar_definicion(_header), do: %{}

  @doc """
  Crea o sincroniza la definición de la SQL View `nombre` (header ya
  importado) con el bloque `datos` del bundle. No crea la vista: eso lo hace
  su migración. `:creada`, `:actualizada` o `:sin_cambios`.
  """
  def importar_definicion(nombre, datos) do
    header = MetaSchemaContext.obtener_header_por_nombre(nombre)

    attrs = %{
      "uso" => datos["uso"] || "diccionario",
      "sql" => datos["sql"],
      "columnas" => datos["columnas"] || [],
      "bcs_autorizados" => datos["bcs_autorizados"] || []
    }

    case obtener_por_header_id(header.id) do
      nil ->
        %ConsultaSql{}
        |> ConsultaSql.changeset(Map.put(attrs, "meta_schema_header_id", header.id))
        |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
        |> Repo.insert!()

        asegurar_permiso_leer(nombre)
        :creada

      actual ->
        changeset = ConsultaSql.changeset(actual, attrs)

        if changeset.changes == %{} do
          :sin_cambios
        else
          changeset |> Ecto.Changeset.change(%{update_guid: generar_guid()}) |> Repo.update!()
          :actualizada
        end
    end
  end

  @doc """
  Catálogos de negocio que usa el SQL de la SQL View `nombre` (vía
  `pg_depend`), para meterlos en el paquete de publicación (R32).
  """
  def catalogos_que_usa(nombre) do
    tablas =
      Repo.query!(
        """
        SELECT DISTINCT t.relname
        FROM pg_depend d
        JOIN pg_rewrite r ON r.oid = d.objid
        JOIN pg_class v ON v.oid = r.ev_class
        JOIN pg_class t ON t.oid = d.refobjid
        WHERE v.relname = $1 AND t.relname <> $1 AND t.relkind IN ('r', 'v', 'p')
        """,
        [nombre]
      ).rows
      |> List.flatten()

    from(h in MetadataApp.BusinessProcessBuilder.MetaSchema.Header,
      where: h.schema_context_name in ^tablas and is_nil(h.delete_guid) and h.schema_context_type in [1, 4],
      select: h.schema_context_name
    )
    |> Repo.all()
  end

  # --- Dependencias con catálogos (R29) -------------------------------------

  @doc """
  SQL View (`pty_sql_*`) que usan la tabla `tabla` o, si se pasa `columna`,
  esa columna puntual. Postgres ya bloquea el DROP con un error técnico;
  esto permite rechazar antes con un mensaje que nombre la SQL View.
  `[%{nombre:, etiqueta:}]`.
  """
  def vistas_que_dependen(tabla, columna \\ nil) do
    nombres =
      Repo.query!(
        """
        SELECT DISTINCT v.relname
        FROM pg_depend d
        JOIN pg_rewrite r ON r.oid = d.objid
        JOIN pg_class v ON v.oid = r.ev_class
        JOIN pg_class t ON t.oid = d.refobjid
        LEFT JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = d.refobjsubid
        WHERE t.relname = $1 AND v.relname <> $1 AND v.relname LIKE 'pty\\_sql\\_%'
          AND ($2::text IS NULL OR a.attname = $2)
        """,
        [tabla, columna]
      ).rows
      |> List.flatten()

    from(h in MetadataApp.BusinessProcessBuilder.MetaSchema.Header,
      where: h.schema_context_name in ^nombres and is_nil(h.delete_guid),
      select: %{nombre: h.schema_context_name, etiqueta: h.schema_context_label}
    )
    |> Repo.all()
    |> then(fn encontrados -> encontrados ++ for(n <- nombres, not Enum.any?(encontrados, &(&1.nombre == n)), do: %{nombre: n, etiqueta: n}) end)
  end

  @doc "`:ok` o `{:error, mensaje}` si alguna SQL View usa `tabla` (o su `columna`)."
  def validar_sin_vistas(tabla, columna \\ nil) do
    case vistas_que_dependen(tabla, columna) do
      [] ->
        :ok

      vistas ->
        que = if columna, do: "el campo #{columna}", else: "el catálogo #{tabla}"
        {:error, "No se puede eliminar #{que}: lo usa la SQL View #{Enum.map_join(vistas, ", ", &"«#{&1.etiqueta}»")}. Ajusta su SQL primero."}
    end
  end

  # --- Diccionario en un campo referencia (R24-R28) --------------------------

  @doc """
  Diccionarios que puede elegir un campo del catálogo `catalogo` (R24):
  SQL View tipo 4, uso Diccionario, no visibles, con SQL guardado y con
  `catalogo` autorizado. `[%{nombre:, etiqueta:, columnas:}]`.
  """
  def diccionarios_para(catalogo) do
    from(c in ConsultaSql,
      join: h in assoc(c, :header),
      where:
        is_nil(c.delete_guid) and is_nil(h.delete_guid) and h.schema_context_type == @tipo and h.schema_visible == false and
          c.uso == "diccionario" and not is_nil(c.sql) and ^catalogo in c.bcs_autorizados,
      order_by: h.schema_context_label,
      select: %{nombre: h.schema_context_name, etiqueta: h.schema_context_label, columnas: c.columnas}
    )
    |> Repo.all()
  end

  @doc """
  R25: todos los `id` del Diccionario existen en el catálogo destino
  (tabla real de `catalogo_destino`). Un anti-join, con tiempo máximo.
  """
  def verificar_ids_en_destino(nombre, catalogo_destino) do
    vista = identificador!(nombre)

    with modulo when not is_nil(modulo) <- MetadataApp.BusinessProcessBuilder.CatalogoGenerico.modulo_destino_de(catalogo_destino) || {:error, "No existe el catálogo destino #{catalogo_destino}."},
         tabla = modulo.__schema__(:source),
         {:ok, %{rows: [[faltantes]]}} <-
           ejecutar(fn -> Repo.query!("SELECT count(*) FROM #{vista} v WHERE NOT EXISTS (SELECT 1 FROM #{tabla} d WHERE d.id = v.id)", []) end) do
      if faltantes == 0,
        do: :ok,
        else: {:error, "El Diccionario entrega #{faltantes} id que no existen en #{catalogo_destino}: la llave del campo los rechazaría."}
    else
      {:error, motivo} when is_atom(motivo) -> {:error, mensaje_ejecucion(motivo)}
      error -> error
    end
  end

  @doc """
  Query sobre el Diccionario de un campo (`props["diccionario"]`), con el
  alcance por columnas (`scope`, o `:sin_alcance`), los filtros sobre
  columnas del Diccionario (`filtros_dic`, `[{columna, valor}]`) y los
  filtros sobre el catálogo destino (`filtros_destino`, formato de
  `CatalogoGenerico.aplicar_filtros/2`) como `v.id IN (subconsulta)`.
  """
  def query_diccionario(props, filtros_dic, filtros_destino, scope) do
    nombre = get_in(props, ["diccionario", "consulta"])
    consulta_sql = obtener_por_catalogo(nombre)

    base = from(v in identificador!(nombre))
    base = if scope == :sin_alcance, do: base, else: alcance_por_columnas(base, scope, consulta_sql.columnas)

    base =
      Enum.reduce(filtros_dic, base, fn {columna, valor}, acc -> filtro_columna(acc, atomo_columna(columna), valor) end)

    case filtros_destino do
      [] ->
        base

      filtros ->
        modulo = MetadataApp.BusinessProcessBuilder.CatalogoGenerico.modulo_destino_de(props["catalogo"])

        ids =
          from(d in modulo, where: is_nil(d.delete_guid), select: d.id)
          |> MetadataApp.BusinessProcessBuilder.CatalogoGenerico.aplicar_filtros(filtros)

        from(v in base, where: field(v, :id) in subquery(ids))
    end
  end

  # Se compara como texto: el valor llega del formulario como string y la
  # columna de la vista puede ser de cualquier tipo.
  defp filtro_columna(query, campo, {:en_ci, valores}),
    do: from(v in query, where: fragment("upper(trim(CAST(? AS text)))", field(v, ^campo)) in ^valores)

  defp filtro_columna(query, campo, valor),
    do: from(v in query, where: fragment("CAST(? AS text)", field(v, ^campo)) == ^to_string(valor))

  @doc "Opciones `[{id, etiqueta}]` del combo de un campo con Diccionario (R26), a lo más 500, sin repetidos."
  def opciones_diccionario(props, filtros_dic, filtros_destino, scope) do
    descripcion = Enum.map(get_in(props, ["diccionario", "descripcion"]) || [], &atomo_columna/1)
    campos = [:id | descripcion]

    props
    |> query_diccionario(filtros_dic, filtros_destino, scope)
    |> then(&from(v in &1, select: map(v, ^campos), order_by: field(v, :id), limit: 500))
    |> then(fn q -> ejecutar(fn -> Repo.all(q) end) end)
    |> case do
      {:ok, filas} ->
        filas
        |> Enum.uniq_by(& &1.id)
        |> Enum.map(fn fila -> {fila.id, Enum.map_join(descripcion, " - ", &to_string(Map.get(fila, &1) || ""))} end)

      {:error, _motivo} ->
        []
    end
  end

  @doc """
  R28: el id `valor` está en el Diccionario del campo, con sus filtros. Sin
  alcance: el changeset no conoce la sesión del usuario (ver
  `02.design.md` §6). `true`/`false`; si la vista no se puede leer, `true`
  (no bloquear el guardado por una falla de configuración, mismo criterio
  que los filtros fijos).
  """
  def pertenece?(props, valor, filtros_dic, filtros_destino) do
    q = from(v in query_diccionario(props, filtros_dic, filtros_destino, :sin_alcance), where: field(v, :id) == ^valor)

    case ejecutar(fn -> Repo.exists?(q) end) do
      {:ok, existe?} -> existe?
      {:error, _} -> true
    end
  rescue
    ArgumentError -> true
  end

  # --- Filas para el listado y la API (R3, R21) -----------------------------

  @doc """
  Una página de filas de la vista, con alcance (R20) y la ejecución
  segura. `{:ok, %{columnas:, filas:, total:, pagina:, por_pagina:}}`.
  Las filas son mapas `%{"columna" => valor}` en el orden del SQL.
  """
  def filas(nombre, scope, pagina \\ 1, por_pagina \\ 25) do
    case obtener_por_catalogo(nombre) do
      %ConsultaSql{sql: sql} = consulta_sql when is_binary(sql) -> filas_de(consulta_sql, nombre, scope, pagina, por_pagina)
      _ -> {:error, "Esta SQL View todavía no tiene SQL guardado."}
    end
  end

  defp filas_de(consulta_sql, nombre, scope, pagina, por_pagina) do
    vista = identificador!(nombre)
    columnas = consulta_sql.columnas
    campos = Enum.map(columnas, &atomo_columna(&1["nombre"]))
    pagina = max(pagina, 1)

    base = alcance_por_columnas(from(v in vista), scope, columnas)

    ejecutar(fn ->
      total = Repo.aggregate(base, :count)

      filas =
        from(v in base, select: map(v, ^campos), limit: ^por_pagina, offset: ^((pagina - 1) * por_pagina))
        |> Repo.all()
        |> Enum.map(fn fila -> Map.new(campos, &{Atom.to_string(&1), Map.get(fila, &1)}) end)

      %{columnas: columnas, filas: filas, total: total, pagina: pagina, por_pagina: por_pagina}
    end)
  end

  defp mensaje_de_error(%Postgrex.Error{postgres: %{code: :query_canceled}}), do: mensaje_ejecucion(:tiempo_excedido)
  defp mensaje_de_error(%Postgrex.Error{postgres: %{message: mensaje}}), do: "La base de datos respondió: #{mensaje}"
  defp mensaje_de_error(%{__exception__: true} = error), do: Exception.message(error)
  defp mensaje_de_error(otro), do: inspect(otro)

  defp resumen_errores(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {mensaje, _opts} -> mensaje end)
    |> Enum.map_join("; ", fn {campo, mensajes} -> "#{campo}: #{Enum.join(mensajes, ", ")}" end)
  end

  defp generar_guid, do: Ecto.UUID.generate() |> String.replace("-", "")
end
