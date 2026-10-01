defmodule MetadataApp.Purga.Local do
  @moduledoc """
  Limpieza opcional de la copia local de quien purga (SPEC-ARQ-3009202601,
  R14, design §9): base de datos local y archivos, como si el artefacto
  nunca hubiera existido en esta máquina. A diferencia de BC List →
  Eliminar, no genera migración de `DROP`.

  Borra las migraciones de `priv/` **y** su copia en `_build/.../priv`: en
  Windows esa carpeta es una copia, y una migración que sigue ahí sin su
  fila en la tabla de migraciones queda "pendiente" (PendingMigrationError
  en `phx.server`, y un `mix ecto.migrate` volvería a crear la tabla).

  Las copias locales de los demás desarrolladores no se tocan.

  `opts` (solo se cambian en pruebas): `:raiz` (raíz del proyecto),
  `:build_priv` (el `priv/` de `_build`), `:bpb_habilitado`.
  """

  alias MetadataApp.Repo
  alias MetadataApp.Purga.{Base, Unidad}

  @catalogos "lib/metadata_app/meta_business_process/catalogos"
  @reglas "lib/metadata_app/meta_business_process/reglas"
  @meta "priv/repo/catalogos"
  @migraciones "priv/repo/migrations"
  @extensiones_meta ~w(meta motor plantillas endpoint)

  @doc "¿Hay algo de `nombre` en esta máquina (header local o algún archivo)?"
  def existe?(nombre, opts \\ []) do
    Unidad.nombre_valido?(nombre) and
      (match?({:ok, _}, Unidad.tablas(Repo, nombre)) or archivos(tablas(nombre), opts) != [])
  end

  @doc """
  Borra `nombre` de esta máquina. `{:ok, %{archivos: n, resultado: ...}}` |
  `{:error, mensaje}`. Si la base local tiene dependencias, no borra nada.
  """
  def purgar(nombre, usuario_email, opts \\ []) do
    cond do
      not Keyword.get(
        opts,
        :bpb_habilitado,
        Application.get_env(:metadata_app, :bpb_habilitado, false)
      ) ->
        {:error, "La limpieza local solo existe donde corre el Business Process Builder."}

      not Unidad.nombre_valido?(nombre) ->
        {:error, "Solo se limpian artefactos pty_*."}

      true ->
        tablas = tablas(nombre)
        archivos = archivos(tablas, opts)

        versiones =
          for ruta <- archivos,
              String.ends_with?(ruta, ".exs"),
              uniq: true,
              do: Unidad.version(ruta)

        params = %{
          artefacto: nombre,
          tablas: tablas,
          versiones: versiones,
          filas_confirmadas: 0,
          usuario_email: usuario_email
        }

        with {:ok, resultado} <- Base.ejecutar(params, local: true) do
          Enum.each(archivos, &File.rm_rf!/1)
          {:ok, %{archivos: length(archivos), resultado: resultado.resultado}}
        end
    end
  end

  # La unidad según la base local; si ya no hay header (por ejemplo, una
  # lápida), solo el nombre.
  defp tablas(nombre) do
    case Unidad.tablas(Repo, nombre) do
      {:ok, tablas} -> tablas
      _ -> [nombre]
    end
  end

  @doc false
  def archivos(tablas, opts \\ []) do
    raiz = Keyword.get(opts, :raiz, File.cwd!())

    build_priv =
      Keyword.get_lazy(opts, :build_priv, fn -> Application.app_dir(:metadata_app, "priv") end)

    universo = Enum.map(Unidad.headers(Repo), & &1.nombre)

    fuentes =
      for t <- tablas do
        [Path.join([raiz, @catalogos, "#{t}.ex"]), Path.join([raiz, @reglas, t])] ++
          for ext <- @extensiones_meta, do: Path.join([raiz, @meta, "#{t}.#{ext}.json"])
      end

    migraciones =
      for dir <- [Path.join(raiz, @migraciones), Path.join(build_priv, "repo/migrations")],
          dir = Path.expand(dir),
          nombre <- Unidad.migraciones(tablas, nombres_en(dir), universo) do
        Path.join(dir, nombre)
      end

    (List.flatten(fuentes) ++ migraciones)
    |> Enum.filter(&File.exists?/1)
    |> Enum.uniq()
  end

  defp nombres_en(dir),
    do: dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.map(&Path.basename/1)
end
