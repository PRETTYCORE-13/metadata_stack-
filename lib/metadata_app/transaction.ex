defmodule MetadataApp.Transaction do
  @moduledoc """
  Contrato que todo schema de un catálogo transaccional implementa (ver
  `MetadataApp.TRN`). Puramente declarativo — `MetadataApp.TRN` no llama
  `transaction_code/0` para generar (lee `codigo_trn` directo de
  `meta_schema_header`), pero deja el módulo generado autodescriptivo sin
  tener que consultar la base para saber su propio código.
  """

  @callback transaction_code() :: String.t()
end
