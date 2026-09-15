defmodule MetadataApp.MetaSchema.ConsultaEndpointTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.MetaConsultas
  alias MetadataApp.MetaSchema.ConsultaEndpoint
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.Autenticacion.Empresa

  defp unique, do: System.unique_integer([:positive])

  defp empresa! do
    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa endpoint test #{unique()}"}) |> Repo.insert()

    empresa
  end

  defp header_vacio(nombre) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => nombre,
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 3,
        "detalles" => []
      })

    header
  end

  defp consulta_con_parametro! do
    header = header_vacio("consulta_endpoint_test_#{unique()}")
    {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")

    campos =
      Enum.map(consulta.campos, fn campo ->
        if campo["campo"] == "meta_fixture_cliente_nombre" do
          Map.merge(campo, %{"tipo" => "string", "es_parametro" => true})
        else
          campo
        end
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)
    consulta
  end

  defp attrs_base(consulta, empresa) do
    %{
      "meta_schema_consulta_id" => consulta.id,
      "nombre" => "Ventas por cliente",
      "metodo" => "get",
      "ruta" => "ventas-cliente-#{unique()}",
      "empresa_id" => empresa.id
    }
  end

  describe "changeset/3" do
    test "válido con los campos requeridos" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()

      changeset = ConsultaEndpoint.changeset(%ConsultaEndpoint{}, attrs_base(consulta, empresa), consulta)

      assert changeset.valid?
    end

    test "rechaza método fuera de get/post" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()

      changeset =
        ConsultaEndpoint.changeset(
          %ConsultaEndpoint{},
          Map.put(attrs_base(consulta, empresa), "metodo", "delete"),
          consulta
        )

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).metodo
    end

    test "rechaza ruta con mayúsculas o barras" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()

      for ruta_invalida <- ["Ventas-Cliente", "ventas/cliente", "ventas_cliente"] do
        changeset =
          ConsultaEndpoint.changeset(
            %ConsultaEndpoint{},
            Map.put(attrs_base(consulta, empresa), "ruta", ruta_invalida),
            consulta
          )

        refute changeset.valid?, "esperaba inválida: #{ruta_invalida}"
      end
    end

    test "R8.1 -- rechaza un parámetro que ya no es Parámetro vigente de la Consulta" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()

      clave = "meta_fixture_cliente__meta_fixture_cliente_nombre"

      attrs =
        attrs_base(consulta, empresa)
        |> Map.put("parametros", [%{"campo" => clave, "obligatorio" => true}])

      changeset = ConsultaEndpoint.changeset(%ConsultaEndpoint{}, attrs, consulta)
      assert changeset.valid?

      # Se desmarca "es_parametro" del lado de la Consulta -- el mismo
      # `parametros` de antes ahora debe romper el guardado (R8.1).
      campos_sin_parametro =
        Enum.map(consulta.campos, fn campo -> Map.put(campo, "es_parametro", false) end)

      {:ok, consulta_actualizada} = MetaConsultas.actualizar_campos(consulta, campos_sin_parametro)

      changeset_roto =
        ConsultaEndpoint.changeset(%ConsultaEndpoint{}, attrs, consulta_actualizada)

      refute changeset_roto.valid?
      assert errors_on(changeset_roto).parametros != nil
    end

    test "sin Consulta pasada, no valida R8.1 (changeset aislado)" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()

      attrs =
        attrs_base(consulta, empresa)
        |> Map.put("parametros", [%{"campo" => "no__existe", "obligatorio" => true}])

      changeset = ConsultaEndpoint.changeset(%ConsultaEndpoint{}, attrs, nil)
      assert changeset.valid?
    end
  end
end
