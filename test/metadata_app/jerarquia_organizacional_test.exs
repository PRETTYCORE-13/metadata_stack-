defmodule MetadataApp.JerarquiaOrganizacionalTest do
  @moduledoc """
  Fase 0 del modelo de Alcance de Datos (2026-08-11) — jerarquía
  Empresa -> Branch -> {SalesUnit, InventoryLocation}. Prueba real contra
  Postgres: creación, denormalización de empresa_id en las hojas, y que el
  borrado de una Branch con hijos vivos se bloquea (mismo criterio que
  eliminar_empresa/1).
  """
  use MetadataApp.DataCase

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Branch
  alias MetadataApp.Repo

  defp fixture_empresa do
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa jerarquia #{System.unique_integer()}", usuario_fixture().id)
    empresa
  end

  test "crea la jerarquía completa y las hojas quedan con empresa_id denormalizado" do
    empresa = fixture_empresa()

    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})
    assert branch.empresa_id == empresa.id

    {:ok, unidad} =
      Autenticacion.crear_sales_unit(%{
        empresa_id: empresa.id,
        branch_id: branch.id,
        sales_unit_name: "Preventa 1",
        sales_unit_type: "preventa"
      })

    {:ok, ubicacion} =
      Autenticacion.crear_inventory_location(%{
        empresa_id: empresa.id,
        branch_id: branch.id,
        inventory_name: "Producto terminado",
        inventory_type: "almacen",
        inventory_function: "producto_terminado"
      })

    # La denormalización es lo que se prueba acá -- empresa_id vive en la
    # hoja SIN necesidad de un join a Branch.
    assert unidad.empresa_id == empresa.id
    assert unidad.branch_id == branch.id
    assert ubicacion.empresa_id == empresa.id
    assert ubicacion.branch_id == branch.id

    assert Autenticacion.listar_branches(empresa.id) |> Enum.map(& &1.id) == [branch.id]
    assert Autenticacion.listar_sales_units(branch.id) |> Enum.map(& &1.id) == [unidad.id]
    assert Autenticacion.listar_inventory_locations(branch.id) |> Enum.map(& &1.id) == [ubicacion.id]
  end

  test "no se puede crear una Sales Unit sin Branch" do
    empresa = fixture_empresa()

    {:error, changeset} =
      Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, sales_unit_name: "Preventa huérfana"})

    assert %{branch_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "eliminar_branch/1 se bloquea si tiene Sales Units o Inventory Locations vivas" do
    empresa = fixture_empresa()
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Con hijos"})

    {:ok, _unidad} =
      Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})

    assert {:error, :tiene_hijos} = Autenticacion.eliminar_branch(branch)
    refute Repo.get!(Branch, branch.id).delete_guid
  end

  test "eliminar_branch/1 funciona una vez que no quedan hijos vivos" do
    empresa = fixture_empresa()
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Sin hijos"})

    {:ok, unidad} =
      Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})

    {:ok, _} = Autenticacion.eliminar_sales_unit(unidad)

    assert {:ok, eliminada} = Autenticacion.eliminar_branch(branch)
    assert eliminada.delete_guid
  end

  test "actualizar_sales_unit/2 estampa update_guid" do
    empresa = fixture_empresa()
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})

    {:ok, unidad} =
      Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})

    refute unidad.update_guid
    {:ok, actualizada} = Autenticacion.actualizar_sales_unit(unidad, %{sales_unit_name: "Preventa 1 renombrada"})

    assert actualizada.sales_unit_name == "Preventa 1 renombrada"
    assert actualizada.update_guid
  end
end
