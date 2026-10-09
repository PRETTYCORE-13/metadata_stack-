defmodule Mix.Tasks.Meta.HuerfanosTest do
  @moduledoc "Huérfanos con confirmación (SPEC-SYS-0210202601, R6)."
  # Mix.shell/1 es global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Meta.Huerfanos

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)

    dir = Path.join(System.tmp_dir!(), "huerfanos_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    for archivo <- [
          "vigente.meta.json",
          "de_otro.meta.json",
          "ajeno.meta.json",
          "vigente.motor.json"
        ] do
      File.write!(Path.join(dir, archivo), "{}")
    end

    %{dir: dir}
  end

  defp existe?(dir, archivo), do: File.exists?(Path.join(dir, archivo))

  test "sin confirmar no borra nada y lo dice", %{dir: dir} do
    send(self(), {:mix_shell_input, :yes?, false})

    assert {:conservados, ["ajeno.meta.json", "de_otro.meta.json"]} =
             Huerfanos.limpiar(dir, ["vigente"], ".meta.json")

    assert existe?(dir, "ajeno.meta.json") and existe?(dir, "de_otro.meta.json")
    assert_received {:mix_shell, :yes?, [pregunta]}
    assert pregunta =~ "Pueden ser de otra persona"
    assert_received {:mix_shell, :info, ["No se borró ninguno."]}
  end

  test "con confirmación borra solo los huérfanos del sufijo", %{dir: dir} do
    send(self(), {:mix_shell_input, :yes?, true})

    assert {:borrados, ["ajeno.meta.json", "de_otro.meta.json"]} =
             Huerfanos.limpiar(dir, ["vigente"], ".meta.json")

    refute existe?(dir, "ajeno.meta.json")
    assert existe?(dir, "vigente.meta.json")
    assert existe?(dir, "vigente.motor.json")
  end

  test "sin huérfanos no pregunta", %{dir: dir} do
    assert :sin_huerfanos = Huerfanos.limpiar(dir, ["vigente"], ".motor.json")
    refute_received {:mix_shell, :yes?, _}
  end

  test "excluir deja fuera archivos que nunca son huérfanos", %{dir: dir} do
    send(self(), {:mix_shell_input, :yes?, true})

    assert {:borrados, ["ajeno.meta.json"]} =
             Huerfanos.limpiar(dir, ["vigente"], ".meta.json",
               excluir: &(&1 == "de_otro.meta.json")
             )

    assert existe?(dir, "de_otro.meta.json")
  end

  test "con el shell real, un Enter vacío no borra (Mix.Shell.IO toma \"\" como sí por default)",
       %{dir: dir} do
    Mix.shell(Mix.Shell.IO)

    salida =
      ExUnit.CaptureIO.capture_io("\n", fn ->
        assert {:conservados, _} = Huerfanos.limpiar(dir, ["vigente"], ".meta.json")
      end)

    assert salida =~ "[yN]"
    assert existe?(dir, "ajeno.meta.json")
  end
end
