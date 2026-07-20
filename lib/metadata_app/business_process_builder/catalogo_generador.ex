defmodule MetadataApp.BusinessProcessBuilder.CatalogoGenerador do
  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.MetaEstadosAdmin

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

    if File.exists?(schema_path) do
      asegurar_estado_id(schema_context_name)
      asegurar_campos_nuevos(schema_context_name)
      {:ok, %{tabla: schema_context_name, ya_existia: true}}
    else
      detalles =
        schema_context_name
        |> MetaSchemaContext.listar_detalles()
        |> Enum.reject(&(&1.schema_context_field == "id"))

      case detalles do
        [] ->
          {:error,
           "No hay metadata en meta_schema_detail para #{schema_context_name} (aparte de 'id')."}

        detalles ->
          with :ok <- validar_tabla(schema_context_name),
               :ok <- validar_referencias(detalles) do
            campos =
              for detalle <- detalles do
                propiedades = detalle.schema_context_properties || %{}
                tipo_str = Map.get(propiedades, "tipo", "string")
                tipo = tipo_ecto(tipo_str)
                opciones = construir_opciones(tipo_str, propiedades)
                {detalle.schema_context_field, tipo, opciones}
              end

            modulo = Macro.camelize(schema_context_name)

            crear_migracion(schema_context_name, campos)
            crear_schema(schema_context_name, modulo, campos)
            migrar()
            recompilar_schema(schema_context_name)

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
      filas = Repo.aggregate(from(t in schema_context_name), :count)
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
  def eliminar(schema_context_name, confirmar_tabla, confirmar_filas) do
    with {:ok, header} <- buscar_header(schema_context_name),
         :ok <- validar_confirmacion(schema_context_name, confirmar_tabla),
         :ok <- validar_confirmacion_filas(schema_context_name, confirmar_filas),
         :ok <- validar_sin_dependientes(schema_context_name) do
      crear_migracion_drop(schema_context_name)
      migrar()
      MetaEstadosAdmin.purgar_historial(header.id)

      with :ok <- MetaSchemaContext.eliminar_header(header) do
        archivo_eliminado? = borrar_schema_file(schema_context_name)
        {:ok, %{tabla: schema_context_name, archivo_eliminado: archivo_eliminado?}}
      end
    end
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

  # Quita un campo de un catálogo YA generado: soft-delete del Detail +
  # DROP COLUMN real (migración hacia adelante, mismo criterio que
  # crear_migracion_drop/1 — nunca se toca la migración de creación) +
  # regenera el schema .ex sin el campo. confirmar_campo repite el mismo
  # criterio de validar_confirmacion/2 que ya usa eliminar/3 (escribir el
  # nombre exacto, no una frase fija) — acá alcanza con el nombre del campo
  # solo (no hace falta confirmar_filas como en el borrado total: esto
  # pierde una columna, no el catálogo entero).
  def eliminar_campo(schema_context_name, campo, confirmar_campo) do
    with {:ok, _header} <- buscar_header(schema_context_name),
         :ok <- validar_confirmacion(campo, confirmar_campo),
         {:ok, detalle} <- buscar_detalle(schema_context_name, campo) do
      MetaSchemaContext.eliminar_detalle(detalle)
      quitar_columna(schema_context_name, campo)
      asegurar_campos_nuevos(schema_context_name)
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

  # Agrega al catálogo YA generado los campos de meta_schema_detail que
  # todavía no son columnas físicas de la tabla — permite extender un
  # catálogo existente (ej. sumarle un campo nuevo) sin borrar y recrear
  # todo. No es una migración versionada por el mismo motivo que
  # asegurar_estado_id/1 (timestamps de 17 dígitos de este generador ordenan
  # siempre después que cualquier migración escrita a mano de 14).
  defp asegurar_campos_nuevos(schema_context_name) do
    detalles =
      schema_context_name
      |> MetaSchemaContext.listar_detalles()
      |> Enum.reject(&(&1.schema_context_field == "id"))

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

    # Siempre regenera el schema (no solo cuando hay columnas nuevas): así
    # también recoge cambios de propiedades en campos que ya existían como
    # columna (ej. marcar uno como "opcional" después de agregarlo). Barato
    # e idempotente — sobreescribe el mismo contenido si nada cambió.
    modulo = Macro.camelize(schema_context_name)
    crear_schema(schema_context_name, modulo, campos)
    recompilar_schema(schema_context_name)
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
        # Los registros ya existentes no tienen valor para este campo nuevo,
        # así que acá SIEMPRE es null: true, a diferencia de columna_migracion/3
        # (pensada para CREATE TABLE, donde todo campo de negocio es
        # obligatorio desde el principio).
        columna_migracion(campo, tipo, opciones) |> String.replace("null: false", "null: true")
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

  # Sin esto, el módulo recién reescrito en disco queda desactualizado en la
  # sesión BEAM que está corriendo ahora mismo (ej. un mix run de seeds que
  # agrega un campo y en la misma corrida ya quiere usarlo) — fuera de un
  # request HTTP no está Phoenix.CodeReloader para recompilarlo solo.
  defp recompilar_schema(schema_context_name) do
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
    filas = Repo.aggregate(from(t in schema_context_name), :count)

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

    contenido = """
    defmodule MetadataApp.Repo.Migrations.#{modulo_migracion} do
      use Ecto.Migration

      def change do
        drop table(:#{schema_context_name})
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
      case Enum.reject(catalogos_referencia, &MetaSchemaContext.obtener_header_por_nombre/1) do
        [] -> :ok
        faltantes -> {:error, "catálogo(s) referenciados inexistentes: #{Enum.join(faltantes, ", ")}"}
      end
    end
  end

  defp tipo_ecto("integer"), do: :integer
  defp tipo_ecto("decimal"), do: :decimal
  defp tipo_ecto("boolean"), do: :boolean
  defp tipo_ecto("date"), do: :date
  defp tipo_ecto("enum"), do: :string
  defp tipo_ecto("referencia"), do: :integer
  defp tipo_ecto(_string_u_otro), do: :string

  defp construir_opciones("string", propiedades) do
    base_opciones(propiedades)
    |> Map.put(:longitud, Map.get(propiedades, "longitud", 255))
    |> Map.put(:formato, Map.get(propiedades, "formato"))
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

  defp construir_opciones("enum", propiedades) do
    base_opciones(propiedades)
    |> Map.put(:valores, Map.fetch!(propiedades, "valores"))
  end

  defp construir_opciones("referencia", propiedades) do
    catalogo_ref = Map.fetch!(propiedades, "catalogo")
    header_ref = MetaSchemaContext.obtener_header_por_nombre(catalogo_ref)

    base_opciones(propiedades)
    |> Map.put(:tabla_referenciada, header_ref.schema_context_name)
  end

  defp construir_opciones(_tipo, propiedades), do: base_opciones(propiedades)

  defp base_opciones(propiedades) do
    opcional = Map.get(propiedades, "opcional", false)

    case Map.get(propiedades, "unico_en") do
      %{"tabla" => tabla, "campo" => campo_externo} ->
        %{unico_en: {tabla, campo_externo}, opcional: opcional}

      _ ->
        %{opcional: opcional}
    end
  end

  defp columna_migracion(campo, _tipo, %{tabla_referenciada: tabla_ref}),
    do: "      add :#{campo}, references(:#{tabla_ref}), null: false"

  defp columna_migracion(campo, :string, opciones),
    do:
      "      add :#{campo}, :string, size: #{opciones[:longitud] || 255}, null: #{nulo?(opciones)}"

  defp columna_migracion(campo, :decimal, %{precision: precision, escala: escala} = opciones)
       when is_integer(precision) and is_integer(escala),
       do:
         "      add :#{campo}, :decimal, precision: #{precision}, scale: #{escala}, null: #{nulo?(opciones)}"

  defp columna_migracion(campo, tipo, opciones)
       when tipo in [:integer, :decimal, :boolean, :date],
       do: "      add :#{campo}, :#{tipo}, null: #{nulo?(opciones)}"

  # "opcional" (opt-in en schema_context_properties) es la única forma de que
  # un campo de negocio no sea null: false — por default todo campo es
  # obligatorio, como siempre fue.
  defp nulo?(opciones), do: opciones[:opcional] == true

  # Mismo motivo que en crear_migracion_drop/1: el sufijo hace único el
  # nombre descriptivo aunque el catálogo se regenere varias veces.
  defp crear_migracion(schema_context_name, campos) do
    timestamp = timestamp_utc()
    modulo_migracion = "Crear" <> Macro.camelize(schema_context_name) <> timestamp
    path = "priv/repo/migrations/#{timestamp}_crear_#{schema_context_name}_#{timestamp}.exs"

    columnas =
      for {campo, tipo, opciones} <- campos do
        columna_migracion(campo, tipo, opciones)
      end
      |> Enum.join("\n")

    nombres_campos = Enum.map(campos, fn {campo, _, _} -> ":#{campo}" end) |> Enum.join(", ")
    nombre_indice = nombre_indice_unico(schema_context_name)

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
        end

        create unique_index(:#{schema_context_name}, [#{nombres_campos}], name: :#{nombre_indice})
      end
    end
    """

    File.write!(path, contenido)
  end

  defp crear_schema(schema_context_name, modulo, campos) do
    path = "lib/metadata_app/meta_business_process/catalogos/#{schema_context_name}.ex"

    campos_literal =
      campos
      |> Enum.map(fn {campo, tipo, opciones} ->
        "{:#{campo}, :#{tipo}, #{inspect(opciones, limit: :infinity, printable_limit: :infinity)}}"
      end)
      |> Enum.join(", ")

    contenido = """
    defmodule MetadataApp.MetaBusinessProcess.Catalogos.#{modulo} do
      use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico, tabla: "#{schema_context_name}", campos: [#{campos_literal}]
    end
    """

    File.write!(path, contenido)
  end

  # Con solo segundos de resolución, dos catálogos creados/borrados en el
  # mismo segundo generan el mismo número de versión — Ecto trata la segunda
  # migración como "ya aplicada" y la salta en silencio, sin correr su
  # contenido. Se agregan milisegundos para que eso no vuelva a pasar.
  defp timestamp_utc do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    ms =
      :erlang.system_time(:millisecond)
      |> rem(1000)
      |> Integer.to_string()
      |> String.pad_leading(3, "0")

    [y, mo, d, h, mi, s]
    |> Enum.zip([4, 2, 2, 2, 2, 2])
    |> Enum.map(fn {n, len} -> n |> Integer.to_string() |> String.pad_leading(len, "0") end)
    |> Enum.join()
    |> Kernel.<>(ms)
  end
end
