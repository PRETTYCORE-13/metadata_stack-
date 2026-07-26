defmodule MetadataApp.PermissionsTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Permissions
  alias MetadataApp.Autenticacion.{Empresa, Rol, Scope}

  import MetadataApp.AutenticacionFixtures

  defp empresa_fixture(attrs \\ %{}) do
    {:ok, empresa} =
      %Empresa{}
      |> Empresa.changeset(Enum.into(attrs, %{nombre: "Empresa #{System.unique_integer()}"}))
      |> Repo.insert()

    empresa
  end

  defp permiso_fixture(recurso, accion) do
    {:ok, permiso} = Permissions.crear_permiso(%{recurso: recurso, accion: accion})
    permiso
  end

  defp rol_fixture(empresa_id) do
    {:ok, rol} = Permissions.crear_rol(%{empresa_id: empresa_id, nombre: "Rol #{System.unique_integer()}"})
    rol
  end

  describe "can?/3" do
    test "false sin usuario en el scope" do
      refute Permissions.can?(%Scope{usuario: nil, empresa_activa: nil}, "leer", "algo")
    end

    test "false sin empresa activa" do
      usuario = usuario_fixture()
      refute Permissions.can?(%Scope{usuario: usuario, empresa_activa: nil}, "leer", "algo")
    end

    test "true cuando el rol asignado tiene el permiso concedido, false para otra acción" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      permiso = permiso_fixture("pty_demo_can", "leer")
      rol = rol_fixture(empresa.id)
      {:ok, _} = Permissions.asignar_permiso_a_rol(rol.id, permiso.id)
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Permissions.can?(scope, "leer", "pty_demo_can")
      refute Permissions.can?(scope, "editar", "pty_demo_can")
    end

    test "aislamiento entre empresas: el mismo usuario no arrastra permisos de otra empresa" do
      usuario = usuario_fixture()
      empresa_a = empresa_fixture()
      empresa_b = empresa_fixture()
      permiso = permiso_fixture("pty_demo_aislamiento", "leer")
      rol = rol_fixture(empresa_a.id)
      {:ok, _} = Permissions.asignar_permiso_a_rol(rol.id, permiso.id)
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa_a.id)

      assert Permissions.can?(%Scope{usuario: usuario, empresa_activa: empresa_a}, "leer", "pty_demo_aislamiento")
      refute Permissions.can?(%Scope{usuario: usuario, empresa_activa: empresa_b}, "leer", "pty_demo_aislamiento")
    end

    test "administrador ve cualquier permiso registrado sin rol_permiso explícito, pero no lo que nunca existió" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      permiso_fixture("pty_demo_admin", "editar")
      rol_admin = Repo.get_by!(Rol, nombre: "administrador")
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Permissions.can?(scope, "editar", "pty_demo_admin")
      refute Permissions.can?(scope, "leer", "recurso_que_nunca_se_registro")
    end
  end

  describe "roles de sistema son inmutables" do
    test "actualizar_rol/2 rechaza un rol de sistema" do
      rol_admin = Repo.get_by!(Rol, nombre: "administrador")
      assert {:error, :rol_de_sistema} = Permissions.actualizar_rol(rol_admin, %{"nombre" => "otro"})
    end

    test "eliminar_rol/1 rechaza un rol de sistema" do
      rol_consulta = Repo.get_by!(Rol, nombre: "consulta")
      assert {:error, :rol_de_sistema} = Permissions.eliminar_rol(rol_consulta)
    end
  end

  describe "asignar_rol/3" do
    test "rechaza un rol que pertenece a otra empresa" do
      usuario = usuario_fixture()
      empresa_a = empresa_fixture()
      empresa_b = empresa_fixture()
      rol = rol_fixture(empresa_a.id)

      assert {:error, :rol_de_otra_empresa} = Permissions.asignar_rol(usuario.id, rol.id, empresa_b.id)
    end

    test "permite un rol de sistema en cualquier empresa" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      rol_consulta = Repo.get_by!(Rol, nombre: "consulta")

      assert {:ok, _} = Permissions.asignar_rol(usuario.id, rol_consulta.id, empresa.id)
    end
  end

  describe "invalidación de cache" do
    test "revocar_rol/3 invalida el cache y can?/3 cae a false de inmediato" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      permiso = permiso_fixture("pty_demo_revocar", "leer")
      rol = rol_fixture(empresa.id)
      {:ok, _} = Permissions.asignar_permiso_a_rol(rol.id, permiso.id)
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Permissions.can?(scope, "leer", "pty_demo_revocar")

      {:ok, _} = Permissions.revocar_rol(usuario.id, rol.id, empresa.id)

      refute Permissions.can?(scope, "leer", "pty_demo_revocar")
    end

    test "reemplazar_permisos_de_rol/2 invalida el cache de TODOS los usuarios con ese rol" do
      usuario1 = usuario_fixture()
      usuario2 = usuario_fixture()
      empresa = empresa_fixture()
      permiso_leer = permiso_fixture("pty_demo_reemplazo", "leer")
      permiso_editar = permiso_fixture("pty_demo_reemplazo", "editar")
      rol = rol_fixture(empresa.id)
      {:ok, _} = Permissions.asignar_permiso_a_rol(rol.id, permiso_leer.id)
      {:ok, _} = Permissions.asignar_rol(usuario1.id, rol.id, empresa.id)
      {:ok, _} = Permissions.asignar_rol(usuario2.id, rol.id, empresa.id)

      scope1 = %Scope{usuario: usuario1, empresa_activa: empresa}
      scope2 = %Scope{usuario: usuario2, empresa_activa: empresa}
      assert Permissions.can?(scope1, "leer", "pty_demo_reemplazo")
      assert Permissions.can?(scope2, "leer", "pty_demo_reemplazo")

      :ok = Permissions.reemplazar_permisos_de_rol(rol.id, [permiso_editar.id])

      refute Permissions.can?(scope1, "leer", "pty_demo_reemplazo")
      refute Permissions.can?(scope2, "leer", "pty_demo_reemplazo")
      assert Permissions.can?(scope1, "editar", "pty_demo_reemplazo")
      assert Permissions.can?(scope2, "editar", "pty_demo_reemplazo")
    end
  end
end
