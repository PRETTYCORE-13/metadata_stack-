defmodule MetadataApp.Purga.ReleasesTest do
  use ExUnit.Case, async: true

  alias MetadataApp.Purga
  alias MetadataApp.Purga.{GhFalso, Releases}

  @cat "lib/metadata_app/meta_business_process/catalogos/"
  @meta "priv/repo/catalogos/"
  @mig "priv/repo/migrations/"

  defp meta(nombre, opts) do
    {"#{@meta}#{nombre}.meta.json",
     Jason.encode!(%{
       "schema_context_name" => nombre,
       "schema_context_type" => Keyword.get(opts, :tipo, 1),
       "schema_encabezado_catalogo" => Keyword.get(opts, :encabezado)
     })}
  end

  defp catalogo(nombre, ts, opts \\ []) do
    [
      meta(nombre, opts),
      {"#{@cat}#{nombre}.ex", "ex"},
      {"#{@mig}#{ts}_crear_#{nombre}_#{ts}.exs", "mig"}
    ]
  end

  # pty_a con detalle pty_a_det; pty_b referencia a pty_a (su paquete trae
  # a pty_a); una carpeta que trae a los dos; y una lápida.
  defp paquetes do
    a =
      catalogo("pty_a", "20260901000001") ++
        catalogo("pty_a_det", "20260901000002", encabezado: "pty_a")

    b = catalogo("pty_b", "20260901000003")

    %{
      "bc-pty_a" =>
        Map.new(a ++ [{"lib/metadata_app/meta_business_process/reglas/pty_a/regla.ex", "r"}]),
      "bc-pty_b" => Map.new(b ++ a),
      "bc-pty_carpeta_x" => Map.new([meta("pty_carpeta_x", tipo: 2)] ++ a ++ b),
      "bc-pty_viejo" =>
        Map.new([
          {"#{@mig}20260801000000_crear_pty_viejo_20260801000000.exs", "m"},
          {"#{@mig}20260802000000_eliminar_pty_viejo_20260802000000.exs", "m"}
        ]),
      "bc-endpoint_pty_b_1" => Map.new([{"#{@meta}endpoint_pty_b_1.endpoint.json", "{}"}])
    }
  end

  describe "artefactos/1" do
    test "catálogos con su unidad y lápidas; sin carpetas ni endpoints" do
      arts = Releases.artefactos(paquetes())

      assert Enum.map(arts, &{&1.nombre, &1.tipo}) == [
               {"pty_a", :catalogo},
               {"pty_b", :catalogo},
               {"pty_viejo", :lapida}
             ]

      assert %{
               tablas: ["pty_a_det", "pty_a"],
               paquetes: ["bc-pty_a", "bc-pty_b", "bc-pty_carpeta_x"]
             } = hd(arts)
    end
  end

  describe "artefactos/1: versiones y retirados" do
    test "cada artefacto trae las versiones de sus migraciones" do
      arts = Map.new(Releases.artefactos(paquetes()), &{&1.nombre, &1})

      assert arts["pty_a"].versiones == [20_260_901_000_001, 20_260_901_000_002]
      assert arts["pty_viejo"].versiones == [20_260_801_000_000, 20_260_802_000_000]
    end

    test "una lápida retirada sigue en la lista (sin paquetes bc)" do
      p =
        paquetes()
        |> Map.put("retirado-pty_viejo", paquetes()["bc-pty_viejo"])
        |> Map.delete("bc-pty_viejo")

      assert %{tipo: :lapida, retirado: true, paquetes: [], versiones: [_, _]} =
               Enum.find(Releases.artefactos(p), &(&1.nombre == "pty_viejo"))
    end

    test "presente?/2: por header o, si es lápida, por una versión aplicada" do
      arts = Map.new(Releases.artefactos(paquetes()), &{&1.nombre, &1})
      inv = %{"unidades" => [%{"maestro" => "pty_a"}], "versiones" => [20_260_802_000_000]}

      assert Purga.presente?(arts["pty_a"], inv)
      assert Purga.presente?(arts["pty_viejo"], inv)
      refute Purga.presente?(arts["pty_b"], inv)
    end
  end

  describe "archivos_de/3" do
    test "toma .ex, .meta.json, reglas y migraciones de la unidad, nada más" do
      rutas = Map.keys(paquetes()["bc-pty_a"]) ++ Map.keys(paquetes()["bc-pty_b"])

      archivos =
        Releases.archivos_de(["pty_a_det", "pty_a"], Enum.uniq(rutas), [
          "pty_a",
          "pty_a_det",
          "pty_b"
        ])

      assert length(archivos) == 7
      refute Enum.any?(archivos, &String.contains?(&1, "pty_b"))
    end
  end

  describe "plan_retiro/2" do
    test "saca a X de los paquetes que lo traen y borra su bc propio" do
      assert {:ok, plan} = Releases.plan_retiro("pty_a", paquetes())

      assert plan.tablas == ["pty_a_det", "pty_a"]

      assert Enum.map(plan.modificados, & &1.tag) |> Enum.sort() == [
               "bc-pty_b",
               "bc-pty_carpeta_x"
             ]

      assert plan.bc_propio == :borrar
      assert map_size(plan.inventario) == 7

      b = Enum.find(plan.modificados, &(&1.tag == "bc-pty_b"))
      assert b.archivos |> Map.keys() |> Enum.all?(&String.contains?(&1, "pty_b"))
    end

    test "conserva bc-X si lo que queda solo viaja ahí" do
      # bc-pty_z trae a pty_z y a pty_b, que pty_z referencia.
      z = Map.new(catalogo("pty_z", "20260901000009") ++ catalogo("pty_b", "20260901000003"))
      b = Map.new(catalogo("pty_b", "20260901000003"))

      assert {:ok, %{bc_propio: :borrar}} =
               Releases.plan_retiro("pty_z", %{"bc-pty_z" => z, "bc-pty_b" => b})

      assert {:ok, %{bc_propio: {:conservar, _, ["pty_b"]}}} =
               Releases.plan_retiro("pty_z", %{"bc-pty_z" => z})
    end

    test "una lápida sale completa" do
      assert {:ok, plan} = Releases.plan_retiro("pty_viejo", paquetes())
      assert plan.tipo == :lapida
      assert plan.bc_propio == :borrar
      assert Releases.versiones(plan.inventario) == [20_260_801_000_000, 20_260_802_000_000]
    end

    test "bloquea si un paquete quedaría vacío" do
      paquetes =
        Map.put(paquetes(), "bc-pty_solo_a", Map.new(catalogo("pty_a", "20260901000001")))

      assert {:error, mensaje} = Releases.plan_retiro("pty_a", paquetes)
      assert mensaje =~ "bc-pty_solo_a"
    end

    test "detalle, carpeta y desconocido" do
      assert {:error, m1} = Releases.plan_retiro("pty_a_det", paquetes())
      assert m1 =~ "es detalle de pty_a"
      assert {:error, m2} = Releases.plan_retiro("pty_carpeta_x", paquetes())
      assert m2 =~ "carpeta de navegación"
      assert {:error, _} = Releases.plan_retiro("pty_nada", paquetes())
    end
  end

  test "empaquetar/2 y extraer/1 van y vuelven", %{} do
    dir = Path.join(System.tmp_dir!(), "purga_rt_#{System.unique_integer([:positive])}")
    archivos = paquetes()["bc-pty_a"]

    assert Releases.extraer(Releases.empaquetar(archivos, dir)) == archivos
    File.rm_rf!(dir)
  end

  describe "Purga.retirar/4 con gh en memoria" do
    setup do
      gh = GhFalso.iniciar(paquetes())
      base = Path.join(System.tmp_dir!(), "purga_gh_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(base) end)

      remoto = fn _ambiente, "unstable", solicitud ->
        send(self(), {:remoto, solicitud})

        case solicitud["op"] do
          "impacto" -> {:ok, %{"dependencias" => Process.get(:dependencias, [])}}
          "registrar" -> {:ok, %{"registro_id" => 1}}
        end
      end

      opts = [
        gh: GhFalso.funcion(gh),
        remoto: remoto,
        cache_dir: Path.join(base, "cache"),
        tmp_dir: Path.join(base, "tmp")
      ]

      %{gh: gh, opts: opts}
    end

    test "retira: inventario, paquetes re-subidos sin X, bc propio borrado y bitácora", %{
      gh: gh,
      opts: opts
    } do
      assert {:ok, %{resultado: "ok", bc_propio: :borrado} = r} =
               Purga.retirar("pty_a", %{}, "dev@x.mx", opts)

      assert Enum.sort(r.modificados) == ["bc-pty_b", "bc-pty_carpeta_x"]

      releases = GhFalso.releases(gh)
      refute Map.has_key?(releases, "bc-pty_a")
      assert map_size(releases["retirado-pty_a"]) == 7
      refute releases["bc-pty_b"] |> Map.keys() |> Enum.any?(&String.contains?(&1, "pty_a"))

      assert releases["bc-pty_carpeta_x"]
             |> Map.keys()
             |> Enum.any?(&String.contains?(&1, "pty_carpeta_x"))

      assert_received {:remoto,
                       %{
                         "op" => "registrar",
                         "registro" => %{"accion" => "retiro", "resultado" => "ok"}
                       }}
    end

    test "repetirlo no falla: sin cambios", %{opts: opts} do
      assert {:ok, %{resultado: "ok"}} = Purga.retirar("pty_a", %{}, "dev@x.mx", opts)
      assert {:ok, %{resultado: "sin_cambios"}} = Purga.retirar("pty_a", %{}, "dev@x.mx", opts)
    end

    test "con dependencias en unstable no toca GitHub", %{gh: gh, opts: opts} do
      Process.put(:dependencias, [
        "El catálogo pty_q tiene un campo que referencia a este artefacto."
      ])

      assert {:error, mensaje} = Purga.retirar("pty_a", %{}, "dev@x.mx", opts)
      assert mensaje =~ "pty_q"
      assert GhFalso.releases(gh) == paquetes()
      assert_received {:remoto, %{"op" => "registrar", "registro" => %{"resultado" => "error"}}}
    end

    test "una lápida se retira sin consultar dependencias", %{gh: gh, opts: opts} do
      assert {:ok, %{resultado: "ok"}} = Purga.retirar("pty_viejo", %{}, "dev@x.mx", opts)
      refute_received {:remoto, %{"op" => "impacto"}}
      assert Map.has_key?(GhFalso.releases(gh), "retirado-pty_viejo")
    end

    test "borrar_inventario se niega si X sigue en algún destino", %{gh: gh, opts: opts} do
      {:ok, _} = Purga.retirar("pty_a", %{}, "dev@x.mx", opts)

      assert {:error, m} = Purga.borrar_inventario("pty_a", ["testing"], opts)
      assert m =~ "testing"
      assert :ok = Purga.borrar_inventario("pty_a", [], opts)
      refute Map.has_key?(GhFalso.releases(gh), "retirado-pty_a")
    end
  end
end
