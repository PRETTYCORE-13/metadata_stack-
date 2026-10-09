defmodule MetadataApp.AutenticacionLogoTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.{Empresa, EmpresaLogo, UsuarioEmpresa}
  alias MetadataApp.AutenticacionFixtures

  defp png(ancho, alto) do
    <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", ancho::32, alto::32, 8, 6, 0, 0, 0,
      0::32>>
  end

  defp empresa! do
    %Empresa{}
    |> Empresa.changeset(%{nombre: "Empresa logo #{System.unique_integer([:positive])}"})
    |> Repo.insert!()
  end

  defp miembro!(empresa) do
    usuario = AutenticacionFixtures.usuario_fixture()

    %UsuarioEmpresa{}
    |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id})
    |> Repo.insert!()

    usuario
  end

  describe "guardar_logo_empresa/2" do
    test "guarda la fila y la versión corta del hash" do
      empresa = empresa!()
      binario = png(320, 64)

      assert {:ok, %Empresa{logo_version: version}} =
               Autenticacion.guardar_logo_empresa(empresa, binario)

      assert String.length(version) == 16

      logo = Repo.get_by!(EmpresaLogo, empresa_id: empresa.id)
      assert logo.contenido == binario
      assert logo.content_type == "image/png"
      assert {logo.ancho, logo.alto, logo.tamano_bytes} == {320, 64, byte_size(binario)}
      assert String.starts_with?(logo.hash, version)
      assert Repo.get!(Empresa, empresa.id).logo_version == version
    end

    test "reemplazar deja una sola fila y cambia la versión" do
      empresa = empresa!()
      {:ok, empresa} = Autenticacion.guardar_logo_empresa(empresa, png(320, 64))
      version_anterior = empresa.logo_version

      {:ok, empresa} = Autenticacion.guardar_logo_empresa(empresa, png(300, 60))

      assert empresa.logo_version != version_anterior

      assert [%EmpresaLogo{ancho: 300}] =
               Repo.all(from l in EmpresaLogo, where: l.empresa_id == ^empresa.id)
    end

    test "un archivo inválido no toca nada" do
      empresa = empresa!()

      assert {:error, "Formato no permitido" <> _} =
               Autenticacion.guardar_logo_empresa(empresa, "<svg/>")

      refute Repo.get_by(EmpresaLogo, empresa_id: empresa.id)
      assert Repo.get!(Empresa, empresa.id).logo_version == nil
    end
  end

  test "quitar_logo_empresa/1 borra la fila y la versión" do
    empresa = empresa!()
    {:ok, empresa} = Autenticacion.guardar_logo_empresa(empresa, png(320, 64))

    assert {:ok, %Empresa{logo_version: nil}} = Autenticacion.quitar_logo_empresa(empresa)
    refute Repo.get_by(EmpresaLogo, empresa_id: empresa.id)
  end

  describe "obtener_logo_empresa/2" do
    setup do
      empresa = empresa!()
      {:ok, empresa} = Autenticacion.guardar_logo_empresa(empresa, png(320, 64))
      %{empresa: empresa}
    end

    test "lo entrega a un miembro de la empresa", %{empresa: empresa} do
      assert %EmpresaLogo{} = Autenticacion.obtener_logo_empresa(miembro!(empresa), empresa.id)
    end

    test "lo niega a quien no pertenece a la empresa", %{empresa: empresa} do
      otro = miembro!(empresa!())
      refute Autenticacion.obtener_logo_empresa(otro, empresa.id)
    end

    test "un super_admin lo ve aunque no sea miembro", %{empresa: empresa} do
      super_admin =
        AutenticacionFixtures.usuario_fixture()
        |> Ecto.Changeset.change(super_admin: true)
        |> Repo.update!()

      assert %EmpresaLogo{} = Autenticacion.obtener_logo_empresa(super_admin, empresa.id)
    end

    test "no lo entrega si la empresa está dada de baja", %{empresa: empresa} do
      usuario = miembro!(empresa)
      empresa |> Ecto.Changeset.change(delete_guid: "baja") |> Repo.update!()
      refute Autenticacion.obtener_logo_empresa(usuario, empresa.id)
    end

    test "nil si la empresa no tiene logo" do
      sin_logo = empresa!()
      refute Autenticacion.obtener_logo_empresa(miembro!(sin_logo), sin_logo.id)
    end
  end
end
