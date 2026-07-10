defmodule MetadataApp.MetaBusinessProcess.Reglas.PtyAlyMarcas.PepsiEsLoDeHoy do
  @behaviour MetadataApp.MetaStateEngine.ReglaPost

  import Ecto.Query

  @impl true
  def ejecutar(registro, _contexto, _params, repo) do
    if registro.pty_aly_marca_nombre == "PEPSI" do
      nuevo_nombre = registro.pty_aly_marca_nombre <> " PEPSI ES LO DE HOY"

      {1, _} =
        repo.update_all(from(t in registro.__struct__, where: t.id == ^registro.id),
          set: [pty_aly_marca_nombre: nuevo_nombre]
        )

      {:ok, %{nombre_final: nuevo_nombre}}
    else
      {:ok, :sin_cambios}
    end
  end
end
