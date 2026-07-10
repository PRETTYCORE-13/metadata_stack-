defmodule MetadataApp.MetaStateEngine.ReglaPost do
  @moduledoc """
  Contrato para una regla de POSTCONDICIÓN de negocio, escrita por un
  equipo fuera del motor (convención: `MetadataApp.MetaBusinessProcess.Reglas.<Catalogo>.<Regla>`,
  ver `MetadataApp.MetaStateEngine.Reglas.modulo_negocio/2`).

  Puede crear/actualizar/borrar datos — del propio registro o, vía
  `MetadataApp.MetaBcCliente`, de otros catálogos (nunca tocando
  `CatalogoGenerico`/`MetaStateEngine` de otro catálogo directamente).
  """

  @callback ejecutar(registro :: struct(), contexto :: map(), params :: map(), repo :: module()) ::
              {:ok, term()} | {:error, term()}
end
