defmodule MetadataApp.BusinessProcessBuilder.FiltrosFijosReferenciaTest do
  @moduledoc """
  "Filtros fijos" de un campo referencia (SPEC-SYS-1109202601, R24-R28):
  acotar las opciones del combo a registros del destino con un valor
  constante en una columna (ej. Almacén con inventory_type = COMPROMETIDA),
  y validarlo del lado del servidor al guardar.
  """
  use MetadataApp.DataCase, async: true

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.BusinessProcessBuilder.{MetaSchemaContext, CatalogoGenerico}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
  alias MetadataApp.MetaBusinessProcess.Catalogos.{MetaFixtureCliente, MetaFixtureEquipo}

  @error_filtro "el valor seleccionado no cumple los filtros configurados para este campo"

  defp unique, do: System.unique_integer([:positive])
  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp crear_cliente(nombre, edad) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(%{
      meta_fixture_cliente_nombre: nombre,
      meta_fixture_cliente_edad: edad,
      meta_fixture_cliente_venta: Decimal.new("1")
    })
    |> Ecto.Changeset.change(%{insert_guid: guid()})
    |> Repo.insert!()
  end

  defp crear_equipo(nombre) do
    %MetaFixtureEquipo{}
    |> MetaFixtureEquipo.changeset(%{meta_fixture_equipo_nombre_equipo: nombre})
    |> Ecto.Changeset.change(%{insert_guid: guid()})
    |> Repo.insert!()
  end

  defp etiquetas(opciones), do: Enum.map(opciones, fn {_id, etiqueta} -> etiqueta end)

  describe "CatalogoGenerico.opciones_referencia/3 con filtros_fijos" do
    setup do
      s = unique()
      crear_cliente("comprometida #{s}", 10)
      crear_cliente("  Comprometida #{s}  ", 11)
      crear_cliente("disponible #{s}", 10)
      crear_cliente("otro #{s}", 10)
      %{s: s}
    end

    defp props(filtros),
      do: %{
        "catalogo" => "meta_fixture_cliente",
        "campos_acompanamiento" => ["meta_fixture_cliente_nombre"],
        "filtros_fijos" => filtros
      }

    test "O entre valores, ignorando mayúsculas y espacios", %{s: s} do
      filtros = [
        %{
          "campo" => "meta_fixture_cliente_nombre",
          "valores" => ["COMPROMETIDA #{s}", "DISPONIBLE #{s}"]
        }
      ]

      resultado =
        filtros |> props() |> CatalogoGenerico.opciones_referencia(%{}, nil) |> etiquetas()

      assert length(resultado) == 3
      refute Enum.any?(resultado, &(&1 =~ "otro #{s}"))
    end

    test "Y entre filtros", %{s: s} do
      filtros = [
        %{
          "campo" => "meta_fixture_cliente_nombre",
          "valores" => ["COMPROMETIDA #{s}", "DISPONIBLE #{s}"]
        },
        %{"campo" => "meta_fixture_cliente_edad", "valores" => ["11"]}
      ]

      assert filtros |> props() |> CatalogoGenerico.opciones_referencia(%{}, nil) |> etiquetas() ==
               ["  Comprometida #{s}  "]
    end

    test "se combina con los filtros de una dependencia sobre la misma columna (no se pisan)", %{
      s: s
    } do
      filtros = [
        %{
          "campo" => "meta_fixture_cliente_nombre",
          "valores" => ["COMPROMETIDA #{s}", "DISPONIBLE #{s}"]
        }
      ]

      resultado =
        filtros
        |> props()
        |> CatalogoGenerico.opciones_referencia(
          %{"meta_fixture_cliente_nombre" => "disponible #{s}"},
          nil
        )
        |> etiquetas()

      assert resultado == ["disponible #{s}"]
    end
  end

  describe "tabla de sistema (Almacén): filtro fijo + acotamiento por sucursal activa" do
    test "solo almacenes COMPROMETIDA de la sucursal activa; los que no tienen tipo quedan fuera" do
      dueno = usuario_fixture()

      {:ok, empresa} =
        Autenticacion.crear_empresa_para_usuario("Empresa filtros #{unique()}", dueno.id)

      {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})

      {:ok, otra_branch} =
        Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})

      crear = fn branch_id, nombre, tipo ->
        {:ok, a} =
          Autenticacion.crear_inventory_location(%{
            empresa_id: empresa.id,
            branch_id: branch_id,
            inventory_name: nombre,
            inventory_type: tipo
          })

        a
      end

      comprometida = crear.(branch.id, "Rutas", "COMPROMETIDA")
      crear.(branch.id, "Disponible", "DISPONIBLE")
      crear.(branch.id, "Sin tipo", nil)
      crear.(otra_branch.id, "Rutas Puebla", "comprometida")

      props = %{
        "catalogo" => "meta_schema_inventory_location",
        "filtros_fijos" => [%{"campo" => "inventory_type", "valores" => ["COMPROMETIDA"]}]
      }

      opciones =
        CatalogoGenerico.opciones_referencia(props, %{}, %Scope{branch_activo: %{id: branch.id}})

      assert Enum.map(opciones, &elem(&1, 0)) == [comprometida.id]
    end
  end

  describe "validar_filtros_fijos/2" do
    @campos [%{schema_context_field: "inventory_type"}, %{schema_context_field: "inventory_name"}]

    test "normaliza (trim + upcase, sin repetidos) y acepta texto separado por comas" do
      assert {:ok, [%{"campo" => "inventory_type", "valores" => ["COMPROMETIDA", "DISPONIBLE"]}]} =
               MetaSchemaContext.validar_filtros_fijos(
                 [
                   %{
                     "campo" => "inventory_type",
                     "valores" => " comprometida , Disponible,COMPROMETIDA,, "
                   }
                 ],
                 @campos
               )
    end

    test "descarta filas totalmente vacías" do
      assert {:ok, []} =
               MetaSchemaContext.validar_filtros_fijos(
                 [%{"campo" => "", "valores" => " , "}],
                 @campos
               )
    end

    test "rechaza sin campo, campo inexistente o sin valores" do
      assert {:error, _} =
               MetaSchemaContext.validar_filtros_fijos(
                 [%{"campo" => "", "valores" => "X"}],
                 @campos
               )

      assert {:error, msg} =
               MetaSchemaContext.validar_filtros_fijos(
                 [%{"campo" => "no_existe", "valores" => "X"}],
                 @campos
               )

      assert msg =~ "no_existe"

      assert {:error, _} =
               MetaSchemaContext.validar_filtros_fijos(
                 [%{"campo" => "inventory_type", "valores" => " "}],
                 @campos
               )
    end
  end

  describe "validación al guardar (R27)" do
    # Mismo atajo que DependenciasReferenciaTest: el campo entero "edad" del
    # fixture se reinterpreta como "referencia" a meta_fixture_equipo solo en
    # la METADATA, que es lo único que mira la validación.
    setup do
      header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")

      detalle_edad =
        Repo.get_by!(Detail,
          meta_schema_header_id: header.id,
          schema_context_field: "meta_fixture_cliente_edad"
        )

      s = unique()

      props =
        detalle_edad.schema_context_properties
        |> Map.put("tipo", "referencia")
        |> Map.put("catalogo", "meta_fixture_equipo")
        |> Map.put("filtros_fijos", [
          %{"campo" => "meta_fixture_equipo_nombre_equipo", "valores" => ["COMPROMETIDA #{s}"]}
        ])

      detalle_edad |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()

      %{
        cumple: crear_equipo("Comprometida #{s}"),
        no_cumple: crear_equipo("Disponible #{s}"),
        detalle: detalle_edad
      }
    end

    defp changeset_alta(equipo_id) do
      MetaFixtureCliente.changeset(%MetaFixtureCliente{}, %{
        meta_fixture_cliente_nombre: "cliente #{unique()}",
        meta_fixture_cliente_edad: equipo_id,
        meta_fixture_cliente_venta: Decimal.new("1")
      })
    end

    test "acepta un destino que cumple el filtro", %{cumple: equipo} do
      assert changeset_alta(equipo.id).valid?
    end

    test "rechaza un destino que no cumple el filtro", %{no_cumple: equipo} do
      changeset = changeset_alta(equipo.id)
      refute changeset.valid?
      assert @error_filtro in errors_on(changeset).meta_fixture_cliente_edad
    end

    test "no valida si el campo no cambió (registro viejo, filtro configurado después)", %{
      no_cumple: equipo
    } do
      existente = %MetaFixtureCliente{
        meta_fixture_cliente_nombre: "viejo",
        meta_fixture_cliente_edad: equipo.id,
        meta_fixture_cliente_venta: Decimal.new("1")
      }

      changeset =
        MetaFixtureCliente.changeset(existente, %{meta_fixture_cliente_nombre: "viejo editado"})

      refute @error_filtro in (errors_on(changeset)[:meta_fixture_cliente_edad] || [])
    end

    test "metadata mal formada (columna inexistente) no truena el guardado", %{
      no_cumple: equipo,
      detalle: detalle
    } do
      detalle = Repo.get!(Detail, detalle.id)

      props =
        Map.put(detalle.schema_context_properties, "filtros_fijos", [
          %{"campo" => "columna_que_no_existe_#{unique()}", "valores" => ["X"]}
        ])

      detalle |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()

      refute @error_filtro in (errors_on(changeset_alta(equipo.id))[:meta_fixture_cliente_edad] ||
                                 [])
    end
  end
end
