defmodule MetadataAppWeb.EmpresaLogoControllerTest do
  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.{Empresa, UsuarioEmpresa}
  alias MetadataApp.Repo

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 13::32, "IHDR", 320::32, 64::32, 8, 6, 0, 0, 0,
         0::32>>

  defp empresa_con_logo! do
    empresa =
      %Empresa{}
      |> Empresa.changeset(%{nombre: "Empresa logo #{System.unique_integer([:positive])}"})
      |> Repo.insert!()

    {:ok, empresa} = Autenticacion.guardar_logo_empresa(empresa, @png)
    empresa
  end

  defp unir!(usuario, empresa) do
    %UsuarioEmpresa{}
    |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id})
    |> Repo.insert!()
  end

  describe "con sesión" do
    setup :register_and_log_in_usuario

    test "200 con el binario y caché inmutable por versión", %{conn: conn, usuario: usuario} do
      empresa = empresa_con_logo!()
      unir!(usuario, empresa)

      conn = get(conn, ~p"/empresas/#{empresa.id}/logo/#{empresa.logo_version}")

      assert conn.status == 200
      assert conn.resp_body == @png
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert get_resp_header(conn, "cache-control") == ["private, max-age=31536000, immutable"]
      assert get_resp_header(conn, "etag") == [~s("#{empresa.logo_version}")]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "404 con una versión que ya no es la vigente", %{conn: conn, usuario: usuario} do
      empresa = empresa_con_logo!()
      unir!(usuario, empresa)

      assert get(conn, ~p"/empresas/#{empresa.id}/logo/0000000000000000").status == 404
    end

    test "404 para el logo de una empresa a la que no pertenece", %{conn: conn} do
      empresa = empresa_con_logo!()

      assert get(conn, ~p"/empresas/#{empresa.id}/logo/#{empresa.logo_version}").status == 404
    end

    test "404 con un id que no es número", %{conn: conn} do
      assert get(conn, "/empresas/abc/logo/0000000000000000").status == 404
    end
  end

  test "sin sesión redirige al login", %{conn: conn} do
    empresa = empresa_con_logo!()

    conn = get(conn, ~p"/empresas/#{empresa.id}/logo/#{empresa.logo_version}")

    assert redirected_to(conn) =~ "/log-in"
  end
end
