defmodule MetadataApp.MotorAlta.EstadoTest do
  use ExUnit.Case, async: true

  alias MetadataApp.MotorAlta.Estado

  # imagen_actual/2 real necesita SSH contra un servidor real (sin mock en
  # este proyecto, ver motor_alta_actualizacion_test.exs) -- estos tests
  # inyectan las 3 dependencias (mismo criterio que `path \\ ruta_sistemas()`
  # en el resto de MotorAlta) para cubrir la lógica nueva (paralelismo +
  # aislamiento de errores, R5) sin tocar SSH real.

  defp dependencias(canales, sistemas, fun_imagen_actual) do
    {fn -> canales end, fn -> sistemas end, fun_imagen_actual}
  end

  test "consulta todos los canales y sistemas, uno por fila" do
    fun = fn _ambiente, destino -> {:ok, "ghcr.io/x/metadata_stack:#{destino}-hash"} end
    dependencias = dependencias(["unstable", "testing", "stable"], %{"ennova" => %{}}, fun)

    resultados = Estado.consultar_todo(:ambiente_fake, dependencias)

    assert length(resultados) == 4
    assert %{destino: "unstable", tipo: :canal, resultado: {:ok, "ghcr.io/x/metadata_stack:unstable-hash"}} in resultados
    assert %{destino: "ennova", tipo: :sistema, resultado: {:ok, "ghcr.io/x/metadata_stack:ennova-hash"}} in resultados
  end

  test "un destino que falla no oculta el resultado de los demás (R5)" do
    fun = fn
      _ambiente, "testing" -> {:error, "SSH caído"}
      _ambiente, destino -> {:ok, "imagen-#{destino}"}
    end

    dependencias = dependencias(["unstable", "testing", "stable"], %{}, fun)

    resultados = Estado.consultar_todo(:ambiente_fake, dependencias)

    assert %{destino: "testing", resultado: {:error, "SSH caído"}} = Enum.find(resultados, &(&1.destino == "testing"))
    assert %{destino: "unstable", resultado: {:ok, "imagen-unstable"}} = Enum.find(resultados, &(&1.destino == "unstable"))
    assert %{destino: "stable", resultado: {:ok, "imagen-stable"}} = Enum.find(resultados, &(&1.destino == "stable"))
  end

  test "una excepción al consultar un destino se captura como error, sin abortar el resto" do
    fun = fn
      _ambiente, "testing" -> raise "boom"
      _ambiente, destino -> {:ok, "imagen-#{destino}"}
    end

    dependencias = dependencias(["unstable", "testing", "stable"], %{}, fun)

    resultados = Estado.consultar_todo(:ambiente_fake, dependencias)

    assert %{destino: "testing", resultado: {:error, mensaje}} = Enum.find(resultados, &(&1.destino == "testing"))
    assert mensaje =~ "boom"
    assert %{destino: "unstable", resultado: {:ok, _}} = Enum.find(resultados, &(&1.destino == "unstable"))
  end

  test "sin sistemas registrados, solo devuelve los 3 canales" do
    fun = fn _ambiente, destino -> {:ok, destino} end
    dependencias = dependencias(["unstable", "testing", "stable"], %{}, fun)

    resultados = Estado.consultar_todo(:ambiente_fake, dependencias)

    assert length(resultados) == 3
    assert Enum.all?(resultados, &(&1.tipo == :canal))
  end
end
