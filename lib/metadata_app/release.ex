defmodule MetadataApp.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :metadata_app

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  # Corre después de migrate/0 — la migración crea la TABLA física del BC
  # (agregado 2026-07-23, ver bin/import_meta y
  # .github/workflows/bc-deploy.yml), esto crea el REGISTRO en
  # meta_schema_header/detail/estados/transiciones que hace que el motor
  # reconozca esa tabla como un Business Context real. Sin esto la tabla
  # existe pero la API responde "no encontrado" — nadie le avisó a la
  # metadata que el catálogo existe.
  def import_meta do
    load_app()

    # "priv/repo/catalogos" (el default que usan los Mix.Tasks) es una
    # ruta relativa que solo resuelve bien corriendo con `mix` desde la
    # raíz del proyecto -- en un release compilado el priv/ real de la app
    # vive en otro lado (ej. /app/lib/metadata_app-<vsn>/priv/...), no en
    # el cwd. Application.app_dir/2 es la forma correcta de encontrarlo en
    # cualquier contexto (encontrado real: probando esto por primera vez
    # contra un release de verdad, la ruta relativa daba {:error, :enoent}
    # en silencio).
    dir = Application.app_dir(@app, "priv/repo/catalogos")

    {:ok, mensajes, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetadataApp.MetaImportExport.importar_meta(dir) ++ MetadataApp.MetaImportExport.importar_motor(dir)
      end)

    Enum.each(mensajes, &IO.puts/1)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
