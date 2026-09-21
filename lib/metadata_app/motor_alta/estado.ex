defmodule MetadataApp.MotorAlta.Estado do
  @moduledoc """
  `mix motor.estado_extension` (SPEC-SYS-1809202603 R4-R5) -- qué imagen
  corre AHORA MISMO en los 3 canales (`MotorAlta.canales/0`) y en cada
  cliente de `priv/sistemas.json`, consultados en una sola corrida.

  `imagen_actual/2` (`MotorAlta`) ya existe -- este módulo solo agrega la
  parte nueva: consultar N destinos EN PARALELO (para que varios clientes
  no multipliquen el tiempo de espera de forma lineal) sin que un destino
  que falla (SSH caído, deployment inexistente) oculte el resultado de
  los demás (R5).
  """

  alias MetadataApp.MotorAlta

  @dependencias_default {&MotorAlta.canales/0, &MotorAlta.leer_sistemas/0, &MotorAlta.imagen_actual/2}

  @doc """
  Consulta todos los destinos (3 canales + cada sistema de
  `priv/sistemas.json`) contra `ambiente` -- en paralelo, un resultado por
  destino, nunca abortado por el error de uno solo.

  `dependencias` -- `{fun_canales/0, fun_leer_sistemas/0, fun_imagen_actual/2}`,
  con default a las funciones reales de `MotorAlta`. Parametrizable solo
  para tests (mismo criterio que `path \\\\ ruta_sistemas()` en el resto de
  `MotorAlta`) -- nunca se llama con otra cosa fuera de un test, `imagen_actual/2`
  necesita SSH real y no tiene mock en este proyecto (ver
  `test/metadata_app/motor_alta_actualizacion_test.exs`, comentario al
  inicio: "sin cobertura automática acá" para lo que depende de SSH real).
  """
  def consultar_todo(ambiente, dependencias \\ @dependencias_default) do
    {fun_canales, fun_leer_sistemas, fun_imagen_actual} = dependencias

    destinos =
      Enum.map(fun_canales.(), &{&1, :canal}) ++
        Enum.map(Map.keys(fun_leer_sistemas.()), &{&1, :sistema})

    destinos
    |> Task.async_stream(
      fn {destino, tipo} -> {destino, tipo, consultar_uno(ambiente, destino, fun_imagen_actual)} end,
      timeout: 30_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(destinos)
    |> Enum.map(fn
      {{:ok, {destino, tipo, resultado}}, _} ->
        %{destino: destino, tipo: tipo, resultado: resultado}

      {{:exit, _motivo}, {destino, tipo}} ->
        %{destino: destino, tipo: tipo, resultado: {:error, "timeout consultando este destino"}}
    end)
  end

  defp consultar_uno(ambiente, destino, fun_imagen_actual) do
    fun_imagen_actual.(ambiente, destino)
  rescue
    e -> {:error, "excepción consultando #{destino}: #{Exception.message(e)}"}
  end
end
