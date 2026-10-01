defmodule MetadataApp.Release.Purga do
  @moduledoc """
  Entrada de `bin/purga` dentro del pod de un sistema destino
  (SPEC-ARQ-3009202601, design §5). Recibe una solicitud JSON en base64
  (nada de comillas que escapar en el shell remoto) y responde con un solo
  renglón `PURGA_RESULTADO:<json>`, que `MetadataApp.Purga.Remoto` busca
  entre el resto de la salida.

  `bin/purga` la invoca con `rpc`, dentro del nodo vivo, para que la purga
  invalide las cachés del servidor que atiende a los usuarios. Si se
  invoca con `eval` (nodo aparte), levanta el Repo por su cuenta.
  """

  alias MetadataApp.Purga.Base, as: PurgaBase

  @marca "PURGA_RESULTADO:"

  def marca, do: @marca

  def cli(b64) do
    resultado =
      case decodificar(b64) do
        {:ok, solicitud} -> con_repo(fn -> despachar(solicitud) end)
        error -> error
      end

    IO.puts(@marca <> Jason.encode!(serializar(resultado)))
  end

  @doc "Codifica una solicitud para `cli/1` (lado local)."
  def codificar(solicitud), do: solicitud |> Jason.encode!() |> Base.encode64()

  @doc false
  def decodificar(b64) do
    with {:ok, json} <- Base.decode64(b64),
         {:ok, %{"op" => _} = solicitud} <- Jason.decode(json) do
      {:ok, solicitud}
    else
      _ -> {:error, "Solicitud ilegible."}
    end
  end

  @doc false
  def despachar(%{"op" => "inventario"}), do: {:ok, PurgaBase.inventario()}

  def despachar(%{"op" => "impacto", "artefacto" => artefacto, "tablas" => tablas} = s)
      when is_list(tablas) do
    PurgaBase.impacto(artefacto, tablas, versiones(s))
  end

  def despachar(
        %{
          "op" => "ejecutar",
          "artefacto" => artefacto,
          "tablas" => tablas,
          "usuario_email" => email
        } = s
      )
      when is_list(tablas) and is_binary(email) do
    PurgaBase.ejecutar(%{
      artefacto: artefacto,
      tablas: tablas,
      versiones: versiones(s),
      filas_confirmadas: s["filas_confirmadas"] || 0,
      usuario_email: email,
      respaldo: s["respaldo"]
    })
  end

  def despachar(%{"op" => "bitacora"} = s), do: {:ok, PurgaBase.bitacora(s["limite"] || 200)}

  def despachar(%{"op" => "registrar", "registro" => attrs}) when is_map(attrs) do
    case PurgaBase.registrar(attrs) do
      {:ok, registro} ->
        {:ok, %{registro_id: registro.id}}

      {:error, changeset} ->
        {:error, "No se pudo registrar en la bitácora: #{inspect(changeset.errors)}"}
    end
  end

  def despachar(_), do: {:error, "Operación desconocida o incompleta."}

  defp versiones(s), do: Enum.filter(s["versiones"] || [], &is_integer/1)

  defp con_repo(fun) do
    if Process.whereis(MetadataApp.Repo) do
      fun.()
    else
      Application.load(:metadata_app)
      {:ok, resultado, _} = Ecto.Migrator.with_repo(MetadataApp.Repo, fn _repo -> fun.() end)
      resultado
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp serializar({:ok, datos}), do: %{ok: true, datos: datos}
  defp serializar({:error, mensaje}) when is_binary(mensaje), do: %{ok: false, error: mensaje}
  defp serializar({:error, otro}), do: %{ok: false, error: inspect(otro)}
end
