defmodule MetadataApp.MetaTepacheReversionTest do
  @moduledoc """
  SPEC-SYS-0710202601 R21: si el import falla, se deshace lo que hizo ese
  intento (archivos + migraciones) y la metadata/permisos quedan en todo
  o nada. Usa bundles locales armados en un directorio temporal y una
  raíz de prueba — nunca GitHub ni el proyecto real.

  Corre FUERA del sandbox (modo `:auto`, base de test): Ecto.Migrator
  corre cada migración en otro proceso mientras el principal sostiene el
  candado, y con la conexión única del sandbox se bloquean entre sí;
  además el sandbox convierte las transacciones en savepoints, que no es
  lo que pasa de verdad. La limpieza de cada test es explícita.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias MetadataApp.{MetaTepache, Repo}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  setup do
    Sandbox.mode(Repo, :auto)

    s = System.unique_integer([:positive])
    base = Path.join(System.tmp_dir!(), "tepache_rev_#{s}")
    raiz = Path.join(base, "raiz")
    fuente = Path.join(base, "fuente")
    File.mkdir_p!(raiz)
    File.mkdir_p!(fuente)

    on_exit(fn ->
      Sandbox.mode(Repo, :auto)
      limpiar_base(s)
      Sandbox.mode(Repo, :manual)
      File.rm_rf!(base)
    end)

    %{s: s, base: base, raiz: raiz, fuente: fuente, dir_migraciones: Path.join(raiz, "priv/repo/migrations")}
  end

  defp limpiar_base(s) do
    %{rows: tablas} = Repo.query!("select tablename from pg_tables where tablename like $1", ["tep_rev_#{s}_%"])
    Enum.each(tablas, fn [t] -> Repo.query!(~s(drop table if exists "#{t}" cascade)) end)

    Repo.query!("delete from meta_schema_migrations where version between $1 and $2", [
      30_000_000_000_000 + s * 10,
      30_000_000_000_000 + s * 10 + 9
    ])

    nombre = "pty_tep_rev_meta_#{s}"
    Repo.query!("delete from meta_schema_permiso where recurso = $1", [nombre])

    Repo.query!(
      "delete from meta_schema_detail where meta_schema_header_id in (select id from meta_schema_header where schema_context_name = $1)",
      [nombre]
    )

    Repo.query!("delete from meta_schema_header where schema_context_name = $1", [nombre])
  end

  defp meta_json(nombre) do
    Jason.encode!(%{
      "schema_context_name" => nombre,
      "schema_context_label" => nombre,
      "schema_context_nav" => "/#{nombre}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "detalles" => []
    })
  end

  defp version(c, n), do: 30_000_000_000_000 + c.s * 10 + n

  defp migracion(c, n, cuerpo) do
    v = version(c, n)
    modulo = "MetadataApp.Repo.Migrations.TepacheRev#{c.s}N#{n}"
    {"priv/repo/migrations/#{v}_tepache_rev_#{c.s}_#{n}.exs", "defmodule #{modulo} do\n  use Ecto.Migration\n\n  def change do\n#{cuerpo}\n  end\nend\n"}
  end

  defp crear_tabla(c, n), do: migracion(c, n, "    create table(:tep_rev_#{c.s}_#{n})")

  defp tabla_rota(c, n),
    do: migracion(c, n, "    create table(:tep_rev_#{c.s}_#{n}) do\n      add :x, references(:no_existe_#{c.s})\n    end")

  defp armar_bundle(c, archivos) do
    Enum.each(archivos, fn {ruta, contenido} ->
      destino = Path.join(c.fuente, ruta)
      File.mkdir_p!(Path.dirname(destino))
      File.write!(destino, contenido)
    end)

    raices = archivos |> Enum.map(fn {ruta, _} -> ruta |> Path.split() |> hd() end) |> Enum.uniq()
    bundle = Path.join(c.base, "tepache.tar.gz")
    {_, 0} = System.cmd("tar", ["-czf", bundle, "-C", c.fuente | raices], stderr_to_stdout: true)
    bundle
  end

  defp aplicar(c, bundle, opts \\ []) do
    MetaTepache.aplicar_import(
      %{bundle_path: bundle, nombres: [], campos_removidos: %{}},
      Keyword.merge([raiz: c.raiz, dir_migraciones: c.dir_migraciones], opts)
    )
  end

  defp tabla_existe?(nombre) do
    %{rows: [[r]]} = Repo.query!("select to_regclass($1)::text", [nombre])
    r != nil
  end

  defp aplicada?(version) do
    %{rows: rows} = Repo.query!("select 1 from meta_schema_migrations where version = $1", [version])
    rows != []
  end

  defp limpiar_respaldo(mensaje) do
    case Regex.run(~r/están en (.+?)\.$/, mensaje) do
      [_, dir] -> File.rm_rf(dir)
      _ -> :ok
    end
  end

  test "falla al migrar: revierte lo aplicado, borra lo nuevo y restaura lo sobrescrito", c do
    File.mkdir_p!(Path.join(c.raiz, "lib"))
    File.write!(Path.join(c.raiz, "lib/existente.txt"), "original")

    {ruta_ok, _} = ok = crear_tabla(c, 1)
    {ruta_rota, _} = rota = tabla_rota(c, 2)

    bundle =
      armar_bundle(c, [
        ok,
        rota,
        {"lib/existente.txt", "del bundle"},
        {"priv/repo/catalogos/pty_tep_rev_#{c.s}.meta.json", "{}"}
      ])

    assert {:error, mensaje} = aplicar(c, bundle)

    assert mensaje =~ "migrar tu base"
    assert mensaje =~ Path.basename(ruta_rota)
    assert mensaje =~ "No se aplicó nada"

    refute tabla_existe?("tep_rev_#{c.s}_1")
    refute aplicada?(version(c, 1))
    refute File.exists?(Path.join(c.raiz, ruta_ok))
    refute File.exists?(Path.join(c.raiz, "priv"))
    assert File.read!(Path.join(c.raiz, "lib/existente.txt")) == "original"
    refute File.exists?(bundle)
  end

  test "falla al importar metadata: nada de la transacción queda y se revierte lo demás", c do
    bundle = armar_bundle(c, [crear_tabla(c, 1)])
    nombre = "pty_tep_rev_meta_#{c.s}"

    importar = fn _nombres, _campos ->
      {:ok, _} =
        MetaSchemaContext.crear_header_con_detalles(%{
          "schema_context_name" => nombre,
          "schema_context_label" => nombre,
          "schema_context_nav" => "/#{nombre}",
          "schema_visible" => true,
          "schema_context_type" => 1,
          "detalles" => []
        })

      raise "falla forzada"
    end

    assert {:error, mensaje} = aplicar(c, bundle, importar: importar)

    assert mensaje =~ "importar metadata y permisos"
    assert mensaje =~ "falla forzada"
    assert mensaje =~ "No se aplicó nada"
    assert MetaSchemaContext.obtener_header_por_nombre(nombre) == nil
    refute tabla_existe?("tep_rev_#{c.s}_1")
    refute aplicada?(version(c, 1))
  end

  test "con una migración \"crear si no existe\" aplicada, no revierte nada y lo reporta", c do
    peligrosa = migracion(c, 1, "    create_if_not_exists table(:tep_rev_#{c.s}_1)")
    bundle = armar_bundle(c, [peligrosa, tabla_rota(c, 2)])

    assert {:error, mensaje} = aplicar(c, bundle)
    limpiar_respaldo(mensaje)

    assert mensaje =~ "No se revirtió nada"
    assert mensaje =~ "crear si no existe"
    assert tabla_existe?("tep_rev_#{c.s}_1")
    assert aplicada?(version(c, 1))
    assert File.exists?(Path.join(c.raiz, elem(peligrosa, 0)))
  end

  test "nunca revierte una migración que ya estaba aplicada antes del intento", c do
    {ruta_previa, contenido_previo} = crear_tabla(c, 0)
    File.mkdir_p!(c.dir_migraciones)
    File.write!(Path.join(c.raiz, ruta_previa), contenido_previo)
    Ecto.Migrator.run(Repo, [Path.expand(c.dir_migraciones)], :up, all: true, log: false)
    assert aplicada?(version(c, 0))

    bundle = armar_bundle(c, [crear_tabla(c, 1), tabla_rota(c, 2)])

    assert {:error, mensaje} = aplicar(c, bundle)

    assert mensaje =~ "No se aplicó nada"
    assert aplicada?(version(c, 0))
    assert tabla_existe?("tep_rev_#{c.s}_0")
    assert File.exists?(Path.join(c.raiz, ruta_previa))
    refute aplicada?(version(c, 1))
  end

  # E9 — bug real (TEPACHE-000010, 2026-10-07): re-importar un catálogo
  # cuyos permisos ya existen abortaba la transacción (25P02), porque
  # registrar_permisos_catalogo/1 dependía de que el INSERT duplicado
  # chocara con el índice único.
  test "importa un catálogo que ya existe con sus permisos ya registrados", c do
    nombre = "pty_tep_rev_meta_#{c.s}"
    archivo = {"priv/repo/catalogos/#{nombre}.meta.json", meta_json(nombre)}

    primero = armar_bundle(c, [archivo])

    assert {:ok, _} =
             MetaTepache.aplicar_import(%{bundle_path: primero, nombres: [nombre], campos_removidos: %{}},
               raiz: c.raiz,
               dir_migraciones: c.dir_migraciones
             )

    %{rows: [[permisos]]} = Repo.query!("select count(*) from meta_schema_permiso where recurso = $1", [nombre])
    assert permisos == 4

    segundo = armar_bundle(c, [archivo])

    assert {:ok, %{catalogos: [^nombre]}} =
             MetaTepache.aplicar_import(%{bundle_path: segundo, nombres: [nombre], campos_removidos: %{}},
               raiz: c.raiz,
               dir_migraciones: c.dir_migraciones
             )

    %{rows: [[permisos]]} = Repo.query!("select count(*) from meta_schema_permiso where recurso = $1", [nombre])
    assert permisos == 4
  end

  describe "en_transaccion/1 (R21.3)" do
    test "una excepción adentro es falla y no deja cambios", c do
      nombre = "pty_tep_rev_meta_#{c.s}"

      resultado =
        MetaTepache.en_transaccion(fn ->
          {:ok, _} =
            MetaSchemaContext.crear_header_con_detalles(%{
              "schema_context_name" => nombre,
              "schema_context_label" => nombre,
              "schema_context_nav" => "/#{nombre}",
              "schema_visible" => true,
              "schema_context_type" => 1,
              "detalles" => []
            })

          raise "boom"
        end)

      assert {:error, "boom"} = resultado
      assert MetaSchemaContext.obtener_header_por_nombre(nombre) == nil
    end
  end
end
