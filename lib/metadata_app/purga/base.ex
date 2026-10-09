defmodule MetadataApp.Purga.Base do
  @moduledoc """
  Lo que la purga hace dentro de la base de UN sistema destino
  (SPEC-ARQ-3009202601, design §5). Corre en el pod de ese destino, vía
  `MetadataApp.Release.Purga`, siempre contra `MetadataApp.Repo`.

  Las tablas del artefacto llegan como parámetro (salen del inventario
  `retirado-X`, design §4), nunca se deducen de la metadata de aquí: en
  una purga que quedó a medias el header ya puede no existir.

  Nunca usa `Ecto.Migrator` con `:to`/`:step` (NF1): las migraciones del
  artefacto se quitan de la tabla de migraciones (`migration_source` del
  Repo, `meta_schema_migrations` en este proyecto) por versión exacta.
  """

  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.Purga.{Registro, Unidad}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  # FK hacia meta_schema_header que la purga resuelve borrando, no que
  # bloquean: historial propio del artefacto.
  @fk_header_propias ~w(folio_historial meta_schema_transicion_eventos)

  ## Inventario

  @doc """
  Artefactos `pty_*` presentes en esta base, con un estimado de filas por
  tabla (`pg_class.reltuples`, sin `COUNT(*)`: no escanea tablas grandes),
  y todas las versiones de migración aplicadas: una lápida no tiene header,
  solo se ve por sus versiones.

  `%{unidades: [%{maestro, tablas, tipo, filas_estimadas}], versiones: [integer]}`.
  """
  def inventario do
    unidades = Unidad.unidades(Repo)
    estimados = estimar_filas(Enum.flat_map(unidades, & &1.tablas))

    %{
      unidades:
        Enum.map(unidades, fn u ->
          %{
            maestro: u.maestro,
            tablas: u.tablas,
            tipo: u.tipo,
            filas_estimadas: Enum.sum(Enum.map(u.tablas, &Map.get(estimados, &1, 0)))
          }
        end),
      versiones:
        Repo.query!("SELECT version FROM #{tabla_migraciones()}", []).rows |> List.flatten()
    }
  end

  defp estimar_filas([]), do: %{}

  defp estimar_filas(tablas) do
    Repo.query!(
      "SELECT relname::text, greatest(reltuples, 0)::bigint FROM pg_class WHERE relkind = 'r' AND relname = ANY($1)",
      [tablas]
    ).rows
    |> Map.new(fn [t, n] -> {t, n} end)
  end

  ## Impacto

  @doc """
  Qué hay de `tablas` en esta base y si se puede purgar. No modifica nada.

  `opts[:priv_dir]`: dónde buscar si la imagen todavía trae el artefacto
  (default: el `priv/` de este release).
  """
  def impacto(artefacto, tablas, versiones, opts \\ []) do
    with :ok <- validar_nombres([artefacto | tablas]) do
      headers = headers_de(tablas)

      # `tabla`: hay un objeto físico con ese nombre (tabla, vista o
      # función, R15); `objeto` dice cuál. Solo una tabla tiene filas.
      detalle =
        Enum.map(tablas, fn t ->
          objeto = objeto_fisico(t)
          filas = if objeto == "tabla", do: contar(t), else: 0

          %{
            nombre: t,
            tabla: objeto != nil,
            objeto: objeto,
            header: Map.has_key?(headers, t),
            filas: filas
          }
        end)

      aplicadas = versiones_aplicadas(versiones)

      {:ok,
       %{
         artefacto: artefacto,
         tablas: detalle,
         filas: Enum.sum(Enum.map(detalle, & &1.filas)),
         imagen_incluye:
           imagen_incluye?(tablas, opts[:priv_dir] || Application.app_dir(:metadata_app, "priv")),
         dependencias: dependencias(tablas, Map.values(headers)),
         versiones_aplicadas: aplicadas,
         nada_que_borrar:
           aplicadas == [] and Enum.all?(detalle, &(not &1.tabla and not &1.header))
       }}
    end
  end

  defp validar_nombres(nombres) do
    case Enum.reject(nombres, &Unidad.nombre_valido?/1) do
      [] -> :ok
      malos -> {:error, "Nombres no permitidos (solo pty_*): #{Enum.join(malos, ", ")}"}
    end
  end

  # Por nombre, incluidos los de borrado lógico (su tabla puede seguir viva).
  defp headers_de(tablas) do
    from(h in "meta_schema_header",
      where: h.schema_context_name in ^tablas,
      select: {h.schema_context_name, h.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  # Una Consulta SQL es una vista (Diccionario/Consulta) o una función
  # (Servicio); un catálogo, una tabla.
  defp objeto_fisico(t) do
    case Repo.query!("SELECT relkind::text FROM pg_class WHERE oid = to_regclass($1)", [t]).rows do
      [["r"]] ->
        "tabla"

      [["v"]] ->
        "vista"

      [["m"]] ->
        "vista_materializada"

      [] ->
        if Repo.query!("SELECT 1 FROM pg_proc WHERE proname = $1", [t]).rows != [], do: "funcion"

      _ ->
        nil
    end
  end

  @drop %{
    "tabla" => "TABLE",
    "vista" => "VIEW",
    "vista_materializada" => "MATERIALIZED VIEW",
    "funcion" => "FUNCTION"
  }

  defp contar(t), do: Repo.query!(~s|SELECT count(*) FROM "#{t}"|, []).rows |> hd() |> hd()

  defp tabla_migraciones do
    nombre = Repo.config()[:migration_source] || "schema_migrations"
    ~s|"#{nombre}"|
  end

  defp versiones_aplicadas([]), do: []

  defp versiones_aplicadas(versiones) do
    Repo.query!(
      "SELECT version FROM #{tabla_migraciones()} WHERE version = ANY($1) ORDER BY version",
      [versiones]
    ).rows
    |> List.flatten()
  end

  @doc """
  ¿La imagen que corre aquí todavía trae alguna tabla del artefacto? Si la
  trae, purgar es inútil: el siguiente arranque la vuelve a crear (R6).
  """
  def imagen_incluye?(tablas, priv_dir) do
    # Path.expand/1 deja la ruta con "/": Path.wildcard/1 toma "\" como
    # escape y en Windows no encontraría nada.
    priv_dir = Path.expand(priv_dir)

    meta? =
      Enum.any?(
        tablas,
        &File.exists?(Path.join([priv_dir, "repo", "catalogos", "#{&1}.meta.json"]))
      )

    meta? or
      Unidad.migraciones(
        tablas,
        Enum.map(
          Path.wildcard(Path.join([priv_dir, "repo", "migrations", "*.exs"])),
          &Path.basename/1
        ),
        Enum.map(Unidad.headers(Repo), & &1.nombre)
      ) != []
  end

  ## Dependencias (R5)

  @doc "Lo que, fuera del artefacto, depende de él. Lista de textos; vacía si nada."
  def dependencias(tablas, header_ids) do
    propias = MapSet.new(tablas)

    referencias =
      tablas
      |> Enum.flat_map(&MetaSchemaContext.listar_dependientes/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(propias, &1))
      |> Enum.map(&"El catálogo #{&1} tiene un campo que referencia a este artefacto.")

    vistas =
      for t <- tablas,
          v <- MetadataApp.ConsultasSql.vistas_que_dependen(t),
          not MapSet.member?(propias, v.nombre) do
        "La Consulta SQL «#{v.etiqueta}» (#{v.nombre}) usa la tabla #{t}."
      end

    referencias ++
      Enum.uniq(vistas) ++
      fk_hacia_tablas(tablas) ++
      registros_que_apuntan(tablas, header_ids) ++ usos_de_consultas(tablas, header_ids)
  end

  # Llaves foráneas reales de otra tabla hacia una tabla del artefacto.
  defp fk_hacia_tablas(tablas) do
    Repo.query!(
      """
      SELECT DISTINCT c.conrelid::regclass::text, c.confrelid::regclass::text
      FROM pg_constraint c
      WHERE c.contype = 'f'
        AND c.confrelid::regclass::text = ANY($1)
        AND NOT (c.conrelid::regclass::text = ANY($1))
      ORDER BY 1
      """,
      [tablas]
    ).rows
    |> Enum.map(fn [origen, destino] ->
      "La tabla #{origen} tiene una llave foránea hacia #{destino}."
    end)
  end

  # Registros de negocio (fuera de meta_schema_* y del artefacto) que apuntan
  # al header del artefacto, ej. un Perfil de Folio con `documento` = este
  # catálogo.
  defp registros_que_apuntan(_tablas, []), do: []

  defp registros_que_apuntan(tablas, header_ids) do
    Repo.query!(
      """
      SELECT c.conrelid::regclass::text, a.attname::text
      FROM pg_constraint c
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY(c.conkey)
      WHERE c.contype = 'f' AND c.confrelid = 'meta_schema_header'::regclass
        AND c.conrelid::regclass::text NOT LIKE 'meta\\_schema\\_%'
        AND NOT (c.conrelid::regclass::text = ANY($1))
      ORDER BY 1
      """,
      [tablas ++ @fk_header_propias]
    ).rows
    |> Enum.flat_map(fn [tabla, columna] ->
      n =
        Repo.query!(~s|SELECT count(*) FROM "#{tabla}" WHERE "#{columna}" = ANY($1)|, [header_ids]).rows
        |> hd()
        |> hd()

      if n > 0,
        do: [
          "La tabla #{tabla} tiene #{n} registro(s) que apuntan a este artefacto (columna #{columna})."
        ],
        else: []
    end)
  end

  # R15: una Consulta SQL usada como Diccionario por un campo, o como
  # Servicio por reglas, y cualquier Endpoint vivo de una Consulta o
  # Consulta SQL del artefacto. Mismas reglas que
  # ConsultasSql.validar_sin_usos/2. Solo se buscan usos de los nombres que
  # son Consulta SQL: buscar el nombre de un catálogo en el código de las
  # reglas daría falsos positivos.
  defp usos_de_consultas(_tablas, []), do: []

  defp usos_de_consultas(tablas, header_ids) do
    propias = MapSet.new(tablas)

    consultas_sql =
      from(h in "meta_schema_header",
        where: h.id in ^header_ids and h.schema_context_type == 4,
        select: h.schema_context_name
      )
      |> Repo.all()

    campos =
      for n <- consultas_sql,
          u <- MetadataApp.ConsultasSql.campos_que_usan(n),
          not MapSet.member?(propias, u.catalogo) do
        "El campo #{u.campo} de #{u.catalogo} usa el Diccionario #{n}."
      end

    reglas =
      for n <- consultas_sql,
          u <- MetadataApp.ConsultasSql.reglas_que_usan(n),
          not MapSet.member?(propias, u.catalogo) do
        "Las reglas #{String.upcase(u.tipo)} de #{u.catalogo} usan el Servicio #{n}."
      end

    endpoints =
      from(e in "meta_schema_consulta_endpoint",
        left_join: c in "meta_schema_consulta",
        on: c.id == e.meta_schema_consulta_id,
        left_join: s in "meta_schema_consulta_sql",
        on: s.id == e.meta_schema_consulta_sql_id,
        where:
          is_nil(e.delete_guid) and
            (c.meta_schema_header_id in ^header_ids or s.meta_schema_header_id in ^header_ids),
        select: {e.nombre, e.ruta}
      )
      |> Repo.all()
      |> Enum.map(fn {nombre, ruta} ->
        "El Endpoint «#{nombre}» (/#{ruta}) usa este artefacto. Elimínalo primero."
      end)

    campos ++ reglas ++ endpoints
  end

  ## Ejecutar (R7, R8, R13, NF3)

  @doc """
  Purga el artefacto en esta base. `params`:
  `%{artefacto, tablas (detalles primero), versiones, filas_confirmadas,
  usuario_email, respaldo}`. Repite el impacto antes de tocar nada y
  registra el resultado en la bitácora, termine bien o mal (R12).

  `{:ok, %{resultado: "ok" | "sin_cambios", ...}}` | `{:error, mensaje}`.
  """
  def ejecutar(params, opts \\ []) do
    %{artefacto: artefacto, tablas: tablas, versiones: versiones} = params

    case impacto(artefacto, tablas, versiones, opts) do
      {:error, mensaje} ->
        {:error, mensaje}

      {:ok, imp} ->
        case bloqueo(imp, Map.get(params, :filas_confirmadas, 0), opts) do
          nil when imp.nada_que_borrar ->
            registrar(params, imp, "sin_cambios", "No había nada que borrar.")
            {:ok, %{resultado: "sin_cambios", impacto: imp}}

          nil ->
            purgar(params, imp)

          mensaje ->
            registrar(params, imp, "error", mensaje)
            {:error, mensaje}
        end
    end
  end

  # opts[:local]: purga de la copia local de quien purga (R14). Ahí la
  # "imagen" es la propia máquina (sus archivos se borran después) y los
  # registros ya se confirmaron en el modal.
  defp bloqueo(imp, filas_confirmadas, opts) do
    local = Keyword.get(opts, :local, false)

    cond do
      imp.imagen_incluye and not local ->
        "La imagen que corre aquí todavía incluye #{imp.artefacto}: primero hay que retirarlo y desplegar una imagen sin él."

      imp.dependencias != [] ->
        "Hay dependencias: " <> Enum.join(imp.dependencias, " ")

      imp.filas > filas_confirmadas and not local ->
        "#{imp.artefacto} tiene #{imp.filas} registro(s) y se confirmaron #{filas_confirmadas}. Vuelve a revisar el impacto."

      true ->
        nil
    end
  end

  defp purgar(params, imp) do
    resultado =
      Repo.transaction(fn ->
        for %{nombre: t, objeto: objeto} <- imp.tablas,
            objeto,
            do: Repo.query!(~s|DROP #{@drop[objeto]} "#{t}"|, [])

        # Mismo orden que `tablas` (detalles primero): el FK
        # schema_encabezado_id de un detalle no tiene ON DELETE.
        headers = headers_de(params.tablas)

        params.tablas
        |> Enum.map(&headers[&1])
        |> Enum.reject(&is_nil/1)
        |> Enum.each(&borrar_header/1)

        Repo.delete_all(from p in "meta_schema_permiso", where: p.recurso in ^params.tablas)
        Repo.delete_all(from l in "meta_schema_accion_log", where: l.catalogo in ^params.tablas)

        Repo.delete_all(
          from a in "meta_schema_auditoria_definicion",
            where: a.schema_context_name in ^params.tablas
        )

        Repo.query!("DELETE FROM #{tabla_migraciones()} WHERE version = ANY($1)", [
          imp.versiones_aplicadas
        ])

        insertar_registro!(params, imp, "ok", nil)
      end)

    case resultado do
      {:ok, registro} ->
        invalidar_cache_permisos()
        {:ok, %{resultado: "ok", impacto: imp, registro_id: registro.id}}

      {:error, motivo} ->
        mensaje = inspect(motivo)
        registrar(params, imp, "error", mensaje)
        {:error, mensaje}
    end
  rescue
    e ->
      mensaje = Exception.message(e)
      registrar(params, imp, "error", mensaje)
      {:error, mensaje}
  end

  # Lo que cuelga del header sin ON DELETE CASCADE. Lo demás (detalles,
  # estados, transiciones, plantillas, reglas, alcance, consultas) se va en
  # cascada con el DELETE del header.
  defp borrar_header(id) do
    Repo.delete_all(from f in "folio_historial", where: f.meta_schema_header_id == ^id)
    MetadataApp.MetaEstadosAdmin.purgar_historial(id)
    MetadataApp.TRN.purgar_registro_central(id)
    Repo.delete_all(from a in "meta_schema_accion_externa", where: a.meta_schema_header_id == ^id)

    Repo.delete_all(
      from p in "meta_schema_plantillas_importacion", where: p.meta_schema_header_id == ^id
    )

    # Endpoints con borrado lógico de una Consulta SQL: su FK no tiene
    # cascada y detendrían el borrado (los vivos ya bloquearon, R15).
    consultas_sql =
      from(c in "meta_schema_consulta_sql", where: c.meta_schema_header_id == ^id, select: c.id)

    Repo.delete_all(
      from e in "meta_schema_consulta_endpoint",
        where: e.meta_schema_consulta_sql_id in subquery(consultas_sql)
    )

    Repo.delete_all(from c in "meta_schema_consulta_sql", where: c.meta_schema_header_id == ^id)
    Repo.delete_all(from h in "meta_schema_header", where: h.id == ^id)
  end

  defp invalidar_cache_permisos do
    tabla = MetadataApp.Permissions.Cache.tabla()
    if :ets.whereis(tabla) != :undefined, do: :ets.delete_all_objects(tabla)
    :ok
  end

  ## Bitácora (R12)

  @doc "Registra un retiro o una purga que no pasó por `ejecutar/2` (ej. un retiro)."
  def registrar(attrs) do
    %Registro{} |> Registro.changeset(attrs) |> Repo.insert()
  end

  defp registrar(params, imp, resultado, mensaje) do
    registrar(atributos(params, imp, resultado, mensaje))
  end

  defp insertar_registro!(params, imp, resultado, mensaje) do
    %Registro{}
    |> Registro.changeset(atributos(params, imp, resultado, mensaje))
    |> Repo.insert!()
  end

  defp atributos(params, imp, resultado, mensaje) do
    %{
      artefacto: params.artefacto,
      accion: "purga",
      tablas: Map.new(imp.tablas, &{&1.nombre, &1.filas}),
      versiones: imp.versiones_aplicadas,
      respaldo: Map.get(params, :respaldo),
      resultado: resultado,
      mensaje: mensaje,
      usuario_email: params.usuario_email
    }
  end

  @doc "Los últimos `limite` registros de la bitácora, el más reciente primero."
  def bitacora(limite \\ 200) do
    from(r in Registro, order_by: [desc: r.inserted_at, desc: r.id], limit: ^limite)
    |> Repo.all()
    |> Enum.map(
      &Map.take(&1, [
        :id,
        :artefacto,
        :accion,
        :tablas,
        :versiones,
        :respaldo,
        :resultado,
        :mensaje,
        :usuario_email,
        :inserted_at
      ])
    )
  end
end
