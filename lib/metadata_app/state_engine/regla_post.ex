defmodule MetadataApp.StateEngine.ReglaPost do
  @moduledoc """
  Contrato para una regla de POSTCONDICIÓN de negocio, escrita por un
  equipo fuera del motor (convención: `NegocioReglas.<Catalogo>.<Regla>`,
  ver `MetadataApp.StateEngine.Reglas.modulo_negocio/2`).

  Puede crear/actualizar/borrar datos — del propio registro o, vía
  `MetadataApp.BCCliente`, de otros catálogos (nunca tocando
  `CatalogoGenerico`/`StateEngine` de otro catálogo directamente).
  """

  @callback ejecutar(registro :: struct(), contexto :: map(), params :: map(), repo :: module()) ::
              {:ok, term()} | {:error, term()}
end
