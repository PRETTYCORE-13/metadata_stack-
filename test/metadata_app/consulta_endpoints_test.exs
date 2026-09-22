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

  describe "exportar_endpoint/2 (SPEC-SYS-1009202602, design.md §13, R67/R69)" do
    defp dir_temporal! do
      dir = Path.join(System.tmp_dir!(), "consulta_endpoints_export_test_#{unique()}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      dir
    end

    test "escribe <consulta>.endpoint.json con empresa_nombre, nunca empresa_id ni credenciales" do
      empresa = empresa!()
      consulta = consulta_con_parametro!()
      {:ok, endpoint} = ConsultaEndpoints.crear_o_actualizar(consulta, attrs_base(consulta, empresa))
      clave = "meta_fixture_cliente__meta_fixture_cliente_nombre"
      {:ok, _credencial, _key} = ConsultaEndpoints.crear_credencial(endpoint, consulta, %{"nombre" => "ERP", "campos_permitidos" => [clave]})

      dir = dir_temporal!()
      nombre_consulta = ConsultaEndpoints.exportar_endpoint(endpoint, dir)

      header = MetaSchemaContext.obtener_header!(consulta.meta_schema_header_id)
      assert nombre_consulta == header.schema_context_name

      contenido = dir |> Path.join("#{nombre_consulta}.endpoint.json") |> File.read!() |> Jason.decode!()

      assert contenido["catalogo"] == nombre_consulta
      assert contenido["nombre"] == endpoint.nombre
      assert contenido["metodo"] == "get"
      assert contenido["estado"] == "borrador"
      assert contenido["empresa_nombre"] == empresa.nombre
      refute Map.has_key?(contenido, "empresa_id")
      refute Map.has_key?(contenido, "api_key_hash")
      refute Map.has_key?(contenido, "api_key_sufijo")
    end
  end

  describe "crear_registros_en_lote/3 (R77-R81, agregado 2026-09-21, design.md §17)" do
    alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
    alias MetadataApp.MetaSchema.Estado

    defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

    # meta_fixture_cliente no trae ningún estado por default -- sin
    # esto CatalogoGenerico.crear/4 rechaza con :motor_no_configurado
    # (mismo criterio que consulta_endpoint_controller_alta_test.exs).
    defp fixture_estado_inicial! do
      header = MetaSchemaContext.obtener_header_por_nombre("meta_fixture_cliente")

      %Estado{}
      |> Estado.changeset(%{meta_schema_header_id: header.id, orden: unique(), nombre: "inicial_#{unique()}", es_inicial: true})
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert!()
    end

    defp endpoint_con_alta!(empresa) do
      consulta = consulta_con_parametros!(%{})

      {:ok, endpoint} =
        ConsultaEndpoints.crear_o_actualizar(consulta, %{
          "nombre" => "Alta en lote test",
          "metodo" => "post",
          "ruta" => "lote-#{unique()}",
          "empresa_id" => empresa.id,
          "parametros" => [],
          "permite_alta" => true,
          "campos_alta" => ~w(meta_fixture_cliente_nombre meta_fixture_cliente_edad meta_fixture_cliente_venta)
        })

      {endpoint, consulta}
    end

    test "lote completo válido -> {:ok, [ids]} en el mismo orden, todos persistidos" do
      fixture_estado_inicial!()
      empresa = empresa!()
      {endpoint, consulta} = endpoint_con_alta!(empresa)

      lote =
        for n <- 1..5 do
          %{
            "meta_fixture_cliente_nombre" => "cliente lote #{n}_#{unique()}",
            "meta_fixture_cliente_edad" => 20 + n,
            "meta_fixture_cliente_venta" => "10.00"
          }
        end

      assert {:ok, ids} = ConsultaEndpoints.crear_registros_en_lote(endpoint, consulta, lote)
      assert length(ids) == 5

      registros = Enum.map(ids, &Repo.get!(MetaFixtureCliente, &1))
      assert Enum.map(registros, & &1.meta_fixture_cliente_edad) == Enum.map(21..25, & &1)
    end

    test "un elemento inválido en el medio del lote -> {:error, {indice, motivo}}, NADA queda persistido" do
      fixture_estado_inicial!()
      empresa = empresa!()
      {endpoint, consulta} = endpoint_con_alta!(empresa)
      total_antes = Repo.aggregate(MetaFixtureCliente, :count)

      lote = [
        %{"meta_fixture_cliente_nombre" => "válido 1 #{unique()}", "meta_fixture_cliente_edad" => 20, "meta_fixture_cliente_venta" => "1.00"},
        %{"meta_fixture_cliente_nombre" => "válido 2 #{unique()}", "meta_fixture_cliente_edad" => 21, "meta_fixture_cliente_venta" => "2.00"},
        # posición 2 (0-based) -- sin nombre, el campo obligatorio del catálogo.
        %{"meta_fixture_cliente_edad" => 22, "meta_fixture_cliente_venta" => "3.00"},
        %{"meta_fixture_cliente_nombre" => "válido 4 #{unique()}", "meta_fixture_cliente_edad" => 23, "meta_fixture_cliente_venta" => "4.00"}
      ]

      assert {:error, {2, _motivo}} = ConsultaEndpoints.crear_registros_en_lote(endpoint, consulta, lote)
      assert Repo.aggregate(MetaFixtureCliente, :count) == total_antes
    end
  end
end
