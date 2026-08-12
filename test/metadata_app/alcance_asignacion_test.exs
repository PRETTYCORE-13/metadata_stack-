defmodule MetadataApp.AlcanceAsignacionTest do
  @moduledoc """
  Fase 2 del modelo de Alcance de Datos (2026-08-11) — asignación N:N
  usuario<->{Branch,SalesUnit,InventoryLocation}: asignar, revocar, listar
  acotado por empresa, y alcance_de_usuario/2 (el mapa combinado que
  UsuarioAuth.hidratar_alcance/1 usa para el Scope).
  """
  use MetadataApp.DataCase

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion

  defp fixture_empresa_con_jerarquia do
    usuario = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa alcance #{System.unique_integer()}", usuario.id)
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})

    {:ok, sales_unit} =
      Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})

    {:ok, inventory_location} =
      Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Producto terminado"})

    %{empresa: empresa, branch: branch, sales_unit: sales_unit, inventory_location: inventory_location}
  end

  test "asignar/revocar branch" do
    %{empresa: empresa, branch: branch} = fixture_empresa_con_jerarquia()
    usuario = usuario_fixture()

    assert Autenticacion.branches_de_usuario(usuario.id, empresa.id) == []

    {:ok, _} = Autenticacion.asignar_branch(usuario.id, branch.id)
    assert [%{id: id}] = Autenticacion.branches_de_usuario(usuario.id, empresa.id)
    assert id == branch.id

    Autenticacion.revocar_branch(usuario.id, branch.id)
    assert Autenticacion.branches_de_usuario(usuario.id, empresa.id) == []
  end

  test "asignar_branch/2 es idempotente (on_conflict: :nothing, no explota con doble asignación)" do
    %{branch: branch} = fixture_empresa_con_jerarquia()
    usuario = usuario_fixture()

    {:ok, _} = Autenticacion.asignar_branch(usuario.id, branch.id)
    assert {:ok, _} = Autenticacion.asignar_branch(usuario.id, branch.id)
  end

  test "alcance_de_usuario/2 combina las 3 dimensiones en un solo mapa" do
    %{empresa: empresa, branch: branch, sales_unit: sales_unit, inventory_location: inventory_location} =
      fixture_empresa_con_jerarquia()

    usuario = usuario_fixture()
    {:ok, _} = Autenticacion.asignar_branch(usuario.id, branch.id)
    {:ok, _} = Autenticacion.asignar_sales_unit(usuario.id, sales_unit.id)
    {:ok, _} = Autenticacion.asignar_inventory_location(usuario.id, inventory_location.id)

    assert Autenticacion.alcance_de_usuario(usuario.id, empresa.id) == %{
             branches_permitidos: [branch.id],
             sales_units_permitidas: [sales_unit.id],
             inventory_locations_permitidas: [inventory_location.id]
           }
  end

  test "branches_de_usuario/2 no filtra branches de OTRA empresa aunque el usuario esté asignado" do
    %{branch: branch} = fixture_empresa_con_jerarquia()
    %{empresa: otra_empresa} = fixture_empresa_con_jerarquia()
    usuario = usuario_fixture()

    {:ok, _} = Autenticacion.asignar_branch(usuario.id, branch.id)

    # branch pertenece a la PRIMERA empresa -- consultado contra la segunda,
    # no debe aparecer (defensa contra fuga cross-tenant en el Scope).
    assert Autenticacion.branches_de_usuario(usuario.id, otra_empresa.id) == []
  end
end
