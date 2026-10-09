defmodule MetadataApp.Purga.BaseTest do
  use MetadataApp.DataCase, async: true

  import ExUnit.CaptureIO

  alias MetadataApp.Purga.{Base, Registro, Remoto}
  alias MetadataApp.Release.Purga, as: ReleasePurga
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  @version 29_990_101_000_001
  @migraciones MetadataApp.Repo.config()[:migration_source] || "schema_migrations"

  # Artefacto sintético: maestro + detalle (header + tabla física), un
  # permiso por nombre y una versión en la tabla de migraciones.
  setup do
    s = System.unique_integer([:positive])
    maestro = "pty_purga_t#{s}"
    detalle = "#{maestro}_det"

    {:ok, {h_maestro, _}} = MetaSchemaContext.crear_header_con_detalles(attrs(maestro, []))

    {:ok, {_h_det, _}} =
      MetaSchemaContext.crear_header_con_detalles(
        attrs(detalle, [campo("pedido", "referencia", %{"catalogo" => maestro})])
        |> Map.put("schema_encabezado_id", h_maestro.id)
      )

    Repo.query!(~s|CREATE TABLE "#{maestro}" (id bigserial PRIMARY KEY, nombre text)|, [])

    Repo.query!(
      ~s|CREATE TABLE "#{detalle}" (id bigserial PRIMARY KEY, encabezado_id bigint REFERENCES "#{maestro}"(id))|,
      []
    )

    Repo.query!(~s|INSERT INTO "#{maestro}" (nombre) VALUES ('a'), ('b')|, [])

    Repo.query!(
      ~s|INSERT INTO "#{detalle}" (encabezado_id) SELECT id FROM "#{maestro}" LIMIT 1|,
      []
    )

    Repo.insert_all("meta_schema_permiso", [%{recurso: maestro, accion: "leer", insert_guid: "x"}])

    Repo.query!("INSERT INTO #{@migraciones} (version, inserted_at) VALUES ($1, now())", [
      @version
    ])

    priv = Path.join(System.tmp_dir!(), "purga_priv_#{s}")
    File.mkdir_p!(Path.join([priv, "repo", "migrations"]))
    File.mkdir_p!(Path.join([priv, "repo", "catalogos"]))
    on_exit(fn -> File.rm_rf!(priv) end)

    %{
      maestro: maestro,
      detalle: detalle,
      tablas: [detalle, maestro],
      priv: priv,
      h_maestro: h_maestro
    }
  end

  defp attrs(nombre, detalles) do
    %{
      "schema_context_name" => nombre,
      "schema_context_label" => nombre,
      "schema_context_nav" => "/#{nombre}",
      "schema_visible" => true,
      "schema_context_type" => 1,
      "detalles" => detalles
    }
  end

  defp campo(nombre, tipo, extra) do
    %{
      "schema_context_field" => nombre,
      "schema_context_properties" =>
        Map.merge(
          %{
            "etiqueta" => nombre,
            "tipo" => tipo,
            "orden" => 0,
            "visible" => true,
            "editable" => true
          },
          extra
        )
    }
  end

  defp params(c, extra \\ %{}) do
    Map.merge(
      %{
        artefacto: c.maestro,
        tablas: c.tablas,
        versiones: [@version],
        filas_confirmadas: 3,
        usuario_email: "dev@prueba.mx"
      },
      extra
    )
  end

  defp tabla_existe?(t),
    do: Repo.query!("SELECT to_regclass($1) IS NOT NULL", [t]).rows == [[true]]

  defp header?(t),
    do: Repo.exists?(from h in "meta_schema_header", where: h.schema_context_name == ^t)

  defp registros(maestro),
    do: Repo.all(from r in Registro, where: r.artefacto == ^maestro, order_by: r.id)

  describe "impacto/4" do
    test "cuenta filas por tabla, ve las versiones y no toma al propio detalle como dependencia",
         c do
      assert {:ok, imp} = Base.impacto(c.maestro, c.tablas, [@version, 1], priv_dir: c.priv)

      assert [
               %{nombre: _, tabla: true, header: true, filas: 1},
               %{tabla: true, header: true, filas: 2}
             ] = imp.tablas

      assert imp.filas == 3
      assert imp.versiones_aplicadas == [@version]
      assert imp.dependencias == []
      refute imp.imagen_incluye
      refute imp.nada_que_borrar
    end

    test "detecta que la imagen todavía trae el artefacto (meta.json o migración)", c do
      File.write!(
        Path.join([
          c.priv,
          "repo",
          "migrations",
          "20260901000000_crear_#{c.detalle}_20260901000000.exs"
        ]),
        ""
      )

      assert {:ok, %{imagen_incluye: true}} =
               Base.impacto(c.maestro, c.tablas, [], priv_dir: c.priv)

      File.rm_rf!(Path.join([c.priv, "repo", "migrations"]))
      File.write!(Path.join([c.priv, "repo", "catalogos", "#{c.maestro}.meta.json"]), "{}")

      assert {:ok, %{imagen_incluye: true}} =
               Base.impacto(c.maestro, c.tablas, [], priv_dir: c.priv)
    end

    test "rechaza nombres que no son pty_*", c do
      assert {:error, _} = Base.impacto(c.maestro, ["meta_schema_header"], [], priv_dir: c.priv)
    end
  end

  describe "dependencias" do
    test "un campo referencia de otro catálogo", c do
      MetaSchemaContext.crear_header_con_detalles(
        attrs("#{c.maestro}_otro", [campo("x", "referencia", %{"catalogo" => c.maestro})])
      )

      assert {:ok, %{dependencias: [dep]}} =
               Base.impacto(c.maestro, c.tablas, [], priv_dir: c.priv)

      assert dep =~ "#{c.maestro}_otro"
    end

    test "una llave foránea real desde otra tabla", c do
      Repo.query!(
        ~s|CREATE TABLE "#{c.maestro}_ajena" (id bigserial, m bigint REFERENCES "#{c.maestro}"(id))|,
        []
      )

      assert {:ok, %{dependencias: [dep]}} =
               Base.impacto(c.maestro, c.tablas, [], priv_dir: c.priv)

      assert dep =~ "#{c.maestro}_ajena tiene una llave foránea hacia #{c.maestro}"
    end

    test "una Consulta SQL que lee la tabla", c do
      Repo.query!(
        ~s|CREATE VIEW "pty_sql_purga_#{c.maestro}" AS SELECT id FROM "#{c.maestro}"|,
        []
      )

      assert {:ok, %{dependencias: [dep]}} =
               Base.impacto(c.maestro, c.tablas, [], priv_dir: c.priv)

      assert dep =~ "pty_sql_purga_#{c.maestro}"
    end

    test "un registro de negocio que apunta al header (ej. Perfil de Folio)", c do
      Repo.query!(
        ~s|CREATE TABLE "#{c.maestro}_perfil" (id bigserial, documento bigint REFERENCES meta_schema_header(id))|,
        []
      )

      Repo.query!(~s|INSERT INTO "#{c.maestro}_perfil" (documento) VALUES ($1)|, [c.h_maestro.id])

      assert {:ok, %{dependencias: [dep]}} =
               Base.impacto(c.maestro, c.tablas, [], priv_dir: c.priv)

      assert dep =~ "1 registro(s) que apuntan a este artefacto (columna documento)"
    end
  end

  describe "ejecutar/2" do
    test "borra tablas, metadata, permiso y versión, y lo registra", c do
      assert {:ok, %{resultado: "ok"}} = Base.ejecutar(params(c), priv_dir: c.priv)

      for t <- c.tablas do
        refute tabla_existe?(t)
        refute header?(t)
      end

      refute Repo.exists?(from p in "meta_schema_permiso", where: p.recurso == ^c.maestro)

      assert Repo.query!("SELECT 1 FROM #{@migraciones} WHERE version = $1", [@version]).rows ==
               []

      assert [
               %Registro{
                 accion: "purga",
                 resultado: "ok",
                 versiones: [@version],
                 usuario_email: "dev@prueba.mx"
               } = r
             ] = registros(c.maestro)

      assert r.tablas == %{c.maestro => 2, c.detalle => 1}
    end

    test "se detiene si hay más filas que las confirmadas, sin borrar nada", c do
      assert {:error, mensaje} =
               Base.ejecutar(params(c, %{filas_confirmadas: 2}), priv_dir: c.priv)

      assert mensaje =~ "tiene 3 registro(s) y se confirmaron 2"

      assert tabla_existe?(c.maestro)
      assert [%Registro{resultado: "error"}] = registros(c.maestro)
    end

    test "se detiene si la imagen todavía lo trae", c do
      File.write!(Path.join([c.priv, "repo", "catalogos", "#{c.maestro}.meta.json"]), "{}")

      assert {:error, mensaje} = Base.ejecutar(params(c), priv_dir: c.priv)
      assert mensaje =~ "todavía incluye"
      assert tabla_existe?(c.maestro)
    end

    test "si algo falla a mitad, no queda nada a medias", c do
      # Una vista que no es pty_sql_* no cuenta como dependencia, pero hace
      # fallar el DROP TABLE.
      Repo.query!(~s|CREATE VIEW "v_#{c.maestro}" AS SELECT id FROM "#{c.maestro}"|, [])

      assert {:error, _} = Base.ejecutar(params(c), priv_dir: c.priv)

      assert tabla_existe?(c.detalle)
      assert header?(c.maestro)

      assert Repo.query!("SELECT 1 FROM #{@migraciones} WHERE version = $1", [@version]).rows == [
               [1]
             ]

      assert [%Registro{resultado: "error"}] = registros(c.maestro)
    end

    test "repetirla no falla: avisa que no había nada que borrar", c do
      assert {:ok, %{resultado: "ok"}} = Base.ejecutar(params(c), priv_dir: c.priv)

      assert {:ok, %{resultado: "sin_cambios"}} =
               Base.ejecutar(params(c, %{filas_confirmadas: 0}), priv_dir: c.priv)

      assert ["ok", "sin_cambios"] = Enum.map(registros(c.maestro), & &1.resultado)
    end
  end

  describe "inventario/0 y bitacora/1" do
    test "el inventario incluye el artefacto con sus tablas", c do
      inv = Base.inventario()
      assert %{tablas: tablas, tipo: 1} = Enum.find(inv.unidades, &(&1.maestro == c.maestro))
      assert @version in inv.versiones
      assert tablas == c.tablas
    end

    test "la bitácora sale del más reciente al más viejo", c do
      {:ok, _} =
        Base.registrar(%{
          artefacto: c.maestro,
          accion: "retiro",
          resultado: "ok",
          usuario_email: "a@b.mx"
        })

      {:ok, _} =
        Base.registrar(%{
          artefacto: c.maestro,
          accion: "purga",
          resultado: "error",
          usuario_email: "a@b.mx"
        })

      assert [%{accion: "purga"}, %{accion: "retiro"} | _] =
               Enum.filter(Base.bitacora(50), &(&1.artefacto == c.maestro))
    end
  end

  describe "Release.Purga.cli/1 y Remoto" do
    test "ida y vuelta: la solicitud codificada se ejecuta y Remoto interpreta la respuesta", c do
      solicitud = %{
        "op" => "impacto",
        "artefacto" => c.maestro,
        "tablas" => c.tablas,
        "versiones" => [@version]
      }

      salida = capture_io(fn -> ReleasePurga.cli(ReleasePurga.codificar(solicitud)) end)

      assert {:ok, %{"filas" => 3, "versiones_aplicadas" => [@version]}} =
               Remoto.interpretar("ruido de logs\n" <> salida)
    end

    test "una solicitud ilegible responde error, no truena" do
      salida = capture_io(fn -> ReleasePurga.cli("no-es-base64!!") end)
      assert {:error, "Solicitud ilegible."} = Remoto.interpretar(salida)
    end

    test "Remoto.llamar arma el comando y reconoce una imagen sin bin/purga" do
      ejecutor = fn _amb, comando ->
        send(self(), {:comando, comando})
        {:ok, 126, "exec: \"/app/bin/purga\": stat /app/bin/purga: no such file or directory"}
      end

      assert {:error, :sin_purga} =
               Remoto.llamar(%{}, "unstable", %{"op" => "inventario"}, ejecutor)

      assert_received {:comando, comando}
      assert comando =~ "app=metadata-unstable"
      assert comando =~ "/app/bin/purga '"
    end

    test "Remoto rechaza un nombre de sistema que podría inyectar shell" do
      assert_raise ArgumentError, fn ->
        Remoto.comando("unstable; rm -rf /", %{"op" => "inventario"})
      end
    end
  end
end
