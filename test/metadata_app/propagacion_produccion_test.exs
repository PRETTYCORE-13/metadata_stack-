defmodule MetadataApp.PropagacionProduccionTest do
  use ExUnit.Case, async: true

  alias MetadataApp.{MotorAlta, PropagacionProduccion}

  # imagen_actual/2 real necesita SSH contra el servidor (sin mock en este
  # proyecto): se inyectan las dependencias, mismo criterio que
  # MotorAlta.EstadoTest.

  @stable "ghcr.io/x/metadata_stack:abc123"

  defp dependencias(sistemas, fun_imagen_actual), do: {fn -> sistemas end, fun_imagen_actual}

  describe "A1 -- campos piloto/version_fijada en priv/sistemas.json" do
    @tag :tmp_dir
    test "leer_sistemas/1 y sistema_registrado?/2 siguen igual con los campos nuevos", %{tmp_dir: dir} do
      path = Path.join(dir, "sistemas.json")

      File.write!(path, """
      {
        "prueba-a": {"alta": "2026-10-08", "dominio": "prueba-a.ventaenruta.com.mx", "piloto": true},
        "prueba-b": {"alta": "2026-10-08", "dominio": "prueba-b.ventaenruta.com.mx", "version_fijada": "ghcr.io/x/metadata_stack:viejo"}
      }
      """)

      sistemas = MotorAlta.leer_sistemas(path)

      assert Map.keys(sistemas) |> Enum.sort() == ["prueba-a", "prueba-b"]
      assert sistemas["prueba-a"]["dominio"] == "prueba-a.ventaenruta.com.mx"
      assert sistemas["prueba-a"]["piloto"] == true
      assert sistemas["prueba-b"]["version_fijada"] == "ghcr.io/x/metadata_stack:viejo"
      assert MotorAlta.sistema_registrado?("prueba-a", path)
    end
  end

  describe "A2 -- elegibles/2" do
    test "clasifica al día, versión fijada, elegible (piloto o no) y error de SSH" do
      sistemas = %{
        "al-dia" => %{},
        "fijado" => %{"version_fijada" => "ghcr.io/x/metadata_stack:viejo"},
        "normal" => %{},
        "piloto" => %{"piloto" => true},
        "caido" => %{}
      }

      fun = fn
        _ambiente, "stable" -> {:ok, @stable}
        _ambiente, "al-dia" -> {:ok, @stable}
        _ambiente, "fijado" -> flunk("un cliente con version_fijada no se consulta")
        _ambiente, "caido" -> {:error, "SSH caído"}
        _ambiente, _otro -> {:ok, "ghcr.io/x/metadata_stack:viejo"}
      end

      assert {:ok, @stable, lista} = PropagacionProduccion.elegibles(:ambiente_fake, dependencias(sistemas, fun))

      assert lista == [
               {"al-dia", {:no_elegible, :al_dia, @stable}},
               {"caido", {:error, "SSH caído"}},
               {"fijado", {:no_elegible, :version_fijada, "ghcr.io/x/metadata_stack:viejo"}},
               {"normal", {:elegible, "ghcr.io/x/metadata_stack:viejo", false}},
               {"piloto", {:elegible, "ghcr.io/x/metadata_stack:viejo", true}}
             ]
    end

    test "una excepción consultando un cliente no rompe a los demás" do
      sistemas = %{"explota" => %{}, "normal" => %{}}

      fun = fn
        _ambiente, "stable" -> {:ok, @stable}
        _ambiente, "explota" -> raise "conexión rechazada"
        _ambiente, "normal" -> {:ok, @stable}
      end

      assert {:ok, @stable, lista} = PropagacionProduccion.elegibles(:ambiente_fake, dependencias(sistemas, fun))
      assert {"explota", {:error, mensaje}} = List.keyfind(lista, "explota", 0)
      assert mensaje =~ "conexión rechazada"
      assert {"normal", {:no_elegible, :al_dia, @stable}} = List.keyfind(lista, "normal", 0)
    end

    test "un cliente marcado activo: false no aparece" do
      sistemas = %{"apagado" => %{"activo" => false}, "normal" => %{}}
      fun = fn _ambiente, _destino -> {:ok, @stable} end

      assert {:ok, @stable, [{"normal", _}]} = PropagacionProduccion.elegibles(:ambiente_fake, dependencias(sistemas, fun))
    end
  end

  describe "B1 -- identidad_actual/1" do
    test "devuelve el login sin espacios ni saltos de línea" do
      fun_gh = fn ["api", "user", "--jq", ".login"] -> {"X4GUSS\n", 0} end

      assert {:ok, "X4GUSS"} = PropagacionProduccion.identidad_actual(fun_gh)
    end

    test "gh sin sesión o sin instalar -- error con la salida de gh" do
      fun_gh = fn _args -> {"To get started with GitHub CLI, please run:  gh auth login\n", 4} end

      assert {:error, mensaje} = PropagacionProduccion.identidad_actual(fun_gh)
      assert mensaje =~ "gh auth login"
    end
  end

  describe "C1 -- registrar_intento/3" do
    test "agrega (>>) en el archivo del registro, con la línea en base64 (R11, R11a)" do
      motivo = ~s|REL-1 "urgente" $(rm -rf ~) `id` año|
      linea = %{tipo: "lote", motivo: motivo, clientes: %{piloto: ["a"], resto: ["b"]}}
      test_pid = self()

      fun_ssh = fn :ambiente_fake, comando ->
        send(test_pid, {:comando, comando})
        {:ok, 0, ""}
      end

      assert :ok = PropagacionProduccion.registrar_intento(:ambiente_fake, linea, fun_ssh)
      assert_received {:comando, comando}

      assert comando =~ ">> /home/elixir/metadata-propagaciones/propagaciones.jsonl"
      refute comando =~ ~r/[^>]> /
      refute comando =~ "rm -rf"
      refute comando =~ "urgente"

      [_, b64] = Regex.run(~r/echo (\S+) \| base64 -d/, comando)
      decodificada = Base.decode64!(b64)
      assert String.ends_with?(decodificada, "\n")
      assert Jason.decode!(decodificada)["motivo"] == motivo
    end

    test "si el servidor responde con error, lo devuelve" do
      fun_ssh = fn _ambiente, _comando -> {:ok, 1, "Permission denied\n"} end

      assert {:error, mensaje} = PropagacionProduccion.registrar_intento(:ambiente_fake, %{}, fun_ssh)
      assert mensaje =~ "Permission denied"
    end
  end

  describe "C2 -- listar_intentos/2" do
    test "más reciente primero, saltando una línea dañada" do
      contenido = """
      {"ts":"2026-10-01T10:00:00Z","motivo":"uno"}
      {"ts":"2026-10-02T10:00:00Z","motivo":"dos"}
      esto no es json
      {"ts":"2026-10-03T10:00:00Z","motivo":"tres"}
      """

      fun_ssh = fn _ambiente, comando ->
        assert comando =~ "cat /home/elixir/metadata-propagaciones/propagaciones.jsonl"
        {:ok, 0, contenido}
      end

      assert {:ok, intentos} = PropagacionProduccion.listar_intentos(:ambiente_fake, fun_ssh)
      assert Enum.map(intentos, & &1["motivo"]) == ["tres", "dos", "uno"]
    end

    test "si el archivo no existe todavía, lista vacía" do
      fun_ssh = fn _ambiente, _comando -> {:ok, 0, ""} end

      assert {:ok, []} = PropagacionProduccion.listar_intentos(:ambiente_fake, fun_ssh)
    end

    test "si no hay conexión, error" do
      fun_ssh = fn _ambiente, _comando -> {:error, "ssh: connect to host: timeout"} end

      assert {:error, "ssh: connect to host: timeout"} = PropagacionProduccion.listar_intentos(:ambiente_fake, fun_ssh)
    end
  end

  describe "A3 -- imagen_stable/2 (R3a)" do
    test "con :latest en stable se rechaza y no se consulta a ningún cliente" do
      fun = fn
        _ambiente, "stable" -> {:ok, "ghcr.io/x/metadata_stack:latest"}
        _ambiente, cliente -> flunk("no debía consultar a #{cliente}")
      end

      deps = dependencias(%{"normal" => %{}}, fun)

      assert {:error, mensaje} = PropagacionProduccion.imagen_stable(:ambiente_fake, deps)
      assert mensaje =~ "--commit=<hash>"
      assert {:error, ^mensaje} = PropagacionProduccion.elegibles(:ambiente_fake, deps)
    end

    test "con etiqueta fija devuelve la imagen completa" do
      fun = fn _ambiente, "stable" -> {:ok, @stable} end

      assert {:ok, @stable} = PropagacionProduccion.imagen_stable(:ambiente_fake, dependencias(%{}, fun))
    end

    test "si no se puede consultar stable, lo dice" do
      fun = fn _ambiente, "stable" -> {:error, "SSH caído"} end

      assert {:error, mensaje} = PropagacionProduccion.imagen_stable(:ambiente_fake, dependencias(%{}, fun))
      assert mensaje =~ "SSH caído"
    end
  end
end
