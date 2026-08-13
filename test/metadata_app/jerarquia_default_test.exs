defmodule MetadataApp.JerarquiaDefaultTest do
  @moduledoc """
  Default de jerarquía operativa (2026-08-12, extensión sobre la
  jerarquía operativa activa) — un admin puede marcar UNA sucursal/
  almacén/unidad de venta como "default" entre las permitidas de un
  usuario, para que el login la elija aunque tenga varias (antes solo se
  auto-activaba con exactamente 1 permitida). Ver
  Autenticacion.resolver_jerarquia_operativa/3.
  """
  use MetadataApp.DataCase

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion

  defp jerarquia_con_dos_branches do
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa default #{System.unique_integer()}", dueno.id)
    {:ok, branch_a} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})
    {:ok, branch_b} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})
    %{empresa: empresa, branch_a: branch_a, branch_b: branch_b}
  end

  test "definir_branch_default/3 lo fija, y resolver_jerarquia_operativa/3 lo prefiere aunque haya 2+ permitidas" do
    %{empresa: empresa, branch_a: branch_a, branch_b: branch_b} = jerarquia_con_dos_branches()
    usuario = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
    Autenticacion.asignar_branch(usuario.id, branch_a.id)
    Autenticacion.asignar_branch(usuario.id, branch_b.id)

    # Sin default: 2 permitidas -> pendiente (nada se auto-activa).
    assert %{branch: {:pendiente, _}} = Autenticacion.resolver_jerarquia_operativa(usuario.id, empresa.id)

    assert {:ok, _} = Autenticacion.definir_branch_default(usuario.id, empresa.id, branch_b.id)

    assert %{branch: {:automatico, branch}} = Autenticacion.resolver_jerarquia_operativa(usuario.id, empresa.id)
    assert branch.id == branch_b.id
  end

  test "definir_branch_default/3 rechaza un id fuera de lo permitido" do
    %{empresa: empresa, branch_b: branch_ajena} = jerarquia_con_dos_branches()
    usuario = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
    # branch_ajena nunca se asigna al usuario.

    assert {:error, :fuera_de_alcance} = Autenticacion.definir_branch_default(usuario.id, empresa.id, branch_ajena.id)
  end

  test "definir_branch_default/3 con nil limpia el default" do
    %{empresa: empresa, branch_a: branch_a} = jerarquia_con_dos_branches()
    usuario = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
    Autenticacion.asignar_branch(usuario.id, branch_a.id)
    {:ok, _} = Autenticacion.definir_branch_default(usuario.id, empresa.id, branch_a.id)

    assert {:ok, _} = Autenticacion.definir_branch_default(usuario.id, empresa.id, nil)
    assert Autenticacion.branch_default_de_usuario(usuario.id, empresa.id) == nil
  end

  test "un default con la asignación revocada después no bloquea -- cae al criterio de siempre" do
    %{empresa: empresa, branch_a: branch_a} = jerarquia_con_dos_branches()
    usuario = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
    Autenticacion.asignar_branch(usuario.id, branch_a.id)
    {:ok, _} = Autenticacion.definir_branch_default(usuario.id, empresa.id, branch_a.id)

    Autenticacion.revocar_branch(usuario.id, branch_a.id)

    # Ya no tiene NINGUNA branch permitida -- el default (stale, sigue
    # guardado en meta_schema_usuario_empresa) se ignora, no revienta ni
    # se cuela como si siguiera siendo válido.
    assert %{branch: {:vacio}} = Autenticacion.resolver_jerarquia_operativa(usuario.id, empresa.id)
  end

  test "un administrador puede tener default aunque no tenga NADA asignado explícitamente" do
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa default admin #{System.unique_integer()}", dueno.id)
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})
    {:ok, _otra} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})

    # dueno es "administrador" de su propia empresa (crear_empresa_para_usuario/2)
    # y no tiene ninguna branch asignada en usuario_branch.
    assert {:ok, _} = Autenticacion.definir_branch_default(dueno.id, empresa.id, branch.id, true)

    assert %{branch: {:automatico, resultado}} = Autenticacion.resolver_jerarquia_operativa(dueno.id, empresa.id, true)
    assert resultado.id == branch.id
  end

  # Arquitectura ERP (2026-08-13): el default de Almacén/Unidad de venta
  # se movió de UsuarioEmpresa (uno solo por empresa) a UsuarioBranch (uno
  # por SUCURSAL puntual) -- un almacén pertenece a una sola branch, así
  # que Metepec y Temoaya (ej.) necesitan CADA UNA su propio default, no
  # uno solo compartido a nivel empresa.
  describe "definir_inventory_default_de_branch/4" do
    test "lo fija, y resolver_jerarquia_operativa/3 lo prefiere para ESA sucursal" do
      %{empresa: empresa, branch_a: branch} = jerarquia_con_dos_branches()
      {:ok, inventory_a} = Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Disponible"})
      {:ok, inventory_b} = Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Comprometida"})

      usuario = usuario_fixture()
      Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
      Autenticacion.asignar_branch(usuario.id, branch.id)
      Autenticacion.asignar_inventory_location(usuario.id, inventory_a.id)
      Autenticacion.asignar_inventory_location(usuario.id, inventory_b.id)
      {:ok, _} = Autenticacion.definir_branch_default(usuario.id, empresa.id, branch.id)

      # Sin default de almacén: 2 permitidos en esa sucursal -> pendiente.
      assert %{inventory_location: {:pendiente, _}} = Autenticacion.resolver_jerarquia_operativa(usuario.id, empresa.id)

      assert {:ok, _} = Autenticacion.definir_inventory_default_de_branch(usuario.id, branch.id, inventory_b.id)

      assert %{inventory_location: {:automatico, resuelto}} = Autenticacion.resolver_jerarquia_operativa(usuario.id, empresa.id)
      assert resuelto.id == inventory_b.id
    end

    test "rechaza un almacén que pertenece a OTRA sucursal -- estructuralmente ni aparece como opción" do
      %{empresa: empresa, branch_a: branch_a, branch_b: branch_b} = jerarquia_con_dos_branches()
      {:ok, inventory_de_branch_b} = Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch_b.id, inventory_name: "Disponible"})

      usuario = usuario_fixture()
      Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
      Autenticacion.asignar_branch(usuario.id, branch_a.id)
      Autenticacion.asignar_inventory_location(usuario.id, inventory_de_branch_b.id)

      assert {:error, :fuera_de_alcance} =
               Autenticacion.definir_inventory_default_de_branch(usuario.id, branch_a.id, inventory_de_branch_b.id)
    end

    test "rechaza un almacén de la sucursal correcta pero fuera de lo permitido del usuario" do
      %{empresa: empresa, branch_a: branch} = jerarquia_con_dos_branches()
      {:ok, inventory_ajeno} = Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Disponible"})

      usuario = usuario_fixture()
      Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
      Autenticacion.asignar_branch(usuario.id, branch.id)
      # inventory_ajeno nunca se asigna al usuario.

      assert {:error, :fuera_de_alcance} = Autenticacion.definir_inventory_default_de_branch(usuario.id, branch.id, inventory_ajeno.id)
    end

    test "con nil limpia el default" do
      %{empresa: empresa, branch_a: branch} = jerarquia_con_dos_branches()
      {:ok, inventory} = Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Disponible"})

      usuario = usuario_fixture()
      Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
      Autenticacion.asignar_branch(usuario.id, branch.id)
      Autenticacion.asignar_inventory_location(usuario.id, inventory.id)
      {:ok, _} = Autenticacion.definir_inventory_default_de_branch(usuario.id, branch.id, inventory.id)

      assert {:ok, _} = Autenticacion.definir_inventory_default_de_branch(usuario.id, branch.id, nil)
      assert Autenticacion.defaults_de_branch(usuario.id, branch.id).inventory_location == nil
    end
  end

  # Único de los 3 defaults que puede quedar sin fijar -- jerarquia_completa?/2
  # no lo exige (ver ese describe más abajo).
  test "definir_sales_unit_default_de_branch/4 lo fija por sucursal, igual que almacén" do
    %{empresa: empresa, branch_a: branch} = jerarquia_con_dos_branches()
    {:ok, sales_unit} = Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})

    usuario = usuario_fixture()
    Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
    Autenticacion.asignar_branch(usuario.id, branch.id)
    Autenticacion.asignar_sales_unit(usuario.id, sales_unit.id)
    {:ok, _} = Autenticacion.definir_branch_default(usuario.id, empresa.id, branch.id)

    assert {:ok, _} = Autenticacion.definir_sales_unit_default_de_branch(usuario.id, branch.id, sales_unit.id)

    assert %{sales_unit: {:automatico, resuelto}} = Autenticacion.resolver_jerarquia_operativa(usuario.id, empresa.id)
    assert resuelto.id == sales_unit.id
  end

  describe "jerarquia_completa?/2" do
    test "false sin branch default" do
      %{empresa: empresa} = jerarquia_con_dos_branches()
      usuario = usuario_fixture()
      Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)

      refute Autenticacion.jerarquia_completa?(usuario.id, empresa.id)
    end

    test "false con branch default pero sin inventory default de esa sucursal" do
      %{empresa: empresa, branch_a: branch} = jerarquia_con_dos_branches()
      usuario = usuario_fixture()
      Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
      Autenticacion.asignar_branch(usuario.id, branch.id)
      {:ok, _} = Autenticacion.definir_branch_default(usuario.id, empresa.id, branch.id)

      refute Autenticacion.jerarquia_completa?(usuario.id, empresa.id)
    end

    test "true con branch default Y su inventory default -- sales_unit no hace falta" do
      %{empresa: empresa, branch_a: branch} = jerarquia_con_dos_branches()
      {:ok, inventory} = Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Disponible"})

      usuario = usuario_fixture()
      Autenticacion.agregar_usuario_a_empresa(usuario.email, empresa.id)
      Autenticacion.asignar_branch(usuario.id, branch.id)
      Autenticacion.asignar_inventory_location(usuario.id, inventory.id)
      {:ok, _} = Autenticacion.definir_branch_default(usuario.id, empresa.id, branch.id)
      {:ok, _} = Autenticacion.definir_inventory_default_de_branch(usuario.id, branch.id, inventory.id)

      assert Autenticacion.jerarquia_completa?(usuario.id, empresa.id)
    end
  end
end
