defmodule MetadataApp.BusinessProcessBuilder.FormatoCapturaTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente

  defp unique, do: System.unique_integer([:positive])

  # Mismo atajo que dependencias_referencia_test.exs: reusa los campos del
  # fixture meta_fixture_cliente (ya reales, con columnas string/decimal
  # de verdad) en vez de levantar un catálogo sintético — el motor de
  # "formato_captura" solo le pide cosas a la METADATA
  # (schema_context_properties), no a la columna física. Ningún test acá
  # inserta en base (solo `changeset.valid?`), así que insert_guid/unicidad
  # no aplican.
  defp detalle(campo) do
    header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
    Repo.get_by!(Detail, meta_schema_header_id: header.id, schema_context_field: campo)
  end

  defp con_formato_captura(campo, formato) do
    d = detalle(campo)
    props = Map.put(d.schema_context_properties, "formato_captura", formato)
    d |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()
    :ok
  end

  defp changeset_nombre(nombre) do
    MetaFixtureCliente.changeset(%MetaFixtureCliente{}, %{
      meta_fixture_cliente_nombre: nombre,
      meta_fixture_cliente_edad: 1,
      meta_fixture_cliente_venta: Decimal.new("1")
    })
  end

  defp changeset_venta(venta) do
    MetaFixtureCliente.changeset(%MetaFixtureCliente{}, %{
      meta_fixture_cliente_nombre: "cliente #{unique()}",
      meta_fixture_cliente_edad: 1,
      meta_fixture_cliente_venta: venta
    })
  end

  describe "validar_formato_captura/2 — texto posicional (con formato)" do
    setup do
      con_formato_captura("meta_fixture_cliente_nombre", %{
        "habilitada" => true,
        "modo" => "personalizada",
        "patron" => "999-999",
        "guardar_formato" => true,
        "estricto" => true,
        "permitir_incompleto" => false,
        "mensaje_invalido" => "formato inválido"
      })
    end

    test "acepta un valor que calza el patrón completo" do
      assert changeset_nombre("123-456").valid?
    end

    test "rechaza un valor que no calza (sin el separador literal)" do
      cs = changeset_nombre("123456")
      refute cs.valid?
      assert "formato inválido" in errors_on(cs).meta_fixture_cliente_nombre
    end

    test "rechaza un valor incompleto cuando permitir_incompleto es falso" do
      refute changeset_nombre("12").valid?
    end
  end

  describe "validar_formato_captura/2 — texto posicional (permitir_incompleto)" do
    setup do
      con_formato_captura("meta_fixture_cliente_nombre", %{
        "habilitada" => true,
        "modo" => "personalizada",
        "patron" => "999-999",
        "guardar_formato" => true,
        "permitir_incompleto" => true
      })
    end

    test "acepta un prefijo válido del patrón" do
      assert changeset_nombre("12").valid?
      assert changeset_nombre("123-").valid?
      assert changeset_nombre("123-45").valid?
    end

    test "sigue rechazando un valor que rompe la clase de un slot" do
      refute changeset_nombre("1A").valid?
    end
  end

  describe "validar_formato_captura/2 — texto posicional (solo datos)" do
    setup do
      con_formato_captura("meta_fixture_cliente_nombre", %{
        "habilitada" => true,
        "modo" => "personalizada",
        "patron" => "999-999",
        "guardar_formato" => false,
        "permitir_incompleto" => false
      })
    end

    test "con guardar_formato false, exige el valor SIN los literales del patrón" do
      assert changeset_nombre("123456").valid?
      refute changeset_nombre("123-456").valid?
    end
  end

  describe "validar_formato_captura/2 — número/moneda en un campo string" do
    setup do
      con_formato_captura("meta_fixture_cliente_nombre", %{
        "habilitada" => true,
        "modo" => "moneda",
        "decimales" => 2,
        "separador_miles" => true,
        "simbolo" => "$",
        "simbolo_posicion" => "prefijo",
        "permitir_negativos" => false,
        "guardar_formato" => false
      })
    end

    test "solo datos: acepta un número plano, rechaza símbolo/separadores" do
      assert changeset_nombre("1234567.50").valid?
      refute changeset_nombre("$1,234,567.50").valid?
    end

    test "solo datos: rechaza más decimales de los configurados" do
      refute changeset_nombre("1234567.505").valid?
    end

    test "solo datos: rechaza negativo cuando permitir_negativos es falso" do
      refute changeset_nombre("-1234567.50").valid?
    end
  end

  describe "validar_formato_captura/2 — número/moneda en un campo string (con formato)" do
    setup do
      con_formato_captura("meta_fixture_cliente_nombre", %{
        "habilitada" => true,
        "modo" => "moneda",
        "decimales" => 2,
        "separador_miles" => true,
        "simbolo" => "$",
        "simbolo_posicion" => "prefijo",
        "permitir_negativos" => true,
        "guardar_formato" => true
      })
    end

    test "con formato: acepta símbolo + separadores de miles" do
      assert changeset_nombre("$1,234,567.50").valid?
    end

    test "con formato: rechaza el número plano sin separadores (no es lo que se pidió guardar)" do
      refute changeset_nombre("1234567.50").valid?
    end

    test "con formato: acepta negativo cuando permitir_negativos es verdadero (símbolo antes del signo, como arma FormatoNumericoField)" do
      assert changeset_nombre("$-1,234,567.50").valid?
    end
  end

  describe "validar_formato_captura/2 — numérico (decimales)" do
    setup do
      con_formato_captura("meta_fixture_cliente_venta", %{
        "habilitada" => true,
        "modo" => "moneda",
        "decimales" => 1,
        "permitir_negativos" => false
      })
    end

    test "acepta un valor dentro del límite de decimales configurado" do
      assert changeset_venta(Decimal.new("10.5")).valid?
    end

    test "rechaza más decimales de los configurados (aunque la columna física permita más)" do
      cs = changeset_venta(Decimal.new("10.55"))
      refute cs.valid?
      assert "no puede tener más de 1 decimales" in errors_on(cs).meta_fixture_cliente_venta
    end

    test "rechaza negativo cuando permitir_negativos es falso" do
      cs = changeset_venta(Decimal.new("-5.0"))
      refute cs.valid?
      assert "no puede ser negativo" in errors_on(cs).meta_fixture_cliente_venta
    end
  end

  describe "validar_formato_captura/2 — numérico (permitir_negativos)" do
    setup do
      con_formato_captura("meta_fixture_cliente_venta", %{
        "habilitada" => true,
        "modo" => "moneda",
        "decimales" => 2,
        "permitir_negativos" => true
      })
    end

    test "acepta negativo cuando permitir_negativos es verdadero" do
      assert changeset_venta(Decimal.new("-5.00")).valid?
    end
  end

  describe "campos_con_formato_captura/1" do
    test "solo trae campos con habilitada == true" do
      con_formato_captura("meta_fixture_cliente_nombre", %{"habilitada" => true, "modo" => "personalizada", "patron" => "9"})
      con_formato_captura("meta_fixture_cliente_edad", %{"habilitada" => false})

      campos = MetaSchemaContext.campos_con_formato_captura("meta_fixture_cliente") |> Enum.map(& &1.schema_context_field)

      assert "meta_fixture_cliente_nombre" in campos
      refute "meta_fixture_cliente_edad" in campos
    end
  end
end
