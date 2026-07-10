defmodule NegocioReglas.PtyAlyMarcas.NoCocacola do
  @behaviour MetadataApp.StateEngine.ReglaPre

  @impl true
  def evaluar(registro, _contexto, _params) do
    if registro.pty_aly_marca_nombre == "COCACOLA" do
      {:error, "el nombre de la marca no puede ser COCACOLA"}
    else
      :ok
    end
  end
end
