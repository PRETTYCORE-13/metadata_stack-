defmodule MetadataApp.ReleaseTest do
  use MetadataApp.DataCase, async: false

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Branch, Empresa, InventoryLocation, SalesUnit}

  # SPEC-SYS-0309202601, R9 (Grupo C), tarea 15: Release.setup/0 (camino
  # SYSADMIN_EMAIL, sin wizard) llama a la MISMA
  # Autenticacion.crear_empresa_para_usuario/2 que ya usa el wizard --
  # confirma que el camino sin wizard también termina con
  # Branch/SalesUnit/InventoryLocation, sin código aparte.
  #
  # Ecto.Migrator.with_repo/3 (lo que usa Release por diseño, para poder
  # correr sin la app supervisada) corre FUERA del sandbox de este test
  # -- lo que escribe queda de verdad en la base compartida de test, no
  # se revierte solo. Limpieza manual explícita en on_exit, verificada.
  test "Release.setup/0 crea Branch/SalesUnit/InventoryLocation igual que el wizard" do
    email = "sysadmin_release_test_#{System.unique_integer([:positive])}@ejemplo.com"
    nombre_empresa = "Empresa Release Test #{System.unique_integer([:positive])}"

    # Sin marcar super_admin: true acá a propósito -- upsert_sysadmin/2
    # (que corre adentro de Release.seed_sysadmin/0) busca primero
    # CUALQUIER super_admin existente antes que por email; si este
    # fixture ya fuera uno, competiría con lo que sea que ya haya en la
    # base compartida de test. Dejarlo sin marcar fuerza que lo encuentre
    # por email (único, recién creado) -- determinístico.
    usuario = usuario_fixture(%{email: email})

    on_exit(fn ->
      # Orden importa -- SalesUnit/InventoryLocation tienen FK contra
      # Branch, hay que borrarlas primero.
      Repo.delete_all(from(s in SalesUnit, join: e in Empresa, on: e.id == s.empresa_id, where: e.nombre == ^nombre_empresa))
      Repo.delete_all(from(i in InventoryLocation, join: e in Empresa, on: e.id == i.empresa_id, where: e.nombre == ^nombre_empresa))
      Repo.delete_all(from(b in Branch, join: e in Empresa, on: e.id == b.empresa_id, where: e.nombre == ^nombre_empresa))
      Repo.delete_all(from(ue in MetadataApp.Autenticacion.UsuarioEmpresa, where: ue.usuario_id == ^usuario.id))
      Repo.delete_all(from(e in Empresa, where: e.nombre == ^nombre_empresa))
      Repo.delete_all(from(u in MetadataApp.Autenticacion.Usuario, where: u.id == ^usuario.id))
    end)

    System.put_env("SYSADMIN_EMAIL", email)
    System.put_env("SYSADMIN_PASSWORD", "una_contrasena_larga_de_prueba_123")
    System.put_env("EMPRESA_INICIAL_NOMBRE", nombre_empresa)

    try do
      MetadataApp.Release.setup()
    after
      System.delete_env("SYSADMIN_EMAIL")
      System.delete_env("SYSADMIN_PASSWORD")
      System.delete_env("EMPRESA_INICIAL_NOMBRE")
    end

    empresa = Repo.get_by!(Empresa, nombre: nombre_empresa)

    branch = Repo.get_by!(Branch, empresa_id: empresa.id)
    assert branch.branch_name == "Sucursal Principal"

    assert Repo.get_by!(SalesUnit, empresa_id: empresa.id, branch_id: branch.id).sales_unit_name ==
             "Unidad de Venta Principal"

    assert Repo.get_by!(InventoryLocation, empresa_id: empresa.id, branch_id: branch.id).inventory_name ==
             "Almacén Principal"
  end
end
