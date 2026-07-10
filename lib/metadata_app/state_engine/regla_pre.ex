defmodule MetadataApp.StateEngine.ReglaPre do
  @moduledoc """
  Contrato para una regla de PRECONDICIÓN de negocio, escrita por un equipo
  fuera del motor (convención: `NegocioReglas.<Catalogo>.<Regla>`, ver
  `MetadataApp.StateEngine.Reglas.modulo_negocio/2`).

  Reglas nunca deben actualizar datos — solo lectura. Para consultar OTRO
  catálogo (no el propio), usar `MetadataApp.BCCliente`, nunca
  `CatalogoGenerico`/`StateEngine` directamente.
  """

  @callback evaluar(registro :: struct(), contexto :: map(), params :: map()) ::
              :ok | {:error, String.t()}
end
