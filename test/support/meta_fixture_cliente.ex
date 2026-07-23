defmodule MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente do
  @moduledoc false
  # Fixture de test permanente — ver migración
  # priv/repo/migrations/20260723220000_crear_fixtures_de_test.exs
  # (reemplaza a pty_clientes, que dejó de existir cuando ningún pty_* se
  # volvió a commitear). Vive en test/support/ (solo compila en MIX_ENV=test,
  # ver elixirc_paths en mix.exs), pero el namespace sigue siendo
  # MetaBusinessProcess.Catalogos porque MetaSchemaContext.modulo_por_nombre/1
  # siempre arma el módulo bajo ese namespace fijo al resolver un catálogo
  # por nombre — no hay forma de apuntar a otro lado sin tocar ese resolver.
  use MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico,
    tabla: "meta_fixture_cliente",
    campos: [
      {:meta_fixture_cliente_nombre, :string, %{}},
      {:meta_fixture_cliente_edad, :integer, %{}},
      {:meta_fixture_cliente_venta, :decimal, %{}}
    ]
end
