defmodule MetadataApp.ConsultaEndpointsTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.MetaConsultas
  alias MetadataApp.ConsultaEndpoints
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.Autenticacion.Empresa

  defp unique, do: System.unique_integer([:positive])

  defp empresa! do
    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa endpoints ctx test #{unique()}"}) |> Repo.insert()

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
    consulta_con_parametros!(%{"meta_fixture_cliente_nombre" => %{"tipo" => "string"}})
  end

  defp consulta_con_parametros!(overrides_por_campo) do
    header = header_vacio("consulta_endpoints_ctx_#{unique()}")
    {:ok, consulta} = MetaConsultas.crear(header, "meta_fixture_cliente")

    campos =
      Enum.map(consulta.campos, fn campo ->
        case Map.get(overrides_por_campo, campo["campo"]) do
          nil -> campo
          extra -> Map.merge(campo, Map.merge(extra, %{"es_parametro" => true}))
        end
      end)

    {:ok, consulta} = MetaConsultas.actualizar_campos(consulta, campos)
    consulta
  end

  defp attrs_base(_consulta, empresa) do
    %{
      "nombre" => "Ventas por cliente",
      "metodo" => "get",
      "ruta" => "ventas-cliente-#{unique()}",
      "empresa_id" => empresa.id
    }
  end

  describe "crear_o_actualizar/2" do
    test "crea uno nuevo con insert_guid" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()

      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))

      assert endpoint.meta_schema_consulta_id == consulta.id
      assert endpoint.estado == "borrador"
      refute is_nil(endpoint.insert_guid)
    end

    test "una segunda llamada actualiza el mismo registro, no crea otro" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()

      {:ok, endpoint1} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))
      {:ok, endpoint2} = ConsultaEndpoints.crear_o_actualizar(consulta, Map.put(attrs_base(consulta, empresa), "nombre", "Otro nombre"))

      assert endpoint1.id == endpoint2.id
      assert endpoint2.nombre == "Otro nombre"
      refute is_nil(endpoint2.update_guid)
    end

    test "empresa_id no cambia en una actualización aunque attrs traiga otro" do
      empresa_original = empresa!()
      otra_empresa = empresa!()
      consulta = consulta_con_parametro!()

      {:ok, _endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa_original))

      {:ok, endpoint} =
        ConsultaEndpoints.crear_o_actualizar(consulta, Map.put(attrs_base(consulta, otra_empresa), "empresa_id", otra_empresa.id))

      assert endpoint.empresa_id == empresa_original.id
    end
  end

  describe "publicar/1, despublicar/1" do
    test "publicar/1 solo cambia el estado, sin tocar ninguna key" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))

      {:ok, publicado} = ConsultaEndpoints.publicar(endpoint)

      assert publicado.estado == "publicado"
    end

    test "despublicar/1 vuelve a borrador" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))
      {:ok, publicado} = ConsultaEndpoints.publicar(endpoint)

      {:ok, despublicado} = ConsultaEndpoints.despublicar(publicado)

      assert despublicado.estado == "borrador"
    end
  end

  describe "credenciales (R19.1, R42-R46)" do
    test "crear_credencial/3 genera hash+sufijo y devuelve la key en claro" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))
      clave = "meta_fixture_cliente__meta_fixture_cliente_nombre"

      {:ok, credencial, key} =
        ConsultaEndpoints.crear_credencial(endpoint, consulta, %{"nombre" => "ERP", "campos_permitidos" => [clave]})

      assert credencial.estado == "activa"
      assert credencial.campos_permitidos == [clave]
      assert String.ends_with?(key, credencial.api_key_sufijo)
      assert ConsultaEndpoints.resolver_credencial(endpoint.id, key).id == credencial.id
    end

    test "crear_credencial/3 rechaza un campo que no es visible del endpoint" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))

      assert {:error, changeset} =
               ConsultaEndpoints.crear_credencial(endpoint, consulta, %{
                 "nombre" => "ERP",
                 "campos_permitidos" => ["no__existe"]
               })

      refute changeset.valid?
    end

    test "no exige que el endpoint esté publicado (R46)" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))
      assert endpoint.estado == "borrador"

      assert {:ok, _credencial, _key} =
               ConsultaEndpoints.crear_credencial(endpoint, consulta, %{"nombre" => "ERP", "campos_permitidos" => []})
    end

    test "regenerar_api_key_credencial/1 invalida la key anterior sin afectar otras credenciales" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))

      {:ok, credencial_erp, key_erp_vieja} =
        ConsultaEndpoints.crear_credencial(endpoint, consulta, %{"nombre" => "ERP", "campos_permitidos" => []})

      {:ok, _credencial_tienda, key_tienda} =
        ConsultaEndpoints.crear_credencial(endpoint, consulta, %{"nombre" => "Tienda", "campos_permitidos" => []})

      {:ok, regenerada, key_erp_nueva} = ConsultaEndpoints.regenerar_api_key_credencial(credencial_erp)

      assert key_erp_nueva != key_erp_vieja
      assert ConsultaEndpoints.resolver_credencial(endpoint.id, key_erp_vieja) == nil
      assert ConsultaEndpoints.resolver_credencial(endpoint.id, key_erp_nueva).id == regenerada.id
      assert ConsultaEndpoints.resolver_credencial(endpoint.id, key_tienda).nombre == "Tienda"
    end

    test "revocar_credencial/1 la inutiliza sin afectar a las demás, y sigue listada" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))

      {:ok, credencial_erp, key_erp} =
        ConsultaEndpoints.crear_credencial(endpoint, consulta, %{"nombre" => "ERP", "campos_permitidos" => []})

      {:ok, _credencial_tienda, key_tienda} =
        ConsultaEndpoints.crear_credencial(endpoint, consulta, %{"nombre" => "Tienda", "campos_permitidos" => []})

      {:ok, revocada} = ConsultaEndpoints.revocar_credencial(credencial_erp)

      assert revocada.estado == "revocada"
      assert ConsultaEndpoints.resolver_credencial(endpoint.id, key_erp) == nil
      assert ConsultaEndpoints.resolver_credencial(endpoint.id, key_tienda).nombre == "Tienda"

      nombres = endpoint.id |> ConsultaEndpoints.listar_credenciales() |> Enum.map(& &1.nombre)
      assert Enum.sort(nombres) == ["ERP", "Tienda"]
    end
  end

  describe "obtener_publicado/2" do
    test "nil para borrador y para inexistente" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      ruta = "obtener-publicado-#{unique()}"
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, Map.put(attrs_base(consulta, empresa), "ruta", ruta))

      assert ConsultaEndpoints.obtener_publicado("get", ruta) == nil
      assert ConsultaEndpoints.obtener_publicado("get", "no-existe-#{unique()}") == nil

      {:ok, _publicado} = ConsultaEndpoints.publicar(endpoint)

      assert %{ruta: ^ruta} = ConsultaEndpoints.obtener_publicado("get", ruta)
      assert ConsultaEndpoints.obtener_publicado("post", ruta) == nil
    end
  end

  describe "probar/3" do
    test "ejecuta la Consulta con el scope y overrides dados, sin exigir que exista un endpoint" do
      consulta = consulta_con_parametro!()

      %MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente{}
      |> MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente.changeset(%{
        meta_fixture_cliente_nombre: "probar_ctx_#{unique()}",
        meta_fixture_cliente_edad: 40,
        meta_fixture_cliente_venta: Decimal.new("1.00")
      })
      |> Ecto.Changeset.put_change(:insert_guid, Ecto.UUID.generate() |> String.replace("-", ""))
      |> Repo.insert!()

      clave = "meta_fixture_cliente__meta_fixture_cliente_nombre"

      resultado =
        ConsultaEndpoints.probar(consulta, :sistema, %{
          clave => %{"defaults" => %{"valor" => "probar_ctx"}}
        })

      assert resultado.total_filas >= 1
    end
  end

  describe "construir_overrides/3" do
    test "un parámetro string simple, presente en los valores externos" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))
      clave = "meta_fixture_cliente__meta_fixture_cliente_nombre"

      {:ok, endpoint} =
        ConsultaEndpoints.crear_o_actualizar(consulta, %{
          "nombre" => endpoint.nombre,
          "metodo" => endpoint.metodo,
          "ruta" => endpoint.ruta,
          "parametros" => [%{"campo" => clave, "obligatorio" => true}]
        })

      assert {:ok, overrides} = ConsultaEndpoints.construir_overrides(consulta, endpoint, %{clave => "ana"})
      assert overrides == %{clave => %{"defaults" => %{"valor" => "ana"}}}
    end

    test "ignora una clave externa que no está configurada como parámetro (R13)" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))

      assert {:ok, overrides} = ConsultaEndpoints.construir_overrides(consulta, endpoint, %{"empresa_id" => "999"})
      assert overrides == %{}
    end

    test "un parámetro numérico ACOTADO necesita las dos claves _desde/_hasta" do
      empresa = empresa!()
      consulta = consulta_con_parametros!(%{"meta_fixture_cliente_edad" => %{"tipo" => "integer", "acotado" => true}})
      clave = "meta_fixture_cliente__meta_fixture_cliente_edad"

      {:ok, endpoint} =
        ConsultaEndpoints.crear_o_actualizar(consulta, %{
          "nombre" => "Edad",
          "metodo" => "get",
          "ruta" => "edad-#{unique()}",
          "empresa_id" => empresa.id,
          "parametros" => [%{"campo" => clave, "obligatorio" => false}]
        })

      assert {:ok, overrides} =
               ConsultaEndpoints.construir_overrides(consulta, endpoint, %{
                 "#{clave}_desde" => "18",
                 "#{clave}_hasta" => "65"
               })

      assert overrides == %{clave => %{"defaults" => %{"valor" => "18", "valor_hasta" => "65"}}}
    end

    test "error si falta un parámetro obligatorio" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      clave = "meta_fixture_cliente__meta_fixture_cliente_nombre"

      {:ok, endpoint} =
        ConsultaEndpoints.crear_o_actualizar(consulta, %{
          "nombre" => "Ventas",
          "metodo" => "get",
          "ruta" => "ventas-#{unique()}",
          "empresa_id" => empresa.id,
          "parametros" => [%{"campo" => clave, "obligatorio" => true}]
        })

      assert {:error, {:parametros_faltantes, [^clave]}} =
               ConsultaEndpoints.construir_overrides(consulta, endpoint, %{})
    end
  end
end
