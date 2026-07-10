defmodule MetadataApp.MetaStateEngine.ReglaPre do
  @moduledoc """
  Contrato para una regla de PRECONDICIÓN de negocio, escrita por un equipo
  fuera del motor (convención: `MetadataApp.MetaBusinessProcess.Reglas.<Catalogo>.<Regla>`, ver
  `MetadataApp.MetaStateEngine.Reglas.modulo_negocio/2`).

  Reglas nunca deben actualizar datos — solo lectura. Para consultar OTRO
  catálogo (no el propio), usar `MetadataApp.MetaBcCliente`, nunca
  `CatalogoGenerico`/`MetaStateEngine` directamente.
  """

  @callback evaluar(registro :: struct(), contexto :: map(), params :: map()) ::
              :ok | {:error, String.t()}
end
