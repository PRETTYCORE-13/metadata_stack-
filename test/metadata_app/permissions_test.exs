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

  # Fase 3 del modelo de Alcance de Datos (2026-08-11) — QUÉ FILAS puede
  # ver/operar un usuario en UN catálogo, ortogonal a can?/3 (QUÉ ACCIONES).
  describe "alcance_tipo_efectivo/2" do
    defp header_fixture(attrs \\ %{}) do
      {:ok, header} =
        %MetadataApp.BusinessProcessBuilder.MetaSchema.Header{}
        |> MetadataApp.BusinessProcessBuilder.MetaSchema.Header.changeset(
          Enum.into(attrs, %{
            schema_context_name: "pty_alcance_test_#{System.unique_integer([:positive])}",
            schema_context_label: "Alcance test",
            schema_context_type: 1,
            schema_context_nav: "/catalogos/alcance-test-#{System.unique_integer([:positive])}",
            schema_visible: true
          })
        )
        |> Ecto.Changeset.put_change(:insert_guid, Ecto.UUID.generate() |> String.replace("-", ""))
        |> Repo.insert()

      header
    end

    test ":propio por default -- sin ningún rol_alcance concedido en ese catálogo" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      header = header_fixture()

      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Permissions.alcance_tipo_efectivo(scope, header.id) == :propio
    end

    test ":propio sin usuario o sin empresa activa (mismo criterio deny-by-default que can?/3)" do
      header = header_fixture()
      assert Permissions.alcance_tipo_efectivo(%Scope{usuario: nil, empresa_activa: nil}, header.id) == :propio
      assert Permissions.alcance_tipo_efectivo(%Scope{usuario: usuario_fixture(), empresa_activa: nil}, header.id) == :propio
    end

    test "el tipo concedido al rol del usuario en ESE catálogo" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      header = header_fixture()
      rol = rol_fixture(empresa.id)

      {:ok, _} = Permissions.definir_alcance_de_rol(rol.id, header.id, :branch)
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Permissions.alcance_tipo_efectivo(scope, header.id) == :branch
    end

    test "no se filtra por otro catálogo -- el alcance es por (rol, catálogo), no global del rol" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      header_a = header_fixture()
      header_b = header_fixture()
      rol = rol_fixture(empresa.id)

      {:ok, _} = Permissions.definir_alcance_de_rol(rol.id, header_a.id, :empresa)
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Permissions.alcance_tipo_efectivo(scope, header_a.id) == :empresa
      assert Permissions.alcance_tipo_efectivo(scope, header_b.id) == :propio
    end

    test "con varios roles concediendo alcances distintos en el MISMO catálogo, gana el más amplio" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      header = header_fixture()

      rol_estrecho = rol_fixture(empresa.id)
      rol_amplio = rol_fixture(empresa.id)
      {:ok, _} = Permissions.definir_alcance_de_rol(rol_estrecho.id, header.id, :propio)
      {:ok, _} = Permissions.definir_alcance_de_rol(rol_amplio.id, header.id, :empresa)
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol_estrecho.id, empresa.id)
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol_amplio.id, empresa.id)

      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Permissions.alcance_tipo_efectivo(scope, header.id) == :empresa
    end

    test "administrador es comodín total (:global) sin fila en meta_schema_rol_alcance" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      header = header_fixture()
      rol_admin = Repo.get_by!(Rol, nombre: "administrador")
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Permissions.alcance_tipo_efectivo(scope, header.id) == :global
    end

    test "definir_alcance_de_rol/3 es upsert -- una segunda llamada actualiza en vez de duplicar" do
      empresa = empresa_fixture()
      header = header_fixture()
      rol = rol_fixture(empresa.id)

      {:ok, _} = Permissions.definir_alcance_de_rol(rol.id, header.id, :propio)
      {:ok, _} = Permissions.definir_alcance_de_rol(rol.id, header.id, :sales_unit)

      assert [%{alcance_tipo: "sales_unit"}] = Permissions.alcance_de_rol(rol.id)
    end

    test "revocar_alcance_de_rol/2 vuelve al default :propio" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      header = header_fixture()
      rol = rol_fixture(empresa.id)

      {:ok, _} = Permissions.definir_alcance_de_rol(rol.id, header.id, :global)
      {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)
      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Permissions.alcance_tipo_efectivo(scope, header.id) == :global

      {:ok, _} = Permissions.revocar_alcance_de_rol(rol.id, header.id)
      assert Permissions.alcance_tipo_efectivo(scope, header.id) == :propio
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

    # Bug real (2026-08-16, encontrado en vivo con los switches de la
    # pestaña "Sysadmin" -- prender/apagar/prender un mismo rol de
    # sistema rompía en el segundo "prender"): revocar_rol/3 es
    # soft-delete, y el índice único de meta_schema_usuario_rol es
    # (usuario_id, rol_id, empresa_id) SIN filtrar por delete_guid IS
    # NULL -- un Repo.insert() plano chocaba contra la fila muerta y
    # fallaba para siempre. asignar_rol/3 ahora la revive en vez de
    # intentar insertar una segunda.
    test "reasignar un rol ya revocado antes lo revive en vez de fallar" do
      usuario = usuario_fixture()
      empresa = empresa_fixture()
      rol = rol_fixture(empresa.id)

      assert {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)
      assert {:ok, _} = Permissions.revocar_rol(usuario.id, rol.id, empresa.id)
      refute rol.id in Enum.map(Permissions.roles_de_usuario(usuario.id, empresa.id), & &1.id)

      assert {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)
      assert rol.id in Enum.map(Permissions.roles_de_usuario(usuario.id, empresa.id), & &1.id)
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
