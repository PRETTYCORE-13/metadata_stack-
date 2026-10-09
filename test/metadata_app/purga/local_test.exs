defmodule MetadataApp.Purga.LocalTest do
  @moduledoc "Limpieza local opcional (SPEC-ARQ-3009202601, R14, Grupo H)."
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Purga.Local
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @migraciones MetadataApp.Repo.config()[:migration_source] || "schema_migrations"

  setup do
    s = System.unique_integer([:positive])
    nombre = "pty_loc#{s}"
    ts = "2026090100#{String.pad_leading(Integer.to_string(rem(s, 10_000)), 4, "0")}"
    version = String.to_integer(ts)

    {:ok, {_, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => nombre,
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    Repo.query!(~s|CREATE TABLE "#{nombre}" (id bigserial PRIMARY KEY)|, [])
    Repo.query!(~s|INSERT INTO "#{nombre}" DEFAULT VALUES|, [])

    Repo.query!("INSERT INTO #{@migraciones} (version, inserted_at) VALUES ($1, now())", [version])

    raiz = Path.join(System.tmp_dir!(), "purga_local_#{s}")
    build_priv = Path.join(raiz, "_build/dev/lib/metadata_app/priv")
    migracion = "#{ts}_crear_#{nombre}_#{ts}.exs"
    ajena = "#{ts}_crear_#{nombre}_v2_#{ts}.exs"

    propios = [
      "lib/metadata_app/meta_business_process/catalogos/#{nombre}.ex",
      "lib/metadata_app/meta_business_process/reglas/#{nombre}/regla.ex",
      "priv/repo/catalogos/#{nombre}.meta.json",
      "priv/repo/catalogos/#{nombre}.motor.json",
      "priv/repo/migrations/#{migracion}",
      "_build/dev/lib/metadata_app/priv/repo/migrations/#{migracion}"
    ]

    ajenos = [
      "priv/repo/migrations/#{ajena}",
      "_build/dev/lib/metadata_app/priv/repo/migrations/#{ajena}"
    ]

    for ruta <- propios ++ ajenos do
      File.mkdir_p!(Path.dirname(Path.join(raiz, ruta)))
      File.write!(Path.join(raiz, ruta), "x")
    end

    on_exit(fn -> File.rm_rf!(raiz) end)

    %{
      nombre: nombre,
      version: version,
      raiz: raiz,
      opts: [raiz: raiz, build_priv: build_priv, bpb_habilitado: true],
      propios: propios,
      ajenos: ajenos
    }
  end

  defp existe?(c, ruta), do: File.exists?(Path.join(c.raiz, ruta))

  test "borra base, archivos y migraciones (también la copia de _build), nada ajeno", c do
    assert Local.existe?(c.nombre, c.opts)
    assert {:ok, %{archivos: 6, resultado: "ok"}} = Local.purgar(c.nombre, "dev@x.mx", c.opts)

    # 6 = .ex, carpeta de reglas, 2 exports y la migración en priv y en _build.
    for ruta <- c.propios, do: refute(existe?(c, ruta), ruta)
    for ruta <- c.ajenos, do: assert(existe?(c, ruta), ruta)

    assert Repo.query!("SELECT to_regclass($1)", [c.nombre]).rows == [[nil]]
    refute Repo.exists?(from h in "meta_schema_header", where: h.schema_context_name == ^c.nombre)
    assert Repo.query!("SELECT 1 FROM #{@migraciones} WHERE version = $1", [c.version]).rows == []
  end

  test "con dependencias en la base local no borra nada", c do
    Repo.query!(
      ~s|CREATE TABLE "#{c.nombre}_ajena" (id bigserial, x bigint REFERENCES "#{c.nombre}"(id))|,
      []
    )

    assert {:error, mensaje} = Local.purgar(c.nombre, "dev@x.mx", c.opts)
    assert mensaje =~ "llave foránea"
    for ruta <- c.propios, do: assert(existe?(c, ruta), ruta)
  end

  test "solo donde corre el BPB", c do
    assert {:error, m} =
             Local.purgar(c.nombre, "dev@x.mx", Keyword.put(c.opts, :bpb_habilitado, false))

    assert m =~ "Business Process Builder"
  end

  test "existe? es falso para algo que no está en esta máquina", c do
    refute Local.existe?("pty_nunca_existio", c.opts)
    refute Local.existe?("meta_schema_header", c.opts)
  end
end
