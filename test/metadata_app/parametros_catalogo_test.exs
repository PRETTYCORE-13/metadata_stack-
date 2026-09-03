defmodule MetadataApp.ParametrosCatalogoTest do
  @moduledoc """
  SPEC-SYS-0209202601, Grupo A — motor de Parámetro estándar, probado
  AISLADO (sin `%Consulta{}`, sin ningún LiveView): contra `campos ::
  [map()]` de verdad y una query Ecto con named binding armada a mano,
  exactamente como la usaría un catálogo (BC) normal (ver design.md §1.3)
  -- MetaFixtureCliente es un catálogo real (no un mock), Postgres real.
  """
  use MetadataApp.DataCase, async: true

  import Ecto.Query

  alias MetadataApp.Repo
  alias MetadataApp.ParametrosCatalogo
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp fixture_cliente(nombre, edad) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(%{meta_fixture_cliente_nombre: nombre, meta_fixture_cliente_edad: edad, meta_fixture_cliente_venta: Decimal.new("1.00")})
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp query_base do
    from(r in MetaFixtureCliente, as: :t0, where: is_nil(r.delete_guid))
  end

  @alias_por_catalogo %{"meta_fixture_cliente" => :t0}

  defp campo(campo, tipo, extra \\ %{}) do
    Map.merge(%{"catalogo" => "meta_fixture_cliente", "campo" => campo, "tipo" => tipo, "visible" => true, "es_parametro" => true}, extra)
  end

  describe "campos_elegibles_*/1 — mapas planos, sin Consulta" do
    test "filtra por visible + es_parametro + tipo, sin importar el origen de los mapas" do
      campos = [
        campo("meta_fixture_cliente_nombre", "string"),
        campo("meta_fixture_cliente_edad", "integer", %{"es_parametro" => false}),
        campo("meta_fixture_cliente_venta", "decimal", %{"visible" => false}),
        %{"catalogo" => "meta_fixture_cliente", "campo" => "fecha_registro", "tipo" => "date", "visible" => true, "es_parametro" => true}
      ]

      assert Enum.map(ParametrosCatalogo.campos_elegibles_string(campos), & &1["campo"]) == ["meta_fixture_cliente_nombre"]
      assert ParametrosCatalogo.campos_elegibles_numerico(campos) == []
      assert Enum.map(ParametrosCatalogo.campos_elegibles_fecha(campos), & &1["campo"]) == ["fecha_registro"]
    end
  end

  describe "tipo_efectivo/1" do
    test "campo normal -- el tipo guardado tal cual" do
      assert ParametrosCatalogo.tipo_efectivo(%{"tipo" => "integer"}) == "integer"
    end

    test "campo de control referencia (branch/inventory_location/sales_unit) -- siempre \"referencia\" aunque tipo sea nil" do
      assert ParametrosCatalogo.tipo_efectivo(%{"control" => true, "campo" => "branch", "tipo" => nil}) == "referencia"
    end
  end

  describe "aplicar_filtros_parametro_estandar/4 — contra Postgres real" do
    test "string \"like\" filtra de verdad" do
      _a = fixture_cliente("Juan Pérez", 30)
      _b = fixture_cliente("María López", 25)

      campos = [campo("meta_fixture_cliente_nombre", "string", %{"defaults" => %{"valor" => "Pérez"}, "tipo_filtro" => "like"})]

      resultado = ParametrosCatalogo.aplicar_filtros_parametro_estandar(query_base(), campos, @alias_por_catalogo, %{}) |> Repo.all()
      assert Enum.map(resultado, & &1.meta_fixture_cliente_nombre) == ["Juan Pérez"]
    end

    test "numérico \"entre\" (acotado) filtra de verdad" do
      _a = fixture_cliente("A", 20)
      _b = fixture_cliente("B", 30)
      _c = fixture_cliente("C", 40)

      campos = [campo("meta_fixture_cliente_edad", "integer", %{"acotado" => true, "defaults" => %{"valor" => 25, "valor_hasta" => 35}})]

      resultado = ParametrosCatalogo.aplicar_filtros_parametro_estandar(query_base(), campos, @alias_por_catalogo, %{}) |> Repo.all()
      assert Enum.map(resultado, & &1.meta_fixture_cliente_edad) == [30]
    end

    test "overrides_parametro pisa el default del admin sin persistir nada" do
      _a = fixture_cliente("Juan", 30)
      _b = fixture_cliente("Pedro", 30)

      campos = [campo("meta_fixture_cliente_nombre", "string", %{"defaults" => %{"valor" => "Juan"}, "tipo_filtro" => "like"})]
      clave = to_string(ParametrosCatalogo.clave_campo(%{"catalogo" => "meta_fixture_cliente", "campo" => "meta_fixture_cliente_nombre"}))
      overrides = %{clave => %{"defaults" => %{"valor" => "Pedro"}}}

      resultado = ParametrosCatalogo.aplicar_filtros_parametro_estandar(query_base(), campos, @alias_por_catalogo, overrides) |> Repo.all()
      assert Enum.map(resultado, & &1.meta_fixture_cliente_nombre) == ["Pedro"]
    end

    test "sin es_parametro, no filtra nada aunque tenga defaults" do
      _a = fixture_cliente("Juan", 30)
      _b = fixture_cliente("Pedro", 40)

      campos = [campo("meta_fixture_cliente_nombre", "string", %{"es_parametro" => false, "defaults" => %{"valor" => "Juan"}})]

      resultado = ParametrosCatalogo.aplicar_filtros_parametro_estandar(query_base(), campos, @alias_por_catalogo, %{}) |> Repo.all()
      assert length(resultado) == 2
    end
  end
end
