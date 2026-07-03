defmodule MetadataApp.CatalogoGenerador do
  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaModelContext
  alias MetadataApp.CatalogoRegistry

  # Genera migración y schema para schema_nombre/tabla a partir de lo
  # registrado en meta_schema, los registra en el índice de catálogos y
  # corre la migración. Si el catálogo ya existe (schema ya generado antes),
  # no hace nada — es idempotente.
  # Postgres trunca (sin error) identificadores de más de 63 bytes. El índice
  # único del catálogo se nombra "<tabla>_unico_index"; se deja margen para
  # ese sufijo y para nombres de constraint que Ecto derive de la tabla.
  @tabla_longitud_maxima 50

  def generar(schema_nombre, tabla) do
    schema_path = "lib/metadata_app/catalogos/#{schema_nombre}.ex"

    if File.exists?(schema_path) do
      {:ok, %{tabla: tabla, ya_existia: true}}
    else
      campos_meta =
        schema_nombre
        |> MetaModelContext.listar_campos()
        |> Enum.reject(&(&1.campo == "id"))

      case campos_meta do
        [] ->
          {:error,
           "No hay metadata en meta_schema para schema_nombre=#{schema_nombre} (aparte de 'id')."}

        campos_meta ->
          with :ok <- validar_tabla(tabla),
               :ok <- validar_referencias(campos_meta) do
            campos =
              for campo_meta <- campos_meta do
                propiedades = campo_meta.propiedades || %{}
                tipo_str = Map.get(propiedades, "tipo", "string")
                tipo = tipo_ecto(tipo_str)
                opciones = construir_opciones(tipo_str, propiedades)
                {campo_meta.campo, tipo, opciones}
              end

            modulo = Macro.camelize(schema_nombre)

            crear_migracion(tabla, campos)
            crear_schema(schema_nombre, modulo, tabla, campos)
            migrar()
            CatalogoRegistry.registrar(tabla, schema_nombre, modulo)

            {:ok, %{tabla: tabla, modulo: modulo, ya_existia: false}}
          end
      end
    end
  end

  # Vista previa del impacto de borrar un catálogo: cuántas filas se
  # perderían y qué otros catálogos lo referencian (y por lo tanto bloquean
  # el borrado). No modifica nada.
  def impacto(tabla) do
    with {:ok, catalogo} <- buscar_catalogo(tabla) do
      filas = Repo.aggregate(from(t in tabla), :count)
      dependientes = MetaModelContext.listar_dependientes(catalogo.schema_nombre)

      {:ok, %{tabla: tabla, filas: filas, dependientes: dependientes}}
    end
  end

  # Borrado total e irreversible de un catálogo: tabla, metadata, registro y
  # archivo de schema. Nunca hace rollback de la migración de creación (el
  # orden de versiones la hace frágil) — en cambio genera una migración
  # nueva hacia adelante que dropea la tabla, igual que cualquier otra
  # migración del historial.
  def eliminar(tabla, confirmar_tabla) do
    with {:ok, catalogo} <- buscar_catalogo(tabla),
         :ok <- validar_confirmacion(tabla, confirmar_tabla),
         :ok <- validar_sin_dependientes(catalogo.schema_nombre) do
      crear_migracion_drop(tabla)
      migrar()
      MetaModelContext.borrar_campos(catalogo.schema_nombre)
      CatalogoRegistry.eliminar(tabla)
      archivo_eliminado? = borrar_schema_file(catalogo.schema_nombre)

      {:ok, %{tabla: tabla, archivo_eliminado: archivo_eliminado?}}
    end
  end

  defp buscar_catalogo(tabla) do
    case CatalogoRegistry.obtener_por_tabla(tabla) do
      nil -> {:error, :not_found}
      catalogo -> {:ok, catalogo}
    end
  end

  # Repetir el nombre de la tabla en el body es la confirmación — barato de
  # implementar, elimina el borrado accidental por typo o script.
  defp validar_confirmacion(tabla, tabla), do: :ok

  defp validar_confirmacion(_tabla, _confirmar_tabla),
    do: {:error, "confirmar_tabla no coincide con el nombre de la tabla a borrar"}

  defp validar_sin_dependientes(schema_nombre) do
    case MetaModelContext.listar_dependientes(schema_nombre) do
      [] ->
        :ok

      dependientes ->
        {:error,
         "catálogo(s) dependientes, borralos primero: #{Enum.join(dependientes, ", ")}"}
    end
  end

  defp crear_migracion_drop(tabla) do
    timestamp = timestamp_utc()
    modulo_migracion = "Eliminar" <> Macro.camelize(tabla)
    path = "priv/repo/migrations/#{timestamp}_eliminar_#{tabla}.exs"

    contenido = """
    defmodule MetadataApp.Repo.Migrations.#{modulo_migracion} do
      use Ecto.Migration

      def change do
        drop table(:#{tabla})
      end
    end
    """

    File.write!(path, contenido)
  end

  defp borrar_schema_file(schema_nombre) do
    path = "lib/metadata_app/catalogos/#{schema_nombre}.ex"

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

  # Valida que todo campo tipo "referencia" apunte a un catálogo ya
  # registrado (no se puede crear una FK a una tabla que no existe todavía).
  defp validar_referencias(campos_meta) do
    faltantes =
      campos_meta
      |> Enum.filter(&(Map.get(&1.propiedades || %{}, "tipo") == "referencia"))
      |> Enum.map(&Map.fetch!(&1.propiedades, "catalogo"))
      |> Enum.uniq()
      |> Enum.reject(&CatalogoRegistry.obtener_por_schema_nombre/1)

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
    tabla_ref = CatalogoRegistry.obtener_por_schema_nombre(catalogo_ref)

    base_opciones(propiedades)
    |> Map.put(:tabla_referenciada, tabla_ref.tabla)
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

  defp crear_migracion(tabla, campos) do
    timestamp = timestamp_utc()
    modulo_migracion = "Crear" <> Macro.camelize(tabla)
    path = "priv/repo/migrations/#{timestamp}_crear_#{tabla}.exs"

    columnas =
      for {campo, tipo, opciones} <- campos do
        columna_migracion(campo, tipo, opciones)
      end
      |> Enum.join("\n")

    nombres_campos = Enum.map(campos, fn {campo, _, _} -> ":#{campo}" end) |> Enum.join(", ")
    nombre_indice = nombre_indice_unico(tabla)

    contenido = """
    defmodule MetadataApp.Repo.Migrations.#{modulo_migracion} do
      use Ecto.Migration

      def change do
        create table(:#{tabla}) do
    #{columnas}

          add :insert_guid, :string, size: 32, null: false
          add :update_guid, :string, size: 32, null: true
          add :delete_guid, :string, size: 32, null: true
        end

        create unique_index(:#{tabla}, [#{nombres_campos}], name: :#{nombre_indice})
      end
    end
    """

    File.write!(path, contenido)
  end

  defp crear_schema(schema_nombre, modulo, tabla, campos) do
    path = "lib/metadata_app/catalogos/#{schema_nombre}.ex"

    campos_literal =
      campos
      |> Enum.map(fn {campo, tipo, opciones} ->
        "{:#{campo}, :#{tipo}, #{inspect(opciones, limit: :infinity, printable_limit: :infinity)}}"
      end)
      |> Enum.join(", ")

    contenido = """
    defmodule MetadataApp.Catalogos.#{modulo} do
      use MetadataApp.MetaCatalogoGenerico, tabla: "#{tabla}", campos: [#{campos_literal}]
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
