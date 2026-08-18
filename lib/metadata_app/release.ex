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

  # Bootstrap del usuario SYSADMIN (cross-empresa, ver Usuario.super_admin
  # y Autenticacion.upsert_sysadmin/2) — SYSADMIN_EMAIL/SYSADMIN_PASSWORD
  # SIEMPRE vienen del entorno de cada despliegue, nunca hardcodeados acá
  # ni en una migración (mismo criterio que Oracle: SYS/SYSTEM es un
  # nombre fijo, pero la contraseña se define al crear la instancia, no
  # viene de fábrica). Falla fuerte si faltan — mejor un deploy que avisa
  # "falta configurar" que uno que arranca con una contraseña adivinable.
  # Corre después de migrate/0 (necesita la columna super_admin ya creada)
  # — llamado desde bin/seed_sysadmin, mismo patrón que bin/migrate.
  def seed_sysadmin do
    load_app()

    email = System.get_env("SYSADMIN_EMAIL") || raise "Falta la variable de entorno SYSADMIN_EMAIL"
    password = System.get_env("SYSADMIN_PASSWORD") || raise "Falta la variable de entorno SYSADMIN_PASSWORD"

    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        MetadataApp.Autenticacion.upsert_sysadmin(email, password)
      end)

    case resultado do
      {:ok, _usuario} -> IO.puts("SYSADMIN listo: #{email}")
      {:error, changeset} -> raise "No se pudo sembrar SYSADMIN: #{inspect(changeset.errors)}"
    end
  end

  # Bootstrap completo de un sistema nuevo, idempotente (docs/onboarding-
  # nuevo-sistema.md, Fase 1). Antes de esto, migrate/import_meta/
  # seed_sysadmin eran 3 comandos sueltos y crear la primera empresa no
  # existía como comando en ningún lado -- había que hacerlo a mano por
  # RPC. Pensado para correr en CADA deploy (el primero o el número 500):
  # en un sistema ya bootstrapeado, cada paso es un no-op real, no un
  # "ya existe, error" -- seguro de repetir siempre.
  #
  # SYSADMIN_EMAIL/SYSADMIN_PASSWORD son OPCIONALES a propósito (roadmap
  # #onboarding, Fase 2): si no vienen, setup/0 igual termina bien -- deja
  # el sistema sin sysadmin/empresa, listo para que alguien lo complete
  # desde el wizard de primer arranque en el navegador (sin que
  # Operaciones tenga que inventar/generar una contraseña por variable de
  # entorno para cada uno de ~100 sistemas). Si viene SOLO UNA de las dos,
  # eso sí es un error real (typo probable, no "uso el wizard a propósito")
  # -- ahí se falla fuerte, antes de tocar la base.
  def setup do
    validar_par_o_ninguna!("SYSADMIN_EMAIL", "SYSADMIN_PASSWORD")

    IO.puts("== Migrando ==")
    migrate()

    IO.puts("== Importando metadata de catálogos publicados ==")

    try do
      import_meta()
    rescue
      # Un catálogo con metadata desincronizada (bug de datos preexistente,
      # ej. un campo de acompañamiento que apunta a algo que ya no existe)
      # NO puede tumbar sysadmin/empresa -- eso rompería el arranque de un
      # sistema entero por un problema aislado de UN catálogo. Se loguea
      # fuerte para que quede visible, pero setup/0 sigue de largo.
      error ->
        IO.puts("ADVERTENCIA: import_meta falló, revisar manualmente -- #{Exception.message(error)}")
    end

    if System.get_env("SYSADMIN_EMAIL") not in [nil, ""] do
      IO.puts("== Sysadmin ==")
      seed_sysadmin()

      IO.puts("== Empresa inicial ==")
      asegurar_empresa_inicial()
    else
      IO.puts("SYSADMIN_EMAIL no configurado -- completá el primer arranque desde el navegador (wizard).")
    end

    IO.puts("Setup completo.")
  end

  defp validar_par_o_ninguna!(nombre_a, nombre_b) do
    presente_a? = System.get_env(nombre_a) not in [nil, ""]
    presente_b? = System.get_env(nombre_b) not in [nil, ""]

    cond do
      presente_a? == presente_b? -> :ok
      presente_a? -> raise "#{nombre_a} está configurada pero falta #{nombre_b}"
      true -> raise "#{nombre_b} está configurada pero falta #{nombre_a}"
    end
  end

  # No-op si YA existe al menos una empresa -- nunca crea una segunda
  # "por default" arriba de un sistema que ya tiene datos reales.
  defp asegurar_empresa_inicial do
    load_app()

    {:ok, resultado, _apps} =
      Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo ->
        if MetadataApp.Autenticacion.existe_alguna_empresa?() do
          :ya_existia
        else
          email = System.get_env("SYSADMIN_EMAIL")
          nombre_empresa = System.get_env("EMPRESA_INICIAL_NOMBRE", "Empresa Principal")
          usuario = MetadataApp.Autenticacion.get_usuario_by_email(email)
          MetadataApp.Autenticacion.crear_empresa_para_usuario(nombre_empresa, usuario.id)
        end
      end)

    case resultado do
      :ya_existia -> IO.puts("Ya existía al menos una empresa, no se creó ninguna.")
      {:ok, empresa} -> IO.puts("Empresa inicial creada: #{empresa.nombre}")
      {:error, motivo} -> raise "No se pudo crear la empresa inicial: #{inspect(motivo)}"
    end
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
