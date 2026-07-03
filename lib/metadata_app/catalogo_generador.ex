defmodule MetadataApp.CatalogoGenerador do
  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchemaContext

  # Genera migración y schema para schema_context_name a partir de lo
  # registrado en meta_schema_detail y corre la migración. Si el catálogo ya
  # existe (schema ya generado antes), no hace nada — es idempotente.
  # Postgres trunca (sin error) identificadores de más de 63 bytes. El índice
  # único del catálogo se nombra "<schema_context_name>_unico_index"; se deja
  # margen para ese sufijo y para nombres de constraint que Ecto derive.
  @tabla_longitud_maxima 50

  def generar(schema_context_name) do
    schema_path = "lib/metadata_app/catalogos/#{schema_context_name}.ex"

    if File.exists?(schema_path) do
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

            {:ok, %{tabla: schema_context_name, modulo: modulo, ya_existia: false}}
          end
      end
    end
  end

  # Vista previa del impacto de borrar un catálogo: cuántas filas se
  # perderían y qué otros catálogos lo referencian (y por lo tanto bloquean
  # el borrado). No modifica nada.
  def impacto(schema_context_name) do
    with {:ok, _header} <- buscar_header(schema_context_name) do
      filas = Repo.aggregate(from(t in schema_context_name), :count)
      dependientes = MetaSchemaContext.listar_dependientes(schema_context_name)

      {:ok, %{tabla: schema_context_name, filas: filas, dependientes: dependientes}}
    end
  end

  # Borrado total e irreversible de un catálogo: tabla, Header (sus Detalles
  # se van en cascada por FK) y archivo de schema. Nunca hace rollback de la
  # migración de creación (el orden de versiones la hace frágil) — en cambio
  # genera una migración nueva hacia adelante que dropea la tabla, igual que
  # cualquier otra migración del historial.
  def eliminar(schema_context_name, confirmar_tabla) do
    with {:ok, header} <- buscar_header(schema_context_name),
         :ok <- validar_confirmacion(schema_context_name, confirmar_tabla),
         :ok <- validar_sin_dependientes(schema_context_name) do
      crear_migracion_drop(schema_context_name)
      migrar()
      MetaSchemaContext.eliminar_header(header)
      archivo_eliminado? = borrar_schema_file(schema_context_name)

      {:ok, %{tabla: schema_context_name, archivo_eliminado: archivo_eliminado?}}
    end
  end

  defp buscar_header(schema_context_name) do
    case MetaSchemaContext.obtener_header_por_nombre(schema_context_name) do
      nil -> {:error, :not_found}
      header -> {:ok, header}
    end
  end

  # Repetir el nombre de la tabla en el body es la confirmación — barato de
  # implementar, elimina el borrado accidental por typo o script.
  defp validar_confirmacion(tabla, tabla), do: :ok

  defp validar_confirmacion(_tabla, _confirmar_tabla),
    do: {:error, "confirmar_tabla no coincide con el nombre de la tabla a borrar"}

  defp validar_sin_dependientes(schema_context_name) do
    case MetaSchemaContext.listar_dependientes(schema_context_name) do
      [] ->
        :ok

      dependientes ->
        {:error,
         "catálogo(s) dependientes, borralos primero: #{Enum.join(dependientes, ", ")}"}
    end
  end

  defp crear_migracion_drop(schema_context_name) do
    timestamp = timestamp_utc()
    modulo_migracion = "Eliminar" <> Macro.camelize(schema_context_name)
    path = "priv/repo/migrations/#{timestamp}_eliminar_#{schema_context_name}.exs"

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
    path = "lib/metadata_app/catalogos/#{schema_context_name}.ex"

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
  defp validar_referencias(detalles) do
    faltantes =
      detalles
      |> Enum.filter(&(Map.get(&1.schema_context_properties || %{}, "tipo") == "referencia"))
      |> Enum.map(&Map.fetch!(&1.schema_context_properties, "catalogo"))
      |> Enum.uniq()
      |> Enum.reject(&MetaSchemaContext.obtener_header_por_nombre/1)

    case faltantes do
      [] -> :ok
      _ -> {:error, "catálogo(s) referenciados inexistentes: #{Enum.join(faltantes, ", ")}"}
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

  defp construir_opciones(tipo, propiedades) when tipo in ["integer", "decimal"] do
    base_opciones(propiedades)
    |> Map.put(:minimo, Map.get(propiedades, "minimo"))
    |> Map.put(:maximo, Map.get(propiedades, "maximo"))
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
    case Map.get(propiedades, "unico_en") do
      %{"tabla" => tabla, "campo" => campo_externo} -> %{unico_en: {tabla, campo_externo}}
      _ -> %{}
    end
  end

  defp columna_migracion(campo, _tipo, %{tabla_referenciada: tabla_ref}),
    do: "      add :#{campo}, references(:#{tabla_ref}), null: false"

  defp columna_migracion(campo, :string, opciones),
    do: "      add :#{campo}, :string, size: #{opciones[:longitud] || 255}, null: false"

  defp columna_migracion(campo, tipo, _opciones) when tipo in [:integer, :decimal, :boolean, :date],
    do: "      add :#{campo}, :#{tipo}, null: false"

  defp crear_migracion(schema_context_name, campos) do
    timestamp = timestamp_utc()
    modulo_migracion = "Crear" <> Macro.camelize(schema_context_name)
    path = "priv/repo/migrations/#{timestamp}_crear_#{schema_context_name}.exs"

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
        end

        create unique_index(:#{schema_context_name}, [#{nombres_campos}], name: :#{nombre_indice})
      end
    end
    """

    File.write!(path, contenido)
  end

  defp crear_schema(schema_context_name, modulo, campos) do
    path = "lib/metadata_app/catalogos/#{schema_context_name}.ex"

    campos_literal =
      campos
      |> Enum.map(fn {campo, tipo, opciones} ->
        "{:#{campo}, :#{tipo}, #{inspect(opciones, limit: :infinity, printable_limit: :infinity)}}"
      end)
      |> Enum.join(", ")

    contenido = """
    defmodule MetadataApp.Catalogos.#{modulo} do
      use MetadataApp.MetaCatalogoGenerico, tabla: "#{schema_context_name}", campos: [#{campos_literal}]
    end
    """

    File.write!(path, contenido)
  end

  defp timestamp_utc do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    [y, mo, d, h, mi, s]
    |> Enum.zip([4, 2, 2, 2, 2, 2])
    |> Enum.map(fn {n, len} -> n |> Integer.to_string() |> String.pad_leading(len, "0") end)
    |> Enum.join()
  end
end
