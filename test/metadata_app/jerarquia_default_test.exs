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
    assert %{branch: nil} = Autenticacion.defaults_de_usuario(usuario.id, empresa.id)
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
end
