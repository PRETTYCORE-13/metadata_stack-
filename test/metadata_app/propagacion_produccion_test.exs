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
