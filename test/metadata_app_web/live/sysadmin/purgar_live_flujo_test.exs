defmodule MetadataAppWeb.Sysadmin.PurgarLiveFlujoTest do
  @moduledoc """
  Pantalla "Purgar" con datos (SPEC-ARQ-3009202601, Grupo G): matriz de
  artefactos por destino, modales de retiro y purga, aviso del trabajo de
  unstable y bitácora. Sin GitHub ni SSH: `Purga.FuenteFalsa`.
  """
  use MetadataAppWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Autenticacion
  alias MetadataApp.Purga.FuenteFalsa

  @artefactos [
    %{
      nombre: "pty_pub",
      tipo: :catalogo,
      tablas: ["pty_pub"],
      paquetes: ["bc-pty_pub"],
      retirado: false,
      versiones: [1]
    },
    %{
      nombre: "pty_ret",
      tipo: :catalogo,
      tablas: ["pty_ret"],
      paquetes: [],
      retirado: true,
      versiones: [2]
    },
    %{
      nombre: "pty_lap",
      tipo: :lapida,
      tablas: ["pty_lap"],
      paquetes: [],
      retirado: true,
      versiones: [3]
    },
    %{
      nombre: "pty_ido",
      tipo: :catalogo,
      tablas: ["pty_ido"],
      paquetes: [],
      retirado: true,
      versiones: [4]
    }
  ]

  defp unidad(nombre, filas),
    do: %{"maestro" => nombre, "tablas" => [nombre], "tipo" => 1, "filas_estimadas" => filas}

  defp prep(extra) do
    Map.merge(
      %{
        maestro: "pty_ret",
        sistema: "unstable",
        tablas: ["pty_ret"],
        versiones: [2],
        cliente: false,
        bloqueo: nil,
        impacto: %{
          "filas" => 5,
          "dependencias" => [],
          "imagen_incluye" => false,
          "versiones_aplicadas" => [2],
          "tablas" => [%{"nombre" => "pty_ret", "objeto" => "tabla", "filas" => 5}]
        }
      },
      extra
    )
  end

  setup %{conn: conn} do
    admin = usuario_fixture()

    {:ok, empresa} =
      Autenticacion.crear_empresa_para_usuario(
        "Empresa purgar flujo #{System.unique_integer()}",
        admin.id
      )

    {:ok, _} =
      MetadataApp.Ambientes.crear_ambiente(%{
        nombre: "hetzner",
        host: "10.0.0.1",
        ssh_usuario: "elixir",
        ssh_password_nuevo: "x"
      })

    FuenteFalsa.configurar(%{
      artefactos: {:ok, @artefactos},
      inventarios: %{
        "unstable" =>
          {:ok,
           %{"unidades" => [unidad("pty_pub", 5), unidad("pty_ret", 5)], "versiones" => [1, 2, 3]}},
        "testing" => {:error, :sin_purga}
      },
      preparar: {:ok, prep(%{})},
      bitacora: %{
        "unstable" => [
          %{
            "id" => 1,
            "artefacto" => "pty_ret",
            "accion" => "retiro",
            "resultado" => "ok",
            "usuario_email" => "a@x.mx",
            "inserted_at" => "2026-09-30T10:00:00Z"
          },
          %{
            "id" => 2,
            "artefacto" => "pty_ret",
            "accion" => "purga",
            "resultado" => "error",
            "usuario_email" => "a@x.mx",
            "inserted_at" => "2026-09-30T11:00:00Z",
            "mensaje" => "Hay dependencias"
          }
        ]
      }
    })

    conn =
      conn
      |> log_in_usuario(admin)
      |> Plug.Conn.put_session(:empresa_activa_id, empresa.id)
      |> Plug.Conn.put_session("purga_fuente", FuenteFalsa)

    %{conn: conn, admin: admin}
  end

  defp abrir(conn, ruta \\ ~p"/sysadmin/purgar") do
    {:ok, view, _html} = live(conn, ruta)
    render_async(view)
    view
  end

  test "matriz: estado por destino y acciones según el estado del artefacto", %{conn: conn} do
    view = abrir(conn)

    # Publicado: se retira; en unstable se puede retirar y purgar de un paso.
    assert has_element?(view, "#retirar-pty_pub")
    assert has_element?(view, "#purgar-pty_pub-unstable", "Retirar y purgar")
    # Retirado y presente: se purga.
    assert has_element?(view, "#purgar-pty_ret-unstable", "Purgar")
    refute has_element?(view, "#retirar-pty_ret")
    # Lápida: presente en unstable por su versión aplicada.
    assert has_element?(view, "#purgar-pty_lap-unstable")
    # Un destino sin bin/purga lo dice en su columna.
    assert has_element?(view, "#art-pty_pub td", "sin purga")
    # No se borra el inventario mientras un destino no responda bien.
    refute has_element?(view, "#borrar-inventario-pty_ido")
  end

  test "borrar inventario aparece cuando todos los destinos respondieron y ninguno lo tiene", %{
    conn: conn
  } do
    FuenteFalsa.configurar(%{
      artefactos: {:ok, @artefactos},
      inventarios: %{"testing" => {:ok, %{"unidades" => [], "versiones" => []}}},
      preparar: {:ok, prep(%{})}
    })

    view = abrir(conn)
    assert has_element?(view, "#borrar-inventario-pty_ido")

    view |> element("#borrar-inventario-pty_ido") |> render_click()
    view |> form("#form-confirmacion", confirmacion: %{nombre: "pty_ido"}) |> render_change()
    view |> form("#form-confirmacion") |> render_submit()

    assert_receive {:borrar_inventario, "pty_ido", []}
  end

  test "retirar: se confirma escribiendo el nombre", %{conn: conn, admin: admin} do
    view = abrir(conn)
    view |> element("#retirar-pty_pub") |> render_click()

    assert has_element?(view, "#modal-purga")
    assert has_element?(view, "#purga-confirmar[disabled]")

    view |> form("#form-confirmacion", confirmacion: %{nombre: "pty_pub"}) |> render_change()
    refute has_element?(view, "#purga-confirmar[disabled]")

    view |> form("#form-confirmacion") |> render_submit()
    email = admin.email
    assert_receive {:retirar, "pty_pub", ^email}

    render_async(view)
    refute has_element?(view, "#modal-purga")
  end

  test "purgar con registros exige además aceptar que se borran", %{conn: conn, admin: admin} do
    view = abrir(conn)
    view |> element("#purgar-pty_ret-unstable") |> render_click()
    assert_receive {:preparar, "pty_ret", "unstable", [antes_de_retirar: false]}
    render_async(view)

    view
    |> form("#form-confirmacion", confirmacion: %{nombre: "pty_ret", acepto_filas: "false"})
    |> render_change()

    assert has_element?(view, "#purga-confirmar[disabled]")

    view
    |> form("#form-confirmacion", confirmacion: %{nombre: "pty_ret", acepto_filas: "true"})
    |> render_change()

    refute has_element?(view, "#purga-confirmar[disabled]")

    view |> form("#form-confirmacion") |> render_submit()
    email = admin.email
    assert_receive {:purgar, "pty_ret", "unstable", ^email, %{nombre: "pty_ret", filas: 5}}
  end

  describe "copia local (R14)" do
    setup do
      FuenteFalsa.configurar(%{
        artefactos: {:ok, @artefactos},
        inventarios: %{
          "unstable" =>
            {:ok,
             %{"unidades" => [unidad("pty_pub", 0), unidad("pty_ret", 5)], "versiones" => [1, 2]}}
        },
        preparar: {:ok, prep(%{})},
        copias_locales: ["pty_ret", "pty_pub"]
      })

      :ok
    end

    test "la casilla solo aparece si quien purga lo tiene en su máquina", %{conn: conn} do
      FuenteFalsa.configurar(%{
        artefactos: {:ok, @artefactos},
        inventarios: %{
          "unstable" => {:ok, %{"unidades" => [unidad("pty_ret", 5)], "versiones" => [2]}}
        },
        preparar: {:ok, prep(%{})}
      })

      view = abrir(conn)
      view |> element("#purgar-pty_ret-unstable") |> render_click()
      render_async(view)
      refute has_element?(view, "#purga-limpiar-local")
    end

    test "si se marca, se borra la copia local después de la purga", %{conn: conn} do
      view = abrir(conn)
      view |> element("#purgar-pty_ret-unstable") |> render_click()
      render_async(view)
      assert has_element?(view, "#purga-limpiar-local")

      view
      |> form("#form-confirmacion",
        confirmacion: %{nombre: "pty_ret", acepto_filas: "true", limpiar_local: "true"}
      )
      |> render_change()

      view |> form("#form-confirmacion") |> render_submit()
      assert_receive {:purgar, "pty_ret", "unstable", _, _}
      render_async(view)
      assert_receive {:purgar_local, "pty_ret", _}
      assert render(view) =~ "También se borró de tu máquina"
    end

    test "sin marcar, la copia local no se toca", %{conn: conn} do
      view = abrir(conn)
      view |> element("#purgar-pty_ret-unstable") |> render_click()
      render_async(view)

      view
      |> form("#form-confirmacion", confirmacion: %{nombre: "pty_ret", acepto_filas: "true"})
      |> render_change()

      view |> form("#form-confirmacion") |> render_submit()
      render_async(view)
      refute_received {:purgar_local, _, _}
    end

    test "en un paso (unstable), se borra cuando el trabajo avisa que purgó", %{conn: conn} do
      FuenteFalsa.configurar(%{
        artefactos: {:ok, @artefactos},
        inventarios: %{
          "unstable" => {:ok, %{"unidades" => [unidad("pty_pub", 0)], "versiones" => [1]}}
        },
        preparar:
          {:ok,
           prep(%{
             maestro: "pty_pub",
             impacto: %{
               "filas" => 0,
               "dependencias" => [],
               "imagen_incluye" => true,
               "tablas" => []
             }
           })},
        copias_locales: ["pty_pub"]
      })

      view = abrir(conn)
      view |> element("#purgar-pty_pub-unstable") |> render_click()
      render_async(view)

      view
      |> form("#form-confirmacion", confirmacion: %{nombre: "pty_pub", limpiar_local: "true"})
      |> render_change()

      view |> form("#form-confirmacion") |> render_submit()
      assert_receive {:encolar, "pty_pub", _, 0}
      refute_received {:purgar_local, _, _}

      send(view.pid, {:purga_unstable, "pty_pub", :purgado, "pty_pub quedó purgado en unstable."})
      render_async(view)
      assert_receive {:purgar_local, "pty_pub", _}
    end
  end

  test "con un bloqueo no hay formulario, solo el motivo", %{conn: conn} do
    FuenteFalsa.configurar(%{
      artefactos: {:ok, @artefactos},
      inventarios: %{
        "unstable" => {:ok, %{"unidades" => [unidad("pty_ret", 5)], "versiones" => [2]}}
      },
      preparar: {:ok, prep(%{bloqueo: "Hay dependencias: pty_q"})}
    })

    view = abrir(conn)
    view |> element("#purgar-pty_ret-unstable") |> render_click()
    render_async(view)

    assert has_element?(view, "#modal-purga", "Hay dependencias: pty_q")
    refute has_element?(view, "#form-confirmacion")
  end

  test "retirar y purgar en unstable: la imagen vieja no bloquea, se encola el trabajo", %{
    conn: conn
  } do
    FuenteFalsa.configurar(%{
      artefactos: {:ok, @artefactos},
      inventarios: %{
        "unstable" => {:ok, %{"unidades" => [unidad("pty_pub", 0)], "versiones" => [1]}}
      },
      preparar:
        {:ok,
         prep(%{
           maestro: "pty_pub",
           bloqueo: "La versión que corre en unstable todavía incluye este artefacto.",
           impacto: %{
             "filas" => 0,
             "dependencias" => [],
             "imagen_incluye" => true,
             "versiones_aplicadas" => [1],
             "tablas" => []
           }
         })}
    })

    view = abrir(conn)
    view |> element("#purgar-pty_pub-unstable") |> render_click()
    assert_receive {:preparar, "pty_pub", "unstable", [antes_de_retirar: true]}
    render_async(view)

    view |> form("#form-confirmacion", confirmacion: %{nombre: "pty_pub"}) |> render_change()
    view |> form("#form-confirmacion") |> render_submit()

    assert_receive {:encolar, "pty_pub", _email, 0}
    assert has_element?(view, "#art-pty_pub", "Retirando y reconstruyendo unstable")
    refute has_element?(view, "#purgar-pty_pub-unstable")
  end

  test "el aviso final del trabajo de unstable llega como mensaje", %{conn: conn} do
    view = abrir(conn)
    send(view.pid, {:purga_unstable, "pty_pub", :esperando_imagen, "Reconstruyendo unstable"})
    assert has_element?(view, "#art-pty_pub", "Reconstruyendo unstable")

    send(view.pid, {:purga_unstable, "pty_pub", :purgado, "pty_pub quedó purgado en unstable."})
    render_async(view)
    refute has_element?(view, "#art-pty_pub", "Reconstruyendo unstable")
    assert render(view) =~ "pty_pub quedó purgado en unstable."
  end

  test "bitácora: registros de cada destino, el más reciente primero, con filtro", %{conn: conn} do
    view = abrir(conn, ~p"/sysadmin/purgar?pestana=bitacora")

    assert has_element?(view, "#bit-unstable-2", "Hay dependencias")
    assert has_element?(view, "#bit-unstable-1")
    html = view |> element("#bitacora-registros") |> render()
    assert :binary.match(html, "bit-unstable-2") < :binary.match(html, "bit-unstable-1")

    view
    |> form("#bitacora-filtro", filtro: %{artefacto: "", destino: "stable"})
    |> render_change()

    refute has_element?(view, "#bit-unstable-1")
  end
end
