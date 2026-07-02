defmodule MetadataApp.CatalogoGenerador do
  alias MetadataApp.MetaModelContext

  # Genera migración, schema, controller y ruta para schema_nombre a partir de
  # lo registrado en meta_schema, y corre la migración. Si el catálogo ya
  # existe (schema ya generado antes), no hace nada — es idempotente.
  def generar(schema_nombre) do
    schema_path = "lib/metadata_app/catalogos/#{schema_nombre}.ex"

    if File.exists?(schema_path) do
      {:ok, %{tabla: pluralizar(schema_nombre), ya_existia: true}}
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
          campos =
            for campo_meta <- campos_meta do
              propiedades = campo_meta.propiedades || %{}
              tipo = tipo_ecto(Map.get(propiedades, "tipo", "string"))
              longitud = if tipo == :string, do: Map.get(propiedades, "longitud", 255)
              {campo_meta.campo, tipo, longitud}
            end

          tabla = pluralizar(schema_nombre)
          modulo = Macro.camelize(schema_nombre)

          crear_migracion(tabla, campos)
          crear_schema(schema_nombre, modulo, tabla, campos)
          crear_controller(schema_nombre, modulo)
          agregar_ruta(tabla, modulo)
          migrar()

          {:ok, %{tabla: tabla, modulo: modulo, ya_existia: false}}
      end
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

  defp tipo_ecto("integer"), do: :integer
  defp tipo_ecto("decimal"), do: :decimal
  defp tipo_ecto(_string_u_otro), do: :string

  defp columna_migracion(campo, :string, longitud),
    do: "      add :#{campo}, :string, size: #{longitud || 255}, null: false"

  defp columna_migracion(campo, tipo, _longitud) when tipo in [:integer, :decimal],
    do: "      add :#{campo}, :#{tipo}, null: false"

  defp crear_migracion(tabla, campos) do
    timestamp = timestamp_utc()
    modulo_migracion = "Crear" <> Macro.camelize(tabla)
    path = "priv/repo/migrations/#{timestamp}_crear_#{tabla}.exs"

    columnas =
      for {campo, tipo, longitud} <- campos do
        columna_migracion(campo, tipo, longitud)
      end
      |> Enum.join("\n")

    nombres_campos = Enum.map(campos, fn {campo, _, _} -> ":#{campo}" end) |> Enum.join(", ")

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

        create unique_index(:#{tabla}, [#{nombres_campos}])
      end
    end
    """

    File.write!(path, contenido)
  end

  defp crear_schema(schema_nombre, modulo, tabla, campos) do
    path = "lib/metadata_app/catalogos/#{schema_nombre}.ex"

    campos_literal =
      campos
      |> Enum.map(fn
        {campo, :string, longitud} -> "{:#{campo}, :string, #{longitud || 255}}"
        {campo, tipo, _} -> "{:#{campo}, :#{tipo}, nil}"
      end)
      |> Enum.join(", ")

    contenido = """
    defmodule MetadataApp.Catalogos.#{modulo} do
      use MetadataApp.MetaCatalogoGenerico, tabla: "#{tabla}", campos: [#{campos_literal}]
    end
    """

    File.write!(path, contenido)
  end

  defp crear_controller(schema_nombre, modulo) do
    path = "lib/metadata_app_web/controllers/#{schema_nombre}_controller.ex"

    contenido = """
    defmodule MetadataAppWeb.#{modulo}Controller do
      use MetadataAppWeb.CatalogoGenericoController, schema: MetadataApp.Catalogos.#{modulo}, param: "#{schema_nombre}"
    end
    """

    File.write!(path, contenido)
  end

  defp agregar_ruta(tabla, modulo) do
    path = "lib/metadata_app_web/router.ex"
    contenido = File.read!(path)
    linea_nueva = "    resources \"/#{tabla}\", #{modulo}Controller, except: [:new, :edit]"

    cond do
      String.contains?(contenido, linea_nueva) ->
        :ok

      Regex.match?(~r/pipe_through :api\r?\n/, contenido) ->
        actualizado =
          Regex.replace(~r/(pipe_through :api\r?\n)/, contenido, "\\1" <> linea_nueva <> "\n", global: false)

        File.write!(path, actualizado)

      true ->
        raise "No se encontró el pipeline :api en router.ex para insertar la ruta"
    end
  end

  defp pluralizar(palabra) do
    cond do
      String.ends_with?(palabra, "s") -> palabra
      String.ends_with?(palabra, ["a", "e", "i", "o", "u"]) -> palabra <> "s"
      true -> palabra <> "es"
    end
  end

  defp timestamp_utc do
    {{y, mo, d}, {h, mi, s}} = :calendar.universal_time()

    [y, mo, d, h, mi, s]
    |> Enum.zip([4, 2, 2, 2, 2, 2])
    |> Enum.map(fn {n, len} -> n |> Integer.to_string() |> String.pad_leading(len, "0") end)
    |> Enum.join()
  end
end
