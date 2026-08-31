defmodule MetadataApp.BusinessProcessBuilder.CatalogoGenerador do
  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.MetaReglasCodigo
  alias MetadataApp.MetaPlantillas
  alias MetadataApp.MetaAuditoriaDefinicion

  # Genera migración y schema para schema_context_name a partir de lo
  # registrado en meta_schema_detail y corre la migración. Si el catálogo ya
  # existe (schema ya generado antes), no hace nada — es idempotente.
  # Postgres trunca (sin error) identificadores de más de 63 bytes. El índice
  # único del catálogo se nombra "<schema_context_name>_unico_index"; se deja
  # margen para ese sufijo y para nombres de constraint que Ecto derive.
  @tabla_longitud_maxima 50

  @spec generar(any()) ::
          {:error, <<_::64, _::_*8>>}
          | {:ok, %{:tabla => any(), :ya_existia => boolean(), optional(:modulo) => binary()}}
  def generar(schema_context_name) do
    schema_path = "lib/metadata_app/meta_business_process/catalogos/#{schema_context_name}.ex"
    header = MetaSchemaContext.obtener_header_por_nombre(schema_context_name)

    if File.exists?(schema_path) do
      asegurar_estado_id(schema_context_name)
      asegurar_fecha_registro(schema_context_name)
      asegurar_detalle_fecha_registro(header)
      asegurar_columnas_alcance(schema_context_name)
      asegurar_campos_nuevos(schema_context_name)
      {:ok, %{tabla: schema_context_name, ya_existia: true}}
    else
      detalles =
        schema_context_name
        |> MetaSchemaContext.listar_detalles()
        |> Enum.reject(&(&1.schema_context_field in ["id", "fecha_registro"]))

      case detalles do
        [] ->
          {:error,
           "No hay metadata en meta_schema_detail para #{schema_context_name} (aparte de 'id')."}

        detalles ->
          with :ok <- validar_tabla(schema_context_name),
               :ok <- validar_referencias(detalles),
               :ok <- validar_maestro_generado(header) do
            campos =
              for detalle <- detalles do
                propiedades = detalle.schema_context_properties || %{}
                tipo_str = Map.get(propiedades, "tipo", "string")
                tipo = tipo_ecto(tipo_str)
                opciones = construir_opciones(tipo_str, propiedades)
                {detalle.schema_context_field, tipo, opciones}
              end

            modulo = Macro.camelize(schema_context_name)

            crear_migracion(schema_context_name, campos, header)
            crear_schema(schema_context_name, modulo, campos, header)
            migrar()
            recompilar_schema(schema_context_name)

            # asegurar_detalle_fecha_registro/1 ANTES que crear_plantilla_default/1
            # a propósito: la plantilla automática arma sus filas a partir de
            # meta_schema_detail en ESE momento (ver definicion_automatica/1) — si
            # "fecha_registro" todavía no existiera ahí, la plantilla arrancaría
            # sin esa fila para siempre (el catálogo ya creado no vuelve a pasar
            # por acá). Best-effort: si falla, el catálogo ya está creado igual,
            # que es lo que de verdad importa.
            asegurar_detalle_fecha_registro(header)
            MetaPlantillas.crear_plantilla_default(header)

            {:ok, %{tabla: schema_context_name, modulo: modulo, ya_existia: false}}
          end
      end
    end
  end

  # Vista previa del impacto de borrar un catálogo: cuántas filas se
  # perderían y qué otros catálogos lo referencian (y por lo tanto bloquean
  # el borrado). No modifica nada.
  def impacto(schema_context_name) do
    with {:ok, header} <- buscar_header(schema_context_name) do
      filas = contar_filas_si_existe(schema_context_name)
      dependientes = MetaSchemaContext.listar_dependientes(schema_context_name)
      escenario = MetaEstadosAdmin.contar_escenario(header.id)

      {:ok,
       %{
         tabla: schema_context_name,
         filas: filas,
         dependientes: dependientes,
         motor_estados: escenario,
         advertencia:
           "Borrado TOTAL e irreversible: se eliminan #{filas} fila(s) de datos, el catálogo " <>
             "#{schema_context_name} completo, y del motor de estados #{escenario.estados} " <>
             "estado(s), #{escenario.transiciones} transición(es), #{escenario.reglas} regla(s) " <>
             "y #{escenario.eventos} evento(s) de historial de auditoría. Para confirmar: " <>
             "DELETE /api/catalogos/#{schema_context_name} con body " <>
             "{\"confirmar_tabla\": \"#{schema_context_name}\", \"confirmar_filas\": #{filas}}."
       }}
    end
  end

  # Borrado total e irreversible de un catálogo Y su escenario del motor de
  # estados: tabla, Header (sus Detalles se van en cascada por FK), Estados/
  # Transiciones/Reglas (cascada) y, deliberadamente, el HISTORIAL de
  # transiciones ya ejecutadas (meta_schema_transicion_eventos), que en el
  # uso normal está protegido con on_delete: :restrict — acá se purga a
  # propósito porque el usuario ya confirmó el borrado total repitiendo el
  # nombre de la tabla Y la cantidad exacta de filas actuales
  # (confirmar_filas) — ese segundo dato solo se conoce si antes se
  # consultó GET .../impacto, así que en la práctica encadena "mirar el
  # impacto" -> "borrar" sin necesidad de tokens ni estado de sesión: no
  # hay forma de acertar confirmar_filas a ciegas salvo por casualidad en
  # un catálogo vacío. Nunca hace rollback de la migración de creación (el
  # orden de versiones la hace frágil) — en cambio genera una migración
  # nueva hacia adelante que dropea la tabla, igual que cualquier otra
  # migración del historial.
  def eliminar(schema_context_name, confirmar_tabla, confirmar_filas, contexto \\ %{}) do
    with {:ok, _header} <- buscar_header(schema_context_name),
         :ok <- validar_confirmacion(schema_context_name, confirmar_tabla),
         :ok <- validar_confirmacion_filas(schema_context_name, confirmar_filas),
         :ok <- validar_sin_dependientes(schema_context_name) do
      # La migración generada (crear_migracion_drop/1) purga la metadata
      # (header/detail/historial/TRN) POR NOMBRE antes de dropear la tabla
      # -- así, cuando esta misma migración corra vía CI/CD contra
      # producción, el borrado queda completo ahí también, no solo en el
      # ambiente donde se pidió. No se purga acá aparte para no duplicar
      # (y porque el header ya no existiría cuando migrar/0 termine).
      crear_migracion_drop(schema_context_name)
      migrar()

      archivo_eliminado? = borrar_schema_file(schema_context_name)
      reglas_eliminadas? = borrar_reglas_dir(schema_context_name)
      borrar_export_meta(schema_context_name)

      MetaAuditoriaDefinicion.registrar(
        schema_context_name,
        "eliminar",
        %{"filas_eliminadas" => confirmar_filas},
        contexto
      )

      {:ok, %{tabla: schema_context_name, archivo_eliminado: archivo_eliminado?, reglas_eliminadas: reglas_eliminadas?}}
    end
  end

  @doc """
  Purga TODA la metadata (header, detail en cascada, historial de
  transiciones, registro TRN central) de un catálogo por NOMBRE -- pensada
  para correr desde DENTRO de la migración `up/0` que genera
  `crear_migracion_drop/1`, así el borrado de metadata queda completo en
  cualquier ambiente donde esa migración corra (dev al generarla,
  producción al desplegarla vía CI/CD) y no solo en el ambiente donde se
  pidió el borrado -- `header.id` es un autoincremental distinto por base,
  no se puede "grabar" un id fijo en la migración.

  No-op si el catálogo no tiene header en ESTE ambiente (ej. nunca se creó
  en producción) -- mismo criterio defensivo que `contar_filas_si_existe/1`.
  """
  def purgar_metadata_por_nombre(schema_context_name) do
    case MetaSchemaContext.obtener_header_por_nombre(schema_context_name) do
      nil ->
        :ok

      header ->
        MetaEstadosAdmin.purgar_historial(header.id)
        MetadataApp.TRN.purgar_registro_central(header.id)
        :ok = MetaSchemaContext.eliminar_header(header)
        :ok
    end
  end

  # Bug real (visto en producción): un catálogo puede tener metadata
  # (meta_schema_header/detail) sin que su tabla física llegue a existir
  # nunca — la creación quedó a medias en algún punto entre insertar la
  # metadata y correr crear_migracion/3. Sin esto, impacto/1 explotaba con
  # un Postgrex.Error crudo (undefined_table) en vez de simplemente
  # reportar 0 filas — no hay ninguna fila que perder si la tabla nunca
  # existió.
  defp contar_filas_si_existe(schema_context_name) do
    if tabla_existe?(schema_context_name) do
      Repo.aggregate(from(t in schema_context_name), :count)
    else
      0
    end
  end

  defp tabla_existe?(schema_context_name) do
    %{rows: [[existe]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [schema_context_name])
    existe
  end

  # Vista previa del impacto de quitar UN campo: cuántas filas tienen un
  # valor no-nulo ahí (esos valores se pierden con el DROP COLUMN). No
  # modifica nada.
  def impacto_campo(schema_context_name, campo) do
    with {:ok, _header} <- buscar_header(schema_context_name) do
      filas_con_valor =
        Repo.aggregate(
          from(t in schema_context_name, where: not is_nil(field(t, ^String.to_existing_atom(campo)))),
          :count
        )

      {:ok, %{campo: campo, filas_con_valor: filas_con_valor}}
    end
  end

  @doc """
  Tamaño real de cada columna, tal como quedó en Postgres — a propósito
  `information_schema`, no la metadata: un campo puede no tener
  `"longitud"`/`"precision"`/`"escala"` guardados en
  `schema_context_properties` (nunca se tocó esa capacidad al crearlo) y
  aun así la columna real cayó en el default del motor (varchar(255), ver
  `construir_opciones/2`) — leer la metadata ahí mentiría por omisión.
  `%{"campo" => "varchar(255)" | "10,2" | "sin límite" | nil}` — `nil`
  para tipos sin concepto de tamaño (integer/boolean/date/time).
  """
  def info_longitud_columnas(schema_context_name) do
    %{rows: filas} =
      Repo.query!(
        "select column_name, data_type, character_maximum_length, numeric_precision, numeric_scale from information_schema.columns where table_name = $1",
        [schema_context_name]
      )

    Map.new(filas, fn [campo, tipo, longitud, precision, escala] -> {campo, formatear_tamano_columna(tipo, longitud, precision, escala)} end)
  end

  defp formatear_tamano_columna("character varying", longitud, _precision, _escala) when is_integer(longitud), do: "varchar(#{longitud})"
  defp formatear_tamano_columna("text", _longitud, _precision, _escala), do: "sin límite"
  defp formatear_tamano_columna("numeric", _longitud, precision, escala) when is_integer(precision) and is_integer(escala), do: "#{precision},#{escala}"
  defp formatear_tamano_columna("numeric", _longitud, _precision, _escala), do: "sin límite"
  defp formatear_tamano_columna(_tipo, _longitud, _precision, _escala), do: nil

  # Quita un campo de un catálogo YA generado: soft-delete del Detail +
  # DROP COLUMN real (migración hacia adelante, mismo criterio que
  # crear_migracion_drop/1 — nunca se toca la migración de creación) +
  # regenera el schema .ex sin el campo. confirmar_campo repite el mismo
  # criterio de validar_confirmacion/2 que ya usa eliminar/3 (escribir el
  # nombre exacto, no una frase fija) — acá alcanza con el nombre del campo
  # solo (no hace falta confirmar_filas como en el borrado total: esto
  # pierde una columna, no el catálogo entero).
  def eliminar_campo(schema_context_name, campo, confirmar_campo, contexto \\ %{}) do
    with {:ok, _header} <- buscar_header(schema_context_name),
         :ok <- validar_confirmacion(campo, confirmar_campo),
         {:ok, detalle} <- buscar_detalle(schema_context_name, campo) do
      MetaSchemaContext.eliminar_detalle(detalle)
      quitar_columna(schema_context_name, campo)
      asegurar_campos_nuevos(schema_context_name)

      MetaAuditoriaDefinicion.registrar(schema_context_name, "eliminar_campo", %{"campo" => campo}, contexto)

      {:ok, %{campo: campo}}
    end
  end

  defp buscar_detalle(schema_context_name, campo) do
    case Enum.find(MetaSchemaContext.listar_detalles(schema_context_name), &(&1.schema_context_field == campo)) do
      nil -> {:error, "el campo #{campo} no existe en #{schema_context_name}"}
      detalle -> {:ok, detalle}
    end
  end

  # Mismo motivo que crear_migracion_drop/1 y agregar_columnas/2: migración
  # hacia adelante (nunca se toca la de creación), sufijo con timestamp para
  # que el nombre descriptivo no choque si se repite la operación.
  defp quitar_columna(schema_context_name, campo) do
    timestamp = timestamp_utc()

    modulo_migracion =
      "Quitar" <> Macro.camelize(campo) <> "De" <> Macro.camelize(schema_context_name) <> timestamp

    path = "priv/repo/migrations/#{timestamp}_quitar_#{campo}_de_#{schema_context_name}_#{timestamp}.exs"

    contenido = """
    defmodule MetadataApp.Repo.Migrations.#{modulo_migracion} do
      use Ecto.Migration

      def change do
        alter table(:#{schema_context_name}) do
          remove :#{campo}
        end
      end
    end
    """

    File.write!(path, contenido)
    migrar()
  end

  # Backfill de estado_id para catálogos generados antes de que este campo
  # existiera. Deliberadamente NO es una migración versionada: el orden de
  # versiones entre migraciones escritas a mano (14 dígitos) y las que arma
  # este mismo generador (17 dígitos, ver timestamp_utc/0) no es confiable
  # entre sí (un timestamp de 17 dígitos siempre ordena después que uno de
  # 14, sin importar la fecha real). Corre acá, en cambio, cada vez que
  # gen.catalogos toca un catálogo ya existente — momento en el que la tabla
  # ya seguro existe. Idempotente (IF NOT EXISTS).
  defp asegurar_estado_id(schema_context_name) do
    Repo.query!("""
    ALTER TABLE #{schema_context_name}
    ADD COLUMN IF NOT EXISTS estado_id integer
      REFERENCES meta_schema_estados(id)
    """)

    :ok
  end

  # Mismo criterio que asegurar_estado_id/1 de arriba — un catálogo
  # generado ANTES de que fecha_registro existiera (2026-08-06) no tiene
  # esta columna todavía; se agrega sola la próxima vez que gen.catalogos
  # lo toca. Backfill de las filas YA existentes (desde meta_schema_auditoria)
  # va aparte, en una migración de una sola vez — ver
  # priv/repo/migrations/*_backfill_fecha_registro.exs.
  defp asegurar_fecha_registro(schema_context_name) do
    Repo.query!("""
    ALTER TABLE #{schema_context_name}
    ADD COLUMN IF NOT EXISTS fecha_registro timestamptz
    """)

    :ok
  end

  # fecha_registro es un campo de SISTEMA (fuera de @campos/meta_schema_detail
  # normal, ver MetaCatalogoGenerico) — pero para que el usuario final lo
  # vea en Get View/tabla como cualquier otro campo real (a diferencia de
  # estado_id/trn, que son puramente internos), necesita SU PROPIA fila en
  # meta_schema_detail igual. "editable" => false porque no hay ningún
  # camino para cambiarlo por PATCH (ver rechazar_no_editables/4 en
  # CatalogoGenerico). Idempotente — no duplica la fila si ya existe (ej.
  # gen.catalogos corriendo de nuevo sobre un catálogo que ya la tiene).
  defp asegurar_detalle_fecha_registro(header) do
    ya_existe? =
      header.schema_context_name
      |> MetaSchemaContext.listar_detalles()
      |> Enum.any?(&(&1.schema_context_field == "fecha_registro"))

    unless ya_existe? do
      MetaSchemaContext.agregar_detalle(header, %{
        "schema_context_field" => "fecha_registro",
        "schema_context_properties" => %{
          "etiqueta" => "Fecha de registro",
          "tipo" => "date",
          "orden" => 9999,
          "visible" => true,
          "editable" => false
        }
      })
    end

    :ok
  end

  # Agrega al catálogo YA generado los campos de meta_schema_detail que
  # todavía no son columnas físicas de la tabla — permite extender un
  # catálogo existente (ej. sumarle un campo nuevo) sin borrar y recrear
  # todo. No es una migración versionada por el mismo motivo que
  # asegurar_estado_id/1 (timestamps de 17 dígitos de este generador ordenan
  # siempre después que cualquier migración escrita a mano de 14).
  defp asegurar_campos_nuevos(schema_context_name) do
    header = MetaSchemaContext.obtener_header_por_nombre(schema_context_name)

    detalles =
      schema_context_name
      |> MetaSchemaContext.listar_detalles()
      |> Enum.reject(&(&1.schema_context_field in ["id", "fecha_registro"]))

    campos =
      for detalle <- detalles do
        propiedades = detalle.schema_context_properties || %{}
        tipo_str = Map.get(propiedades, "tipo", "string")
        tipo = tipo_ecto(tipo_str)
        opciones = construir_opciones(tipo_str, propiedades)
        {detalle.schema_context_field, tipo, opciones}
      end

    columnas_actuales = columnas_existentes(schema_context_name)

    campos_nuevos =
      Enum.reject(campos, fn {campo, _tipo, _opciones} ->
        to_string(campo) in columnas_actuales
      end)

    if campos_nuevos != [], do: agregar_columnas(schema_context_name, campos_nuevos)
    asegurar_trn(schema_context_name, header, columnas_actuales)
    asegurar_folio(schema_context_name, header, columnas_actuales)

    # Siempre regenera el schema (no solo cuando hay columnas nuevas): así
    # también recoge cambios de propiedades en campos que ya existían como
    # columna (ej. marcar uno como "opcional" después de agregarlo). Barato
    # e idempotente — sobreescribe el mismo contenido si nada cambió.
    modulo = Macro.camelize(schema_context_name)
    crear_schema(schema_context_name, modulo, campos, header)
    recompilar_schema(schema_context_name)
    :ok
  end

  @doc """
  Alinea el NOT NULL real de una columna YA EXISTENTE con lo que dice
  "opcional" en meta_schema_detail — a diferencia de asegurar_campos_nuevos/1
  (que nunca hace ALTER COLUMN sobre una columna que ya existe, a propósito,
  ver el bug real de 2026-08-17: pty_dsd_empleados_fecha_baja se marcó
  "opcional" en el diseñador pero la columna siguió NOT NULL, y el primer
  alta sin ese campo reventó con un 23502 sin atrapar), esto SÍ altera la
  columna física, pero solo en la dirección segura o cuando de verdad se
  puede:

    - "opcional" pasa a true: siempre corre un DROP NOT NULL — relajar una
      restricción nunca puede fallar por datos existentes.
    - "opcional" pasa a false: solo si HOY no hay ninguna fila con esa
      columna en NULL (si las hay, un SET NOT NULL fallaría igual que
      fallaba el alta real — mejor bloquearlo acá, ANTES de guardar, con
      un mensaje claro, que dejarlo reventar en el próximo alta).

  Devuelve `:ok` (incluye el caso "no había nada que sincronizar": columna
  todavía no es física, o ya estaba como corresponde) o `{:error, mensaje}`
  cuando se bloquea el caso riesgoso de arriba. Nunca levanta — cualquier
  otro fallo real de Postgres al correr la migración sí se propaga como
  excepción, igual que el resto del generador.

  Un campo tipo "referencia" SÍ se sincroniza acá igual que cualquier
  otro (bug real encontrado 2026-08-20, misma familia que el de
  pty_dsd_empleados_fecha_baja de arriba): `columna_migracion/3` (CREATE
  TABLE) marcaba toda FK como `null: false` sin mirar "opcional" —
  `tipo_ecto("referencia")` es `:integer`, así que
  `modificar_columna_migracion/4` ya sabe alterarla igual que cualquier
  entero.
  """
  def sincronizar_nulabilidad_campo(schema_context_name, campo) do
    with {:ok, detalle} <- buscar_detalle(schema_context_name, campo) do
      propiedades = detalle.schema_context_properties || %{}
      tipo_str = Map.get(propiedades, "tipo", "string")
      opcional? = Map.get(propiedades, "opcional", false)

      case {tipo_str, nulable_fisica(schema_context_name, campo)} do
        {_tipo, nil} ->
          :ok

        {_tipo, ^opcional?} ->
          :ok

        {_tipo, _distinto} when opcional? ->
          alterar_nulabilidad(schema_context_name, campo, tipo_ecto(tipo_str), construir_opciones(tipo_str, propiedades), true)

        {_tipo, _distinto} ->
          case contar_nulos(schema_context_name, campo) do
            0 ->
              alterar_nulabilidad(schema_context_name, campo, tipo_ecto(tipo_str), construir_opciones(tipo_str, propiedades), false)

            n ->
              {:error, "hay #{n} registro(s) con \"#{campo}\" vacío — no se puede exigir sin completarlos antes"}
          end
      end
    end
  end

  defp nulable_fisica(schema_context_name, campo) do
    %{rows: filas} =
      Repo.query!(
        "select is_nullable from information_schema.columns where table_name = $1 and column_name = $2",
        [schema_context_name, to_string(campo)]
      )

    case filas do
      [["YES"]] -> true
      [["NO"]] -> false
      [] -> nil
    end
  end

  defp contar_nulos(schema_context_name, campo) do
    %{rows: [[n]]} = Repo.query!("select count(*) from #{schema_context_name} where #{campo} is null")
    n
  end

  # Backfill de trn/ulid para un catálogo que se marcó transaccional
  # DESPUÉS de ya haber sido generado (mismo criterio que
  # asegurar_estado_id/1 — no versionado, IF NOT EXISTS, idempotente).
  # Nullable a nivel de columna a propósito: las filas viejas no tienen
  # forma de conseguir un TRN retroactivo sin inventar uno; las nuevas
  # SIEMPRE lo tienen porque MetadataApp.TRN.asignar_si_transaccional/1
  # corre en cada alta — la garantía de la Regla #1 es de aplicación, no
  # de constraint de base.
  defp asegurar_trn(_schema_context_name, %{schema_es_transaccional: false}, _columnas), do: :ok
  defp asegurar_trn(_schema_context_name, nil, _columnas), do: :ok

  defp asegurar_trn(schema_context_name, %{schema_es_transaccional: true}, columnas_actuales) do
    if "trn" not in columnas_actuales do
      Repo.query!("ALTER TABLE #{schema_context_name} ADD COLUMN IF NOT EXISTS trn varchar(23)")
      Repo.query!("CREATE UNIQUE INDEX IF NOT EXISTS #{MetadataApp.TRN.nombre_indice(schema_context_name, "trn")} ON #{schema_context_name} (trn) WHERE trn IS NOT NULL")
    end

    if "ulid" not in columnas_actuales do
      Repo.query!("ALTER TABLE #{schema_context_name} ADD COLUMN IF NOT EXISTS ulid varchar(26)")
      Repo.query!("CREATE UNIQUE INDEX IF NOT EXISTS #{MetadataApp.TRN.nombre_indice(schema_context_name, "ulid")} ON #{schema_context_name} (ulid) WHERE ulid IS NOT NULL")
    end

    :ok
  end

  # NDT (2026-08-31) — mismo criterio de retrofit que asegurar_trn/3
  # arriba: un catálogo YA existente que recién ahora marca
  # requiere_folio: true necesita la columna agregada a mano (ALTER
  # TABLE), no vía la migración de creación (esa ya corrió hace rato).
  defp asegurar_folio(_schema_context_name, %{requiere_folio: false}, _columnas), do: :ok
  defp asegurar_folio(_schema_context_name, %{requiere_folio: nil}, _columnas), do: :ok
  defp asegurar_folio(_schema_context_name, nil, _columnas), do: :ok

  defp asegurar_folio(schema_context_name, %{requiere_folio: true}, columnas_actuales) do
    if "folio" not in columnas_actuales do
      Repo.query!("ALTER TABLE #{schema_context_name} ADD COLUMN IF NOT EXISTS folio varchar(40)")
      Repo.query!("CREATE INDEX IF NOT EXISTS #{schema_context_name}_folio_index ON #{schema_context_name} (folio)")
    end

    :ok
  end

  defp columnas_existentes(schema_context_name) do
    %{rows: filas} =
      Repo.query!("select column_name from information_schema.columns where table_name = $1", [
        schema_context_name
      ])

    Enum.map(filas, fn [nombre] -> nombre end)
  end

  defp agregar_columnas(schema_context_name, campos_nuevos) do
    timestamp = timestamp_utc()

    sufijo =
      campos_nuevos
      |> Enum.map(fn {campo, _, _} -> Macro.camelize(to_string(campo)) end)
      |> Enum.join("")

    modulo_migracion = "Agregar#{sufijo}A#{Macro.camelize(schema_context_name)}#{timestamp}"

    path =
      "priv/repo/migrations/#{timestamp}_agregar_campos_a_#{schema_context_name}_#{timestamp}.exs"

    columnas =
      for {campo, tipo, opciones} <- campos_nuevos do
        columna_migracion_agregar(campo, tipo, opciones)
      end
      |> Enum.join("\n")

    contenido = """
    defmodule MetadataApp.Repo.Migrations.#{modulo_migracion} do
      use Ecto.Migration

      def change do
        alter table(:#{schema_context_name}) do
    #{columnas}
        end
      end
    end
    """

    File.write!(path, contenido)
    migrar()
  end

  # Mismo criterio de nombre único que agregar_columnas/2 y quitar_columna/2
  # (sufijo con timestamp, migración hacia adelante). `modify` (no `add`,
  # esto SIEMPRE es sobre una columna que ya existe) necesita el tipo
  # completo igual que `add` — Ecto arma un solo ALTER TABLE con la cláusula
  # TYPE + la de null; pasarle el mismo tipo/tamaño que ya tiene la columna
  # (derivado de la misma metadata que la creó) hace que la parte de TYPE
  # sea un no-op en Postgres, y lo único que cambia de verdad es la
  # restricción NOT NULL.
  defp alterar_nulabilidad(schema_context_name, campo, tipo, opciones, nulable?) do
    timestamp = timestamp_utc()
    verbo = if nulable?, do: "PermitirNuloEn", else: "ExigirNoNuloEn"
    modulo_migracion = verbo <> Macro.camelize(to_string(campo)) <> Macro.camelize(schema_context_name) <> timestamp
    descripcion = if nulable?, do: "permitir_nulo_en", else: "exigir_no_nulo_en"
    path = "priv/repo/migrations/#{timestamp}_#{descripcion}_#{campo}_#{schema_context_name}_#{timestamp}.exs"

    contenido = """
    defmodule MetadataApp.Repo.Migrations.#{modulo_migracion} do
      use Ecto.Migration

      def change do
        alter table(:#{schema_context_name}) do
    #{modificar_columna_migracion(campo, tipo, opciones, nulable?)}
        end
      end
    end
    """

    File.write!(path, contenido)
    migrar()
    :ok
  end

  defp modificar_columna_migracion(campo, :string, %{texto_largo: true}, nulable?),
    do: "      modify :#{campo}, :text, null: #{nulable?}"

  defp modificar_columna_migracion(campo, :string, opciones, nulable?),
    do: "      modify :#{campo}, :string, size: #{opciones[:longitud] || 255}, null: #{nulable?}"

  defp modificar_columna_migracion(campo, :decimal, %{precision: precision, escala: escala}, nulable?)
       when is_integer(precision) and is_integer(escala),
       do: "      modify :#{campo}, :decimal, precision: #{precision}, scale: #{escala}, null: #{nulable?}"

  defp modificar_columna_migracion(campo, tipo, _opciones, nulable?)
       when tipo in [:integer, :decimal, :boolean, :date, :time],
       do: "      modify :#{campo}, :#{tipo}, null: #{nulable?}"

  # Los registros ya existentes no tienen valor para este campo nuevo — a
  # diferencia de columna_migracion/3 (pensada para CREATE TABLE, tabla
  # vacía, donde todo campo de negocio es obligatorio desde el principio),
  # acá la tabla puede tener millones de filas. Sin un valor por default no
  # hay forma de que Postgres satisfaga NOT NULL en las filas viejas — se
  # degrada a null: true (obligatorio solo desde la aplicación en
  # adelante, ver docs/catalogo-maestro-detalle-requerimientos.md §R13).
  # CON un valor por default constante, en cambio, SÍ se pone null: false
  # real: Postgres 11+ guarda un default constante como metadata del
  # catálogo en vez de reescribir la tabla — instantáneo aunque la tabla
  # tenga millones de filas, sin ventana de bloqueo larga.
  #
  # Una referencia nunca ofrece default (no hay un valor razonable:
  # inventar una FK significaría enganchar a ciegas todas las filas viejas
  # a un mismo registro ajeno) — se mantiene siempre nullable, igual que
  # antes de este cambio.
  defp columna_migracion_agregar(campo, tipo, %{tabla_referenciada: _} = opciones) do
    columna_migracion(campo, tipo, opciones) |> String.replace("null: false", "null: true")
  end

  defp columna_migracion_agregar(campo, tipo, opciones) do
    base = columna_migracion(campo, tipo, opciones)

    case formatear_default(tipo, opciones[:valor_default]) do
      nil -> String.replace(base, "null: false", "null: true")
      literal -> String.replace(base, "null: false", "null: false, default: #{literal}")
    end
  end

  # Devuelve el texto Elixir literal a escribir en la migración, o nil si
  # no hay valor (o no es válido para el tipo — defensa en profundidad:
  # BcMotorLive ya valida esto antes de llegar acá, pero este módulo
  # escribe código fuente a disco que después se COMPILA Y CORRE como
  # migración, así que no confía ciegamente en el caller). string/date
  # usan inspect/1 (siempre produce un literal Elixir escapado, seguro sin
  # importar el contenido); integer/decimal/boolean se validan con regex
  # antes de insertarse SIN comillas — insertar ese texto crudo sin validar
  # sería, en los hechos, ejecutar lo que sea que alguien haya escrito ahí.
  defp formatear_default(_tipo, valor) when valor in [nil, ""], do: nil
  # "hoy"/"ahora" (ver MetaCatalogoGenerico.resolver_valor_default/2) son
  # sentinelas que la APP resuelve en cada alta -- nunca un default de
  # columna real (Postgres rechazaría un default de fecha que sea texto
  # literal). La columna queda nullable, igual que "sin default" (rama de
  # abajo) -- el valor real siempre lo pone forzar_defaults/2, no la BD.
  defp formatear_default(tipo, valor) when tipo in [:date, :time] and valor in ["hoy", "ahora"], do: nil
  defp formatear_default(tipo, valor) when tipo in [:string, :date, :time], do: inspect(valor)
  defp formatear_default(:boolean, valor) when valor in ["true", "false"], do: valor
  defp formatear_default(:boolean, _valor), do: nil

  defp formatear_default(tipo, valor) when tipo in [:integer, :decimal] do
    if Regex.match?(~r/^-?\d+(\.\d+)?$/, valor), do: valor, else: nil
  end

  defp formatear_default(_tipo, _valor), do: nil

  # Sin esto, el módulo recién reescrito en disco queda desactualizado en la
  # sesión BEAM que está corriendo ahora mismo (ej. un mix run de seeds que
  # agrega un campo y en la misma corrida ya quiere usarlo) — fuera de un
  # request HTTP no está Phoenix.CodeReloader para recompilarlo solo. Público
  # (no defp) porque "Compilar motor completo" en BcMotorLive la reusa como
  # paso explícito, además del uso automático de generar/1 en cada campo.
  def recompilar_schema(schema_context_name) do
    Code.compile_file("lib/metadata_app/meta_business_process/catalogos/#{schema_context_name}.ex")
    :ok
  end

  defp buscar_header(schema_context_name) do
    case MetaSchemaContext.obtener_header_por_nombre(schema_context_name) do
      nil -> {:error, :not_found}
      header -> {:ok, header}
    end
  end

  # Repetir el nombre (de la tabla, o de un campo en eliminar_campo/3) en el
  # body es la confirmación — barato de implementar, elimina el borrado
  # accidental por typo o script, y obliga a escribirlo a propósito en vez
  # de copiar/pegar un texto fijo sin leer.
  defp validar_confirmacion(esperado, esperado), do: :ok

  defp validar_confirmacion(_esperado, _confirmacion),
    do: {:error, "el texto de confirmación no coincide con lo que se va a borrar"}

  # Fuerza a haber consultado GET .../impacto antes de borrar: sin conocer
  # la cantidad real de filas, no hay forma de completar este chequeo a
  # ciegas (salvo casualidad en un catálogo vacío).
  defp validar_confirmacion_filas(schema_context_name, confirmar_filas) do
    filas = contar_filas_si_existe(schema_context_name)

    if filas == confirmar_filas do
      :ok
    else
      {:error,
       "confirmar_filas no coincide — el catálogo tiene #{filas} fila(s) ahora mismo. " <>
         "Consultá GET /api/catalogos/#{schema_context_name}/impacto antes de borrar."}
    end
  end

  defp validar_sin_dependientes(schema_context_name) do
    case MetaSchemaContext.listar_dependientes(schema_context_name) do
      [] ->
        :ok

      dependientes ->
        {:error, "catálogo(s) dependientes, borralos primero: #{Enum.join(dependientes, ", ")}"}
    end
  end

  # El sufijo con el timestamp evita que dos migraciones "eliminar_<tabla>"
  # (una por cada regeneración del mismo catálogo) choquen: Ecto exige que el
  # nombre descriptivo del archivo (todo lo que sigue a la versión) sea único
  # en toda la carpeta de migraciones, no solo el número de versión.
  defp crear_migracion_drop(schema_context_name) do
    timestamp = timestamp_utc()
    modulo_migracion = "Eliminar" <> Macro.camelize(schema_context_name) <> timestamp
    path = "priv/repo/migrations/#{timestamp}_eliminar_#{schema_context_name}_#{timestamp}.exs"

    # up/down (no change/0) a propósito: purgar_metadata_por_nombre/1 no es
    # reversible, y esta migración nunca debe "deshacerse" (mismo criterio
    # que el resto del módulo -- nunca se toca la migración de creación).
    #
    # Orden real (encontrado en vivo): DROP TABLE primero, purga de
    # metadata después. Si un catálogo TIENE filas, cada una tiene un
    # estado_id con FK real a meta_schema_estados -- purgar la metadata
    # primero borra esos estados (cascada de header) mientras la tabla
    # todavía existe y los referencia, y Postgres rechaza el DELETE
    # ("<tabla>_estado_id_fkey"). Dropear la tabla primero elimina esas
    # filas (y su referencia) antes de tocar los estados.
    contenido = """
    defmodule MetadataApp.Repo.Migrations.#{modulo_migracion} do
      use Ecto.Migration

      def up do
        drop_if_exists table(:#{schema_context_name})
        # flush/0 obligatorio acá: drop_if_exists (como create/alter) queda
        # ENCOLADO por Ecto, no se ejecuta hasta el final de la migración
        # (o hasta el próximo flush) -- sin esto, purgar_metadata_por_nombre
        # (llamada Elixir normal, corre en el acto) se ejecuta con la tabla
        # todavía física, mismo error de FK que si nunca se hubiera reordenado.
        flush()
        MetadataApp.BusinessProcessBuilder.CatalogoGenerador.purgar_metadata_por_nombre("#{schema_context_name}")
      end

      def down do
        :ok
      end
    end
    """

    File.write!(path, contenido)
  end

  defp borrar_schema_file(schema_context_name) do
    path = "lib/metadata_app/meta_business_process/catalogos/#{schema_context_name}.ex"

    case File.rm(path) do
      :ok -> true
      {:error, _motivo} -> false
    end
  end

  # Bug real encontrado 2026-07-21: eliminar/3 borraba la fila de
  # meta_schema_reglas_codigo (cascada por FK) y el .ex del SCHEMA, pero
  # nunca tocaba lib/.../reglas/<catalogo>/pre.ex|post.ex que "Compilar"
  # escribe a disco — quedaban huérfanos después de un borrado total.
  defp borrar_reglas_dir(schema_context_name) do
    case File.rm_rf(MetaReglasCodigo.ruta_disco_catalogo(schema_context_name)) do
      {:ok, []} -> false
      {:ok, _borrados} -> true
      {:error, _motivo, _ruta} -> false
    end
  end

  # Bug real (encontrado en vivo, roadmap #13): eliminar/4 borraba el .ex
  # y las reglas, pero nunca estos dos -- quedaban huérfanos en disco.
  # `MetaPublicador.armar_bundle/1` los sigue encontrando (File.exists?)
  # aunque el catálogo ya no exista, y el bundle resultante hace que
  # `/app/bin/import_meta` RECREE el catálogo en producción al desplegarlo
  # -- justo lo contrario de lo que pide un borrado.
  defp borrar_export_meta(schema_context_name) do
    File.rm("priv/repo/catalogos/#{schema_context_name}.meta.json")
    File.rm("priv/repo/catalogos/#{schema_context_name}.motor.json")
    :ok
  end

  defp migrar do
    # En Windows, sin symlinks, Mix copia priv/ a _build/ y Ecto.Migrator
    # resuelve el path por default contra esa copia (desactualizada justo
    # después de escribir una migración nueva). Se apunta al path fuente
    # real para leer siempre el archivo recién escrito.
    path = Path.join(File.cwd!(), "priv/repo/migrations")

    Ecto.Migrator.with_repo(MetadataApp.Repo, fn repo ->
      Ecto.Migrator.run(repo, path, :up, all: true)
    end)
  end

  defp validar_tabla(tabla) when byte_size(tabla) <= @tabla_longitud_maxima, do: :ok

  defp validar_tabla(tabla),
    do:
      {:error,
       "tabla=#{tabla} excede #{@tabla_longitud_maxima} caracteres — Postgres trunca identificadores largos y podría colisionar con otro catálogo"}

  # Nombre determinista y corto del índice único del catálogo — una sola
  # fuente de verdad, usada tanto por la migración como por el changeset
  # generado (MetaCatalogoGenerico), para que nunca puedan desincronizarse.
  def nombre_indice_unico(tabla), do: "#{tabla}_unico_index"

  # Valida que todo detalle tipo "referencia" apunte a un catálogo ya
  # registrado (no se puede crear una FK a una tabla que no existe todavía).
  # Map.get en vez de Map.fetch!: un detalle "referencia" sin "catalogo"
  # configurado (bug real que ya pasó — el modal "Agregar campo" ofrecía el
  # tipo sin ningún selector para elegir a qué apuntaba) tiene que reportarse
  # como error de validación, no reventar el proceso con un KeyError.
  defp validar_referencias(detalles) do
    catalogos_referencia =
      detalles
      |> Enum.filter(&(Map.get(&1.schema_context_properties || %{}, "tipo") == "referencia"))
      |> Enum.map(&Map.get(&1.schema_context_properties, "catalogo"))
      |> Enum.uniq()

    if Enum.any?(catalogos_referencia, &(&1 in [nil, ""])) do
      {:error, "hay un campo tipo 'referencia' sin catálogo destino configurado"}
    else
      # Empresa/Branch/InventoryLocation/SalesUnit (MetaSchemaContext.catalogo_sistema/1)
      # nunca van a tener meta_schema_header -- no son catálogos BPB, pero
      # son destinos válidos igual (2026-08-20).
      case Enum.reject(catalogos_referencia, &(MetaSchemaContext.obtener_header_por_nombre(&1) || MetaSchemaContext.catalogo_sistema(&1))) do
        [] -> :ok
        faltantes -> {:error, "catálogo(s) referenciados inexistentes: #{Enum.join(faltantes, ", ")}"}
      end
    end
  end

  # Un catálogo detalle necesita la tabla física del maestro ya creada
  # (para poder referenciarla en `references(:tabla_maestro)`) — mismo
  # motivo que validar_referencias/1 para campos tipo "referencia".
  defp validar_maestro_generado(nil), do: :ok
  defp validar_maestro_generado(%{schema_encabezado_id: nil}), do: :ok

  defp validar_maestro_generado(%{schema_encabezado_id: id}) do
    maestro = MetaSchemaContext.obtener_header!(id)

    if File.exists?("lib/metadata_app/meta_business_process/catalogos/#{maestro.schema_context_name}.ex") do
      :ok
    else
      {:error, "el catálogo maestro '#{maestro.schema_context_name}' todavía no está generado"}
    end
  end

  defp tipo_ecto("integer"), do: :integer
  defp tipo_ecto("decimal"), do: :decimal
  defp tipo_ecto("boolean"), do: :boolean
  defp tipo_ecto("date"), do: :date
  defp tipo_ecto("hora"), do: :time
  defp tipo_ecto("enum"), do: :string
  defp tipo_ecto("referencia"), do: :integer
  # "texto_largo" (Diseñador de campos, Paso 1) no es un tipo Ecto
  # distinto — Ecto no diferencia varchar/text al castear, ambos son
  # String.t() de punta a punta. La única diferencia real es la columna
  # física (ver construir_opciones/2 y columna_migracion/3, que usan la
  # marca :texto_largo en `opciones` para elegir `:text` en la migración
  # en vez de `:string, size: N`).
  defp tipo_ecto(_string_u_otro), do: :string

  defp construir_opciones("string", propiedades) do
    base_opciones(propiedades)
    |> Map.put(:longitud, Map.get(propiedades, "longitud", 255))
    |> Map.put(:formato, Map.get(propiedades, "formato"))
    |> Map.put(:longitud_minima, Map.get(propiedades, "longitud_minima"))
    |> Map.put(:transformacion, Map.get(propiedades, "transformacion"))
  end

  # "Texto largo": sin límite MÁXIMO de longitud ni regex de formato (es
  # para comentarios/descripciones libres, no para un dato con patrón) —
  # la columna física es :text, no varchar(255) (ver columna_migracion/3).
  # Sí admite longitud mínima y transformación, igual que "string".
  defp construir_opciones("texto_largo", propiedades) do
    base_opciones(propiedades)
    |> Map.put(:texto_largo, true)
    |> Map.put(:longitud_minima, Map.get(propiedades, "longitud_minima"))
    |> Map.put(:transformacion, Map.get(propiedades, "transformacion"))
  end

  defp construir_opciones("integer", propiedades) do
    base_opciones(propiedades)
    |> Map.put(:minimo, Map.get(propiedades, "minimo"))
    |> Map.put(:maximo, Map.get(propiedades, "maximo"))
  end

  defp construir_opciones("decimal", propiedades) do
    base_opciones(propiedades)
    |> Map.put(:minimo, Map.get(propiedades, "minimo"))
    |> Map.put(:maximo, Map.get(propiedades, "maximo"))
    |> Map.put(:precision, Map.get(propiedades, "precision"))
    |> Map.put(:escala, Map.get(propiedades, "escala"))
  end

  # "valores" (compile-time, ver validate_inclusion en
  # MetaCatalogoGenerico.aplicar_valores/3) tiene que ser la lista de
  # valores REALMENTE guardables — para una Lista "Mapeada" (Diseñador de
  # campos: valores => [%{"valor"=>, "descripcion"=>}, ...]) eso es el
  # lado "valor" (el código), nunca la descripción; para una Lista
  # "Simple" (lista de string) el texto mismo ya es el valor guardable.
  defp construir_opciones("enum", propiedades) do
    base_opciones(propiedades)
    |> Map.put(:valores, valores_guardables(Map.fetch!(propiedades, "valores")))
  end

  defp construir_opciones("referencia", propiedades) do
    catalogo_ref = Map.fetch!(propiedades, "catalogo")

    # Tabla de sistema (Empresa/Branch/InventoryLocation/SalesUnit, ver
    # MetaSchemaContext.catalogo_sistema/1): "catalogo_ref" YA es el
    # nombre real de la tabla física, no hay header que buscar.
    tabla_referenciada =
      case MetaSchemaContext.catalogo_sistema(catalogo_ref) do
        nil -> MetaSchemaContext.obtener_header_por_nombre(catalogo_ref).schema_context_name
        _sistema -> catalogo_ref
      end

    base_opciones(propiedades)
    |> Map.put(:tabla_referenciada, tabla_referenciada)
  end

  defp construir_opciones(_tipo, propiedades), do: base_opciones(propiedades)

  defp valores_guardables(valores) do
    Enum.map(valores, fn
      %{"valor" => v} -> v
      v when is_binary(v) -> v
    end)
  end

  defp base_opciones(propiedades) do
    opcional = Map.get(propiedades, "opcional", false)
    base = %{opcional: opcional, valor_default: Map.get(propiedades, "valor_default")}

    case Map.get(propiedades, "unico_en") do
      %{"tabla" => tabla, "campo" => campo_externo} -> Map.put(base, :unico_en, {tabla, campo_externo})
      _ -> base
    end
  end

  defp columna_migracion(campo, _tipo, %{tabla_referenciada: tabla_ref} = opciones),
    do: "      add :#{campo}, references(:#{tabla_ref}), null: #{nulo?(opciones)}"

  defp columna_migracion(campo, :string, %{texto_largo: true} = opciones),
    do: "      add :#{campo}, :text, null: #{nulo?(opciones)}"

  defp columna_migracion(campo, :string, opciones),
    do:
      "      add :#{campo}, :string, size: #{opciones[:longitud] || 255}, null: #{nulo?(opciones)}"

  defp columna_migracion(campo, :decimal, %{precision: precision, escala: escala} = opciones)
       when is_integer(precision) and is_integer(escala),
       do:
         "      add :#{campo}, :decimal, precision: #{precision}, scale: #{escala}, null: #{nulo?(opciones)}"

  defp columna_migracion(campo, tipo, opciones)
       when tipo in [:integer, :decimal, :boolean, :date, :time],
       do: "      add :#{campo}, :#{tipo}, null: #{nulo?(opciones)}"

  # "opcional" (opt-in en schema_context_properties) es la única forma de que
  # un campo de negocio no sea null: false — por default todo campo es
  # obligatorio, como siempre fue.
  defp nulo?(opciones), do: opciones[:opcional] == true

  # Mismo motivo que en crear_migracion_drop/1: el sufijo hace único el
  # nombre descriptivo aunque el catálogo se regenere varias veces.
  # `header` (agregado 2026-07-21, TRN Fase 1) decide si se agregan las
  # columnas trn/ulid — nil o schema_es_transaccional: false = catálogo
  # normal, sin cambios respecto de antes.
  defp crear_migracion(schema_context_name, campos, header) do
    timestamp = timestamp_utc()
    modulo_migracion = "Crear" <> Macro.camelize(schema_context_name) <> timestamp
    path = "priv/repo/migrations/#{timestamp}_crear_#{schema_context_name}_#{timestamp}.exs"

    columnas =
      for {campo, tipo, opciones} <- campos do
        columna_migracion(campo, tipo, opciones)
      end
      |> Enum.join("\n")

    # Catálogo Maestro-Detalle (R3): un catálogo detalle SIEMPRE incluye
    # :encabezado_id en su índice único de negocio — sin esto, la misma
    # combinación de valores quedaba prohibida para SIEMPRE en TODA la
    # tabla, aunque fuera de dos encabezados (maestros) distintos, que es
    # exactamente el caso normal (bug real: dos empleados no podían tener
    # el mismo rol+fecha, dos comandos no podían repetir contacto/teléfono/
    # email/owner, etc.). El nombre del índice/constraint NO cambia — el
    # unique_constraint/3 del changeset generado solo matchea por nombre,
    # no por columnas, así que sigue funcionando sin tocar nada ahí.
    nombres_campos_negocio = Enum.map(campos, fn {campo, _, _} -> ":#{campo}" end)

    nombres_campos =
      case header do
        %{schema_encabezado_id: id} when not is_nil(id) -> Enum.join([":encabezado_id" | nombres_campos_negocio], ", ")
        _ -> Enum.join(nombres_campos_negocio, ", ")
      end

    nombre_indice = nombre_indice_unico(schema_context_name)
    {columnas_trn, indices_trn} = columnas_trn(schema_context_name, header)
    {columnas_folio, indices_folio} = columnas_folio(schema_context_name, header)
    {columnas_encab, indices_encab} = columnas_encabezado_detalle(schema_context_name, header)
    columnas_alcance = columnas_alcance(header)

    contenido = """
    defmodule MetadataApp.Repo.Migrations.#{modulo_migracion} do
      use Ecto.Migration

      def change do
        create table(:#{schema_context_name}) do
    #{columnas}

          add :insert_guid, :string, size: 32, null: false
          add :update_guid, :string, size: 32, null: true
          add :delete_guid, :string, size: 32, null: true

          add :estado_id, references(:meta_schema_estados), null: true

          add :fecha_registro, :utc_datetime, null: true
    #{columnas_trn}#{columnas_folio}#{columnas_encab}#{columnas_alcance}
        end

        create unique_index(:#{schema_context_name}, [#{nombres_campos}], name: :#{nombre_indice})
    #{indices_trn}#{indices_folio}#{indices_encab}
      end
    end
    """

    File.write!(path, contenido)
  end

  # PrettyCore TRN (Fase 1) — trn/ulid solo se agregan si el header está
  # marcado schema_es_transaccional. Nullable a nivel columna a propósito
  # (mismo criterio que estado_id): la garantía de "siempre tiene TRN" es
  # de aplicación (MetadataApp.TRN corre en cada alta), no de constraint.
  defp columnas_trn(_schema_context_name, nil), do: {"", ""}
  defp columnas_trn(_schema_context_name, %{schema_es_transaccional: false}), do: {"", ""}

  defp columnas_trn(schema_context_name, %{schema_es_transaccional: true}) do
    columnas = """

          add :trn, :string, size: 23, null: true
          add :ulid, :string, size: 26, null: true
    """

    indices = """
        create unique_index(:#{schema_context_name}, [:trn], name: :#{MetadataApp.TRN.nombre_indice(schema_context_name, "trn")})
        create unique_index(:#{schema_context_name}, [:ulid], name: :#{MetadataApp.TRN.nombre_indice(schema_context_name, "ulid")})
    """

    {columnas, indices}
  end

  # NDT (2026-08-31) — folio solo se agrega si el header marcó
  # requiere_folio. Nullable a nivel columna (mismo criterio que trn/ulid
  # arriba): la garantía es de aplicación (MetadataApp.Folio corre en
  # cada alta), no de constraint de base. Sin índice único acá a
  # propósito -- la unicidad real es (numbering_profile_id, folio) en
  # ndt_numbering_audits (dos catálogos podrían compartir la misma
  # cadena de folio en teoría, aunque en la práctica cada perfil apunta
  # a un solo meta_schema_header_id); esto es solo un índice de lectura.
  defp columnas_folio(_schema_context_name, nil), do: {"", ""}
  defp columnas_folio(_schema_context_name, %{requiere_folio: false}), do: {"", ""}
  defp columnas_folio(_schema_context_name, %{requiere_folio: nil}), do: {"", ""}

  defp columnas_folio(schema_context_name, %{requiere_folio: true}) do
    columnas = """

          add :folio, :string, size: 40, null: true
    """

    indices = """
        create index(:#{schema_context_name}, [:folio])
    """

    {columnas, indices}
  end

  # Catálogo Maestro-Detalle (Fase 1, ver docs/catalogo-maestro-detalle-requerimientos.md
  # R1/R14) — encabezado_id/renglon_id solo se agregan si el header es
  # detalle de otro. `encabezado_id` referencia la FILA del maestro (no
  # solo el catálogo); `renglon_id` es un contador por maestro, lo asigna
  # `MetadataApp.Renglones` en cada alta (nunca un SERIAL de Postgres,
  # que sería global). Índice único compuesto, mismo criterio que
  # nombre_indice_unico/1.
  defp columnas_encabezado_detalle(_schema_context_name, nil), do: {"", ""}
  defp columnas_encabezado_detalle(_schema_context_name, %{schema_encabezado_id: nil}), do: {"", ""}

  defp columnas_encabezado_detalle(schema_context_name, %{schema_encabezado_id: encabezado_id}) do
    maestro = MetaSchemaContext.obtener_header!(encabezado_id)

    columnas = """

          add :encabezado_id, references(:#{maestro.schema_context_name}), null: false
          add :renglon_id, :integer, null: false
    """

    indices = """
        create unique_index(:#{schema_context_name}, [:encabezado_id, :renglon_id], name: :#{nombre_indice_renglon(schema_context_name)})
    """

    {columnas, indices}
  end

  @doc "Nombre determinista del índice único (encabezado_id, renglon_id) de un catálogo detalle — misma fuente de verdad para la migración y para MetadataApp.Renglones."
  def nombre_indice_renglon(tabla), do: "#{tabla}_encabezado_renglon_unico_index"

  # Fase 9 del modelo de Alcance de Datos (2026-08-11) — las 4 dimensiones
  # (branch_id/sales_unit_id/inventory_id/creado_por_id) solo se agregan a
  # un catálogo NUEVO si ya nació con alcance_habilitado: true (caso raro
  # -- hoy el toggle de BcMotorLive solo se prende DESPUÉS de crear el
  # catálogo). El caso normal -- prender el toggle sobre un catálogo YA
  # generado -- lo cubre asegurar_columnas_alcance/1 más abajo, vía ALTER
  # TABLE. Nullable a nivel columna a propósito (mismo criterio que
  # estado_id/trn): filas viejas nunca tuvieron estos datos, no hay forma
  # de inferirlos retroactivos salvo el backfill best-effort de
  # AlcanceBackfill.backfillear_creado_por/1 (creado_por_id únicamente).
  # SIN `references(...)` a propósito (encontrado en vivo, Fase 9): un FK
  # nuevo exige que Postgres tome lock también sobre la tabla REFERENCIADA
  # (meta_schema_branch/sales_unit/inventory_location/usuario), y esas
  # tablas las tocan decenas de tests concurrentes del propio modelo de
  # Alcance de Datos -- causaba deadlocks reales (40P01) bajo carga async,
  # sin importar qué catálogo dedicado se usara del otro lado. La
  # integridad referencial ya la garantiza CatalogoGenerico en la capa de
  # aplicación (branch_id solo puede ser uno de scope.branches_permitidos,
  # que a su vez solo contiene ids de branches reales) -- un FK físico acá
  # sería defensa en profundidad, no la única barrera.
  defp columnas_alcance(%{alcance_habilitado: true}) do
    """

          add :branch_id, :integer, null: true
          add :sales_unit_id, :integer, null: true
          add :inventory_id, :integer, null: true
          add :creado_por_id, :integer, null: true
    """
  end

  defp columnas_alcance(_header), do: ""

  # Contraparte de columnas_alcance/1 para un catálogo YA generado --
  # llamada desde generar/1 en cada regeneración (idempotente, IF NOT
  # EXISTS, mismo patrón que asegurar_estado_id/1). Es el camino real: el
  # toggle "Alcance de datos" de BcMotorLive prende alcance_habilitado y
  # dispara CatalogoGenerador.generar/1, que pasa por acá y agrega las 4
  # columnas físicas antes de que asegurar_campos_nuevos/1 regenere el
  # ".ex" con `alcance: true` (ver MetaCatalogoGenerico.alcance_field_asts/1).
  # No-op si el catálogo no tiene alcance_habilitado (incluye el caso
  # "todavía no existe el header", defensivo). Sin REFERENCES -- ver la
  # nota de columnas_alcance/1 arriba (deadlocks reales con FK).
  defp asegurar_columnas_alcance(schema_context_name) do
    case MetaSchemaContext.obtener_header_por_nombre(schema_context_name) do
      %{alcance_habilitado: true} ->
        Repo.query!("ALTER TABLE #{schema_context_name} ADD COLUMN IF NOT EXISTS branch_id integer")
        Repo.query!("ALTER TABLE #{schema_context_name} ADD COLUMN IF NOT EXISTS sales_unit_id integer")
        Repo.query!("ALTER TABLE #{schema_context_name} ADD COLUMN IF NOT EXISTS inventory_id integer")
        Repo.query!("ALTER TABLE #{schema_context_name} ADD COLUMN IF NOT EXISTS creado_por_id integer")
        :ok

      _ ->
        :ok
    end
  end

  defp crear_schema(schema_context_name, modulo, campos, header) do
    path = "lib/metadata_app/meta_business_process/catalogos/#{schema_context_name}.ex"

    campos_literal =
      campos
      |> Enum.map(fn {campo, tipo, opciones} ->
        "{:#{campo}, :#{tipo}, #{formatear_opciones(opciones)}}"
      end)
      |> Enum.join(", ")

    opciones_trn = opciones_trn_use(header)
    opciones_folio = opciones_folio_use(header)
    opciones_detalle = opciones_detalle_use(header)
    opciones_alcance = opciones_alcance_use(header)

    contenido = """
    defmodule MetadataApp.MetaBusinessProcess.Catalogos.#{modulo} do
      use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "#{schema_context_name}", campos: [#{campos_literal}]#{opciones_trn}#{opciones_folio}#{opciones_detalle}#{opciones_alcance}
    end
    """

    File.write!(path, contenido)
  end

  # inspect(mapa) NO alcanza acá -- el orden en que imprime las llaves de un
  # mapa depende del orden interno de los átomos en ESA instancia de la VM
  # (no es alfabético ni estable entre corridas distintas, confirmado real:
  # el mismo código, corrido en dev local vs. el runner de CI, generaba
  # ".ex" con las llaves en OTRO orden para el mismo contenido lógico —
  # drift-check de ci.yml lo marcaba como "sin commitear" en un loop
  # infinito). Enum.sort/1 sobre átomos sí es alfabético y estable siempre
  # -- armar el texto a mano desde una lista ya ordenada garantiza el mismo
  # archivo byte a byte sin importar en qué VM/máquina se generó.
  defp formatear_opciones(opciones) do
    cuerpo =
      opciones
      |> Enum.sort_by(fn {clave, _valor} -> clave end)
      |> Enum.map(fn {clave, valor} -> "#{clave}: #{inspect(valor, limit: :infinity, printable_limit: :infinity)}" end)
      |> Enum.join(", ")

    "%{#{cuerpo}}"
  end

  defp opciones_trn_use(%{schema_es_transaccional: true, codigo_trn: codigo}), do: ", transaccional: true, codigo_trn: #{inspect(codigo)}"
  defp opciones_trn_use(_header), do: ""

  defp opciones_folio_use(%{requiere_folio: true}), do: ", folio: true"
  defp opciones_folio_use(_header), do: ""

  defp opciones_detalle_use(%{schema_encabezado_id: id}) when not is_nil(id) do
    maestro = MetaSchemaContext.obtener_header!(id)
    ", detalle_de: #{inspect(maestro.schema_context_name)}"
  end

  defp opciones_detalle_use(_header), do: ""

  defp opciones_alcance_use(%{alcance_habilitado: true}), do: ", alcance: true"
  defp opciones_alcance_use(_header), do: ""

  # Con solo segundos de resolución, dos catálogos creados/borrados en el
  # mismo segundo generan el mismo número de versión — Ecto trata la segunda
  # migración como "ya aplicada" y la salta en silencio, sin correr su
  # contenido. Se agregan milisegundos para que eso no vuelva a pasar.
  # Bug real (roadmap #13, encontrado en vivo 2026-08-14): esto ANTES
  # devolvía 17 dígitos (14 de fecha + 3 de milisegundos, para no chocar
  # si el generador arma dos migraciones en el mismo segundo). Ecto
  # ordena las migraciones por el ENTERO completo de la versión, no por
  # fecha real -- un número de 17 dígitos siempre ordena después que
  # cualquiera de 14, sin importar la fecha, así que una migración
  # generada (17 dígitos) de una catálogo podía terminar corriendo
  # DESPUÉS de una migración escrita a mano (14 dígitos) de fecha
  # posterior real -- nunca importa en un deploy normal (la de creación
  # ya corrió hace tiempo), pero migrar una base 100% vacía de una sola
  # pasada mezclaba ambos formatos fuera de orden real (confirmado en
  # vivo contra pty_gasto_diario: "agregar_trn" corría antes que "crear").
  #
  # Ahora devuelve 14 dígitos, el mismo formato que Ecto usa para
  # cualquier migración escrita a mano -- mismo espacio numérico, mismo
  # criterio de orden. La colisión de mismo segundo (el motivo original
  # de los milisegundos) se resuelve avanzando un segundo hasta encontrar
  # un valor que todavía no tenga archivo en priv/repo/migrations/, en
  # vez de agregar dígitos que rompen la comparación.
  defp timestamp_utc do
    :calendar.universal_time() |> desambiguar_timestamp()
  end

  # +1 segundo con aritmética de calendario real (no +1 al entero
  # formateado) -- así un choque a las 23:59:59 avanza al minuto/hora/día
  # siguiente como corresponde, en vez de generar un "...60" que no es un
  # instante real (Ecto no lo valida como fecha, pero no hay motivo para
  # dejar una versión con pinta de inválida cuando avanzar el calendario
  # de verdad es igual de simple).
  defp desambiguar_timestamp(data_hora) do
    candidato = formatear_timestamp(data_hora)

    if Path.wildcard("priv/repo/migrations/#{candidato}_*.exs") == [] do
      candidato
    else
      data_hora
      |> :calendar.datetime_to_gregorian_seconds()
      |> Kernel.+(1)
      |> :calendar.gregorian_seconds_to_datetime()
      |> desambiguar_timestamp()
    end
  end

  defp formatear_timestamp({{y, mo, d}, {h, mi, s}}) do
    [y, mo, d, h, mi, s]
    |> Enum.zip([4, 2, 2, 2, 2, 2])
    |> Enum.map(fn {n, len} -> n |> Integer.to_string() |> String.pad_leading(len, "0") end)
    |> Enum.join()
  end
end
