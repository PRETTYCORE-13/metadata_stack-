defmodule MetadataAppWeb.Sysadmin.NdtConfigLiveTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.Permissions
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyNdtConfiguracion

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  # "administrador" bypasea cualquier permiso vivo (ver
  # Permissions.cargar_permisos_de_db/2) -- mismo criterio que
  # catalogo_live_filtros_test.exs para no tener que sembrar el permiso
  # fino "sysadmin_ndt/leer" a mano en cada test.
  setup %{conn: conn} do
    usuario = usuario_fixture()
    {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa NDT UI #{System.unique_integer()}"}) |> Repo.insert()
    {:ok, _branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca #{System.unique_integer()}"})

    # require_authenticated_con_empresa (router.ex) exige que la empresa
    # activa sea una a la que el usuario de verdad pertenece -- sin esto
    # redirige a /meta_schema_usuario/seleccionar-empresa antes de montar
    # ninguna LiveView (bug real encontrado acá: faltaba este insert).
    {:ok, _} = %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)

    {:ok, header} =
      %Header{}
      |> Header.changeset(%{
        schema_context_name: "meta_fixture_alcance",
        schema_context_label: "Fixture NDT UI",
        schema_context_type: 1,
        schema_context_nav: "/catalogos/fixture-ndt-ui-#{System.unique_integer([:positive])}",
        schema_visible: true,
        schema_es_transaccional: true,
        codigo_trn: "FLIO"
      })
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert()

    conn = conn |> log_in_usuario(usuario) |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn, empresa: empresa, header: header}
  end

  defp perfil_fixture(header, empresa, attrs \\ %{}) do
    base = %{"documento" => header.id, "organizacion" => empresa.id, "serie" => "AUD", "prefijo" => "AUD-"}
    {:ok, perfil} = CatalogoGenerico.crear(PtyNdtConfiguracion, :sistema, Map.merge(base, attrs))
    perfil
  end

  test "sin folios asignados, la tabla queda vacía", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/sysadmin/ndt-config")
    assert html =~ "Todavía no se asignó ningún folio."
  end

  test "linkea al BC real de perfiles (NDT Configuración)", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/sysadmin/ndt-config")
    assert html =~ "/sistema/transacciones/ndt-configuracion"
  end

  test "muestra un folio ya asignado y permite anularlo", %{conn: conn, empresa: empresa, header: header} do
    perfil_fixture(header, empresa)

    assert {:ok, %{folio: "AUD-000001", numbering_audit_id: audit_id}} =
             MetadataApp.NDT.Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)

    {:ok, view, html} = live(conn, "/sysadmin/ndt-config")
    assert html =~ "AUD-000001"
    assert html =~ "Vigente"

    html = view |> element("button[phx-value-id='#{audit_id}']") |> render_click()
    assert html =~ "Anulado"
  end
end
