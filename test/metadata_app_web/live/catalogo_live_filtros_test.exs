defmodule MetadataAppWeb.CatalogoLiveFiltrosTest do
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion.{Empresa, Rol, UsuarioEmpresa}
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataApp.Permissions

  # Catálogo normal (schema_context_type: 1, NO una consulta) — el panel
  # de "Filtros" del usuario final (ver panel_filtros/1 en catalogo_live.ex),
  # no el de agregaciones de bc_motor_live.ex. Mismo criterio de permisos
  # que catalogo_live_consulta_test.exs: administrador ve cualquier
  # permiso YA REGISTRADO, así que alcanza con registrar el "leer" acá.
  setup %{conn: conn} do
    usuario = usuario_fixture()

    {:ok, empresa} =
      %Empresa{} |> Empresa.changeset(%{nombre: "Empresa filtros test #{System.unique_integer()}"}) |> Repo.insert()

    {:ok, _} =
      %UsuarioEmpresa{} |> UsuarioEmpresa.changeset(%{usuario_id: usuario.id, empresa_id: empresa.id}) |> Repo.insert()

    rol_admin = Repo.get_by!(Rol, nombre: "administrador")
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol_admin.id, empresa.id)
    {:ok, _} = Permissions.crear_permiso(%{recurso: "meta_fixture_cliente", accion: "leer"})

    conn =
      conn
      |> log_in_usuario(usuario)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)

    %{conn: conn}
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp fixture_cliente(attrs) do
    %MetaFixtureCliente{}
    |> MetaFixtureCliente.changeset(attrs)
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  test "un filtro de texto acota la tabla a solo las filas que matchean", %{conn: conn} do
    sufijo = unique()

    ana_torres =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Ana Torres #{sufijo}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1")
      })

    beto_torres =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Beto Torres #{sufijo}",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1")
      })

    {:ok, view, html} = live(conn, "/__test__/fixture-cliente")

    # Sin filtro/búsqueda todavía, la tabla no trae datos (carga diferida,
    # ver datos_solicitados?/1) — ninguno de los dos nombres aparece.
    refute html =~ ana_torres.meta_fixture_cliente_nombre
    refute html =~ beto_torres.meta_fixture_cliente_nombre

    html_filtrado = render_change(view, "filtrar", %{"filtros" => %{"meta_fixture_cliente_nombre" => "Ana Torres #{sufijo}"}})

    assert html_filtrado =~ ana_torres.meta_fixture_cliente_nombre
    refute html_filtrado =~ beto_torres.meta_fixture_cliente_nombre
  end

  test "dos filtros aplicados juntos se combinan con AND, no solo el último", %{conn: conn} do
    sufijo = unique()

    # Matchea AMBOS filtros (nombre "Ana<sufijo>" + edad 25-35).
    coincide =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Ana#{sufijo} Uno",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1")
      })

    # Nombre matchea, edad NO (45 fuera de 25-35).
    nombre_ok_edad_no =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Ana#{sufijo} Dos",
        meta_fixture_cliente_edad: 45,
        meta_fixture_cliente_venta: Decimal.new("1")
      })

    # Edad matchea, nombre NO ("Beto" no contiene "Ana").
    edad_ok_nombre_no =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Beto#{sufijo} Tres",
        meta_fixture_cliente_edad: 30,
        meta_fixture_cliente_venta: Decimal.new("1")
      })

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")

    html =
      render_change(view, "filtrar", %{
        "filtros" => %{
          "meta_fixture_cliente_nombre" => "Ana#{sufijo}",
          "meta_fixture_cliente_edad_desde" => "25",
          "meta_fixture_cliente_edad_hasta" => "35"
        }
      })

    assert html =~ coincide.meta_fixture_cliente_nombre
    refute html =~ nombre_ok_edad_no.meta_fixture_cliente_nombre
    refute html =~ edad_ok_nombre_no.meta_fixture_cliente_nombre

    # El botón "Filtros" refleja las DOS columnas con valor puesto (ver
    # contar_filtros_activos/1) — no solo la última que se haya tocado.
    assert html =~ ~r/bg-purple-600 text-white text-\[10px\] font-bold">\s*2\s*</
  end

  test "vaciar un campo del filtro lo saca de la cuenta pero el otro sigue activo", %{conn: conn} do
    sufijo = unique()

    solo_nombre =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Carla Ruiz #{sufijo}",
        meta_fixture_cliente_edad: 99,
        meta_fixture_cliente_venta: Decimal.new("1")
      })

    otro =
      fixture_cliente(%{
        meta_fixture_cliente_nombre: "Dana Ruiz #{sufijo}",
        meta_fixture_cliente_edad: 1,
        meta_fixture_cliente_venta: Decimal.new("1")
      })

    {:ok, view, _html} = live(conn, "/__test__/fixture-cliente")

    render_change(view, "filtrar", %{
      "filtros" => %{
        "meta_fixture_cliente_nombre" => "Ruiz #{sufijo}",
        "meta_fixture_cliente_edad_desde" => "90",
        "meta_fixture_cliente_edad_hasta" => "100"
      }
    })

    # Se borra SOLO el filtro de edad (deja el desde/hasta vacíos) — el de
    # nombre queda intacto y sigue acotando la tabla.
    html =
      render_change(view, "filtrar", %{
        "filtros" => %{
          "meta_fixture_cliente_nombre" => "Ruiz #{sufijo}",
          "meta_fixture_cliente_edad_desde" => "",
          "meta_fixture_cliente_edad_hasta" => ""
        }
      })

    assert html =~ solo_nombre.meta_fixture_cliente_nombre
    assert html =~ otro.meta_fixture_cliente_nombre
    assert html =~ ~r/bg-purple-600 text-white text-\[10px\] font-bold">\s*1\s*</
  end
end
