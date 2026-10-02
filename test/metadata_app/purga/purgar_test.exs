defmodule MetadataApp.Purga.PurgarTest do
  use ExUnit.Case, async: true

  alias MetadataApp.Purga
  alias MetadataApp.Purga.{GhFalso, Respaldo}

  @meta "priv/repo/catalogos/"
  @mig "priv/repo/migrations/"

  defp meta(nombre, encabezado) do
    {"#{@meta}#{nombre}.meta.json",
     Jason.encode!(%{
       "schema_context_name" => nombre,
       "schema_context_type" => 1,
       "schema_encabezado_catalogo" => encabezado
     })}
  end

  defp paquetes do
    %{
      "retirado-pty_a" =>
        Map.new([
          meta("pty_a", nil),
          meta("pty_a_det", "pty_a"),
          {"#{@mig}20260901000001_crear_pty_a_20260901000001.exs", "m"},
          {"#{@mig}20260901000002_crear_pty_a_det_20260901000002.exs", "m"}
        ]),
      "retirado-pty_viejo" =>
        Map.new([{"#{@mig}20260801000000_eliminar_pty_viejo_20260801000000.exs", "m"}]),
      "bc-pty_b" => Map.new([meta("pty_b", nil)])
    }
  end

  defp impacto(extra \\ %{}) do
    Map.merge(
      %{
        "imagen_incluye" => false,
        "dependencias" => [],
        "filas" => 3,
        "tablas" => [
          %{"nombre" => "pty_a_det", "tabla" => true, "objeto" => "tabla", "filas" => 1},
          %{"nombre" => "pty_a", "tabla" => true, "objeto" => "tabla", "filas" => 2}
        ]
      },
      extra
    )
  end

  setup do
    base = Path.join(System.tmp_dir!(), "purgar_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    yo = self()

    remoto = fn _ambiente, sistema, solicitud ->
      send(yo, {:remoto, sistema, solicitud})

      case solicitud["op"] do
        "impacto" -> {:ok, Process.get(:impacto, impacto())}
        "ejecutar" -> {:ok, %{"resultado" => "ok"}}
      end
    end

    ssh = fn _ambiente, comando ->
      send(yo, {:ssh, comando})

      Process.get(
        :ssh,
        {:ok, 0, "4096 /home/elixir/metadata-purgas/ennova/pty_a_20261002000000.dump
"}
      )
    end

    opts = [
      gh: GhFalso.funcion(GhFalso.iniciar(paquetes())),
      remoto: remoto,
      ssh: ssh,
      clientes: ["ennova"],
      cache_dir: Path.join(base, "cache"),
      tmp_dir: Path.join(base, "tmp")
    ]

    %{opts: opts}
  end

  defp confirmacion(nombre \\ "pty_a", filas \\ 3), do: %{nombre: nombre, filas: filas}

  describe "preparar/4" do
    test "sale del inventario: tablas (detalles primero) y versiones", %{opts: opts} do
      assert {:ok, prep} = Purga.preparar("pty_a", "testing", %{}, opts)

      assert prep.tablas == ["pty_a_det", "pty_a"]
      assert prep.versiones == [20_260_901_000_001, 20_260_901_000_002]
      refute prep.cliente
      assert prep.bloqueo == nil
      assert_received {:remoto, "testing", %{"op" => "impacto", "versiones" => [_, _]}}
    end

    test "una lápida: su nombre y las versiones de su inventario", %{opts: opts} do
      assert {:ok, %{tablas: ["pty_viejo"], versiones: [20_260_801_000_000]}} =
               Purga.preparar("pty_viejo", "stable", %{}, opts)
    end

    test "sin retiro no hay purga", %{opts: opts} do
      assert {:error, m} = Purga.preparar("pty_b", "testing", %{}, opts)
      assert m =~ "no está retirado"
    end

    test "destino que no es canal ni cliente", %{opts: opts} do
      assert {:error, m} = Purga.preparar("pty_a", "inventado", %{}, opts)
      assert m =~ "no es un canal ni un cliente"
    end

    test "bloqueo si la imagen todavía lo trae; el mensaje depende del destino", %{opts: opts} do
      Process.put(:impacto, impacto(%{"imagen_incluye" => true}))

      assert {:ok, %{bloqueo: b1}} = Purga.preparar("pty_a", "unstable", %{}, opts)
      assert b1 =~ "reconstruir unstable"
      assert {:ok, %{bloqueo: b2}} = Purga.preparar("pty_a", "stable", %{}, opts)
      assert b2 =~ "Propaga a stable"
    end
  end

  describe "purgar/6" do
    test "en un canal: ejecuta sin respaldo", %{opts: opts} do
      assert {:ok, %{"resultado" => "ok", "respaldo" => nil}} =
               Purga.purgar("pty_a", "testing", %{}, "dev@x.mx", confirmacion(), opts)

      assert_received {:remoto, "testing",
                       %{
                         "op" => "ejecutar",
                         "tablas" => ["pty_a_det", "pty_a"],
                         "filas_confirmadas" => 3,
                         "usuario_email" => "dev@x.mx"
                       }}

      refute_received {:ssh, _}
    end

    test "en un cliente: respalda primero y manda la ruta", %{opts: opts} do
      assert {:ok, %{"respaldo" => ruta}} =
               Purga.purgar("pty_a", "ennova", %{}, "dev@x.mx", confirmacion(), opts)

      assert ruta == "/home/elixir/metadata-purgas/ennova/pty_a_20261002000000.dump"
      assert_received {:ssh, comando}
      assert comando =~ "-t pty_a_det -t pty_a"
      assert_received {:remoto, "ennova", %{"op" => "ejecutar", "respaldo" => ^ruta}}
    end

    test "si el respaldo falla, no purga", %{opts: opts} do
      Process.put(:ssh, {:ok, 1, "pg_dump: error"})

      assert {:error, m} = Purga.purgar("pty_a", "ennova", %{}, "dev@x.mx", confirmacion(), opts)
      assert m =~ "No se purgó nada"
      refute_received {:remoto, _, %{"op" => "ejecutar"}}
    end

    test "un respaldo vacío también detiene la purga", %{opts: opts} do
      Process.put(:ssh, {:ok, 0, "0 /home/elixir/metadata-purgas/ennova/x.dump
"})
      assert {:error, _} = Purga.purgar("pty_a", "ennova", %{}, "dev@x.mx", confirmacion(), opts)
      refute_received {:remoto, _, %{"op" => "ejecutar"}}
    end

    test "nombre mal escrito o registros sin confirmar", %{opts: opts} do
      assert {:error, m1} =
               Purga.purgar("pty_a", "testing", %{}, "dev@x.mx", confirmacion("pty_A"), opts)

      assert m1 =~ "no coincide"

      assert {:error, m2} =
               Purga.purgar("pty_a", "testing", %{}, "dev@x.mx", confirmacion("pty_a", 0), opts)

      assert m2 =~ "tiene 3 registro(s)"
      refute_received {:remoto, _, %{"op" => "ejecutar"}}
    end

    test "con dependencias no ejecuta", %{opts: opts} do
      Process.put(
        :impacto,
        impacto(%{"dependencias" => ["La tabla pty_z tiene una llave foránea hacia pty_a."]})
      )

      assert {:error, m} = Purga.purgar("pty_a", "testing", %{}, "dev@x.mx", confirmacion(), opts)
      assert m =~ "pty_z"
      refute_received {:remoto, _, %{"op" => "ejecutar"}}
    end

    test "en un cliente sin tablas físicas (lápida) no hay nada que respaldar", %{opts: opts} do
      Process.put(
        :impacto,
        impacto(%{
          "filas" => 0,
          "tablas" => [%{"nombre" => "pty_viejo", "tabla" => false, "filas" => 0}]
        })
      )

      assert {:ok, %{"respaldo" => nil}} =
               Purga.purgar(
                 "pty_viejo",
                 "ennova",
                 %{},
                 "dev@x.mx",
                 confirmacion("pty_viejo", 0),
                 opts
               )

      refute_received {:ssh, _}
    end
  end

  describe "Respaldo.comando/3" do
    test "retención, pipefail y una bandera por tabla" do
      c =
        Respaldo.comando(
          "ennova",
          ["pty_a_det", "pty_a"],
          "pty_a_20261002000000.dump"
        )

      assert c =~ ~r/^bash -c '/
      assert c =~ "set -o pipefail"
      assert c =~ "-mtime +30 -delete"
      assert c =~ "pg_dump -U appuser -d db_ennova -Fc -t pty_a_det -t pty_a"
      assert c =~ ~s|"$HOME/metadata-purgas/ennova"/pty_a_20261002000000.dump|
      # Solo kubectl lleva sudo: el usuario SSH no tiene sudo sin contraseña
      # para nada más.
      assert length(String.split(c, "sudo")) == 2
    end

    test "rechaza nombres que podrían inyectar shell" do
      assert_raise ArgumentError, fn -> Respaldo.comando("ennova; rm -rf /", ["pty_a"], "/x") end
      assert_raise ArgumentError, fn -> Respaldo.comando("ennova", ["pty_a; rm"], "/x") end
      assert_raise ArgumentError, fn -> Respaldo.comando("ennova", [], "/x") end
    end
  end
end
