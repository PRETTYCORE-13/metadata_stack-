defmodule MetadataApp.PropagacionProduccion do
  @moduledoc """
  Propagación a producción de clientes, por oleadas
  (SPEC-ARQ-3009202602). Envuelve el mecanismo de un solo cliente de
  `MotorAlta` (SPEC-ARQ-1809202603); nunca lo reimplementa.

  Todo trabaja con la imagen COMPLETA (`ghcr.io/…/metadata_stack:<etiqueta>`),
  que es lo que devuelve `MotorAlta.imagen_actual/2` (design §6).
  """

  alias MetadataApp.MotorAlta

  @dependencias_default {&MotorAlta.leer_sistemas/0, &MotorAlta.imagen_actual/2}

  @doc """
  Imagen que corre en `stable`, solo si tiene etiqueta fija (R3a): con
  `:latest`, "misma etiqueta" no significa "misma imagen", así que no se
  puede saber qué cliente está al día ni qué se le instalaría.

  `{:ok, imagen}` | `{:error, mensaje}`.

  `dependencias` -- `{fun_leer_sistemas/0, fun_imagen_actual/2}`, con
  default a las funciones reales de `MotorAlta`; parametrizable solo para
  tests (mismo criterio que `MotorAlta.Estado.consultar_todo/2`).
  """
  def imagen_stable(ambiente, dependencias \\ @dependencias_default) do
    {_fun_leer_sistemas, fun_imagen_actual} = dependencias

    case fun_imagen_actual.(ambiente, "stable") do
      {:ok, imagen} ->
        if String.ends_with?(imagen, ":latest") do
          {:error,
           "stable corre #{imagen}, una etiqueta que cambia de contenido -- propaga antes a stable " <>
             "una imagen por hash (mix motor.propagar_extension <ambiente> testing stable --commit=<hash>)."}
        else
          {:ok, imagen}
        end

      {:error, motivo} ->
        {:error, "no se pudo consultar la imagen de stable: #{motivo}"}
    end
  end

  @doc """
  Estado de cada cliente de `priv/sistemas.json` frente a `stable`
  (R2, R2a, R4, R4b):

  - `{:elegible, imagen_actual, piloto?}`
  - `{:no_elegible, :al_dia, imagen}` -- ya tiene la imagen de stable
  - `{:no_elegible, :version_fijada, version}` -- nunca elegible (R4b)
  - `{:error, motivo}` -- no se pudo consultar; no afecta a los demás

  `{:ok, imagen_stable, [{cliente, estado}]}` (ordenado por nombre) |
  `{:error, mensaje}` si stable no tiene etiqueta fija (R3a): en ese caso
  no se consulta a ningún cliente.

  Los clientes se consultan en paralelo (mismo criterio que
  `MotorAlta.Estado`): con muchos clientes, en serie multiplicaría la
  espera por SSH.
  """
  def elegibles(ambiente, dependencias \\ @dependencias_default) do
    {fun_leer_sistemas, fun_imagen_actual} = dependencias

    with {:ok, imagen_stable} <- imagen_stable(ambiente, dependencias) do
      clientes =
        fun_leer_sistemas.()
        |> Enum.filter(fn {_nombre, datos} -> Map.get(datos, "activo", true) end)
        |> Enum.sort_by(&elem(&1, 0))

      lista =
        clientes
        |> Task.async_stream(
          fn {nombre, datos} -> {nombre, estado(ambiente, nombre, datos, imagen_stable, fun_imagen_actual)} end,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.zip(clientes)
        |> Enum.map(fn
          {{:ok, resultado}, _} -> resultado
          {{:exit, _}, {nombre, _}} -> {nombre, {:error, "timeout consultando este cliente"}}
        end)

      {:ok, imagen_stable, lista}
    end
  end

  defp estado(ambiente, nombre, datos, imagen_stable, fun_imagen_actual) do
    case Map.get(datos, "version_fijada") do
      fijada when fijada not in [nil, ""] ->
        {:no_elegible, :version_fijada, fijada}

      _ ->
        case fun_imagen_actual.(ambiente, nombre) do
          {:ok, ^imagen_stable} -> {:no_elegible, :al_dia, imagen_stable}
          {:ok, otra} -> {:elegible, otra, Map.get(datos, "piloto", false) == true}
          {:error, motivo} -> {:error, motivo}
        end
    end
  rescue
    e -> {:error, "excepción consultando #{nombre}: #{Exception.message(e)}"}
  end
end
