defmodule MetadataApp.Purga.Remoto do
  @moduledoc """
  Llama a `bin/purga` dentro del pod más reciente de `metadata-<sistema>`
  (SPEC-ARQ-3009202601, design §5): SSH + `kubectl exec`, mismo camino que
  `MotorAlta.rollback_base_datos/3`.

  `ejecutor`: `fn ambiente, comando -> {:ok, status, salida} | {:error, motivo} end`,
  con default a `MetadataApp.Ssh.ejecutar/2`. Solo se cambia en pruebas.
  """

  alias MetadataApp.Release.Purga

  @doc """
  Envía `solicitud` (mapa con `"op"`) a `sistema` y devuelve
  `{:ok, datos}` | `{:error, mensaje}`.
  """
  def llamar(ambiente, sistema, solicitud, ejecutor \\ &MetadataApp.Ssh.ejecutar/2) do
    case ejecutor.(ambiente, comando(sistema, solicitud)) do
      {:ok, 0, salida} -> interpretar(salida)
      {:ok, _status, salida} -> interpretar_o_error(salida)
      {:error, motivo} -> {:error, "SSH falló contra #{sistema}: #{inspect(motivo)}"}
    end
  end

  @doc false
  def comando(sistema, solicitud) do
    unless Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/, sistema),
      do: raise(ArgumentError, "sistema inválido: #{inspect(sistema)}")

    """
    POD=$(sudo k3s kubectl get pod -n metadata-stack -l app=metadata-#{sistema} --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}' | awk '{print $NF}') && \
    sudo k3s kubectl exec -n metadata-stack "$POD" -- /app/bin/purga '#{Purga.codificar(solicitud)}'
    """
    |> String.trim()
  end

  @doc false
  def interpretar(salida) do
    with linea when is_binary(linea) <- buscar_linea(salida),
         {:ok, json} <- Jason.decode(String.replace_prefix(linea, Purga.marca(), "")) do
      case json do
        %{"ok" => true, "datos" => datos} -> {:ok, datos}
        %{"ok" => false, "error" => error} -> {:error, error}
        _ -> {:error, "Respuesta inesperada: #{linea}"}
      end
    else
      _ ->
        {:error,
         "El destino no respondió PURGA_RESULTADO. Salida: #{String.slice(salida, 0, 500)}"}
    end
  end

  # "bin/purga" no existe en una imagen anterior a esta spec: lo decimos así
  # en vez de mostrar el error crudo de kubectl.
  defp interpretar_o_error(salida) do
    cond do
      buscar_linea(salida) -> interpretar(salida)
      salida =~ "bin/purga" and salida =~ ~r/not found|no such file/i -> {:error, :sin_purga}
      true -> {:error, String.trim(salida)}
    end
  end

  defp buscar_linea(salida) do
    salida
    |> String.split(~r/\r?\n/)
    |> Enum.find(&String.starts_with?(&1, Purga.marca()))
  end
end
