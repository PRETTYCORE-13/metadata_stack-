defmodule MetadataAppWeb.PtyMotocicletasCicloCompletoTest do
  @moduledoc """
  Prueba de punta a punta del ciclo completo de un Business Context sobre
  el catálogo real pty_motocicletas: arma un autómata (Activo/Baja +
  alta/guardar/dar_de_baja/reactivar) enganchando las reglas de negocio
  REALES (los módulos que generó `mix motor.reglas.andamiar`, no
  vocabulario cerrado), y ejercita las 4 transiciones vía la API HTTP
  real — la versión automatizada de lo que se venía verificando a mano
  por Postman en cada sesión. También confirma que, con los stubs ya
  completados, MetaEstadosAdmin.completitud/1 marca el catálogo como
  terminado (sin reglas de negocio en estado stub).
  """

  use MetadataAppWeb.ConnCase, async: true

  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.Estado
  alias MetadataApp.MetaEstadosAdmin

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")
  defp unique, do: System.unique_integer([:positive])

  defp header, do: Repo.get_by!(Header, schema_context_name: "pty_motocicletas")

  defp fixture_estado(header, attrs) do
    %Estado{}
    |> Estado.changeset(Map.merge(%{meta_schema_header_id: header.id, orden: unique()}, attrs))
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp fixture_transicion(header, attrs, reglas) do
    {:ok, transicion} = MetaEstadosAdmin.crear_transicion(Map.merge(%{meta_schema_header_id: header.id}, attrs))

    Enum.each(reglas, fn nombre ->
      tipo = if String.ends_with?(nombre, "_post"), do: "post", else: "pre"
      {:ok, _} = MetaEstadosAdmin.crear_regla(%{"transicion_id" => transicion.id, "tipo" => tipo, "regla" => nombre})
    end)

    transicion
  end

  setup do
    h = header()
    activo = fixture_estado(h, %{nombre: "moto_activo_#{unique()}"})
    baja = fixture_estado(h, %{nombre: "moto_baja_#{unique()}"})

    fixture_transicion(h, %{accion: "alta", etiqueta: "Registrar", estado_destino_id: activo.id}, [
      "alta_pre",
      "alta_post"
    ])

    fixture_transicion(
      h,
      %{
        accion: "guardar",
        etiqueta: "Guardar",
        estado_origen_id: activo.id,
        estado_destino_id: activo.id,
        campos_editables: ["pty_motocicletas_marca", "pty_motocicletas_numero_placas"]
      },
      ["guardar_pre", "guardar_post"]
    )

    fixture_transicion(
      h,
      %{accion: "dar_de_baja", etiqueta: "Dar de baja", estado_origen_id: activo.id, estado_destino_id: baja.id},
      ["dar_de_baja_pre", "dar_de_baja_post"]
    )

    fixture_transicion(
      h,
      %{accion: "reactivar", etiqueta: "Reactivar", estado_origen_id: baja.id, estado_destino_id: activo.id},
      ["reactivar_pre", "reactivar_post"]
    )

    %{activo: activo, baja: baja}
  end

  test "alta -> guardar -> dar_de_baja -> reactivar, de punta a punta vía la API real", %{
    conn: conn,
    activo: activo,
    baja: baja
  } do
    atributos = %{
      "pty_motocicletas_nombre" => "R15",
      "pty_motocicletas_marca" => "Yamaha",
      "pty_motocicletas_numero_cilindros" => 1,
      "pty_motocicletas_tipo" => "Deportiva",
      "pty_motocicletas_anio" => "2024-01-01",
      "pty_motocicletas_numero_placas" => "ABC-123"
    }

    conn_alta = post(conn, ~p"/api/pty_motocicletas", atributos)
    assert %{"data" => %{"id" => id, "estado_id" => estado_id}} = json_response(conn_alta, 201)
    assert estado_id == activo.id

    conn_disponibles = get(conn, ~p"/api/pty_motocicletas/#{id}/transiciones")
    acciones = conn_disponibles |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["accion"])
    assert "guardar" in acciones
    assert "dar_de_baja" in acciones
    refute "reactivar" in acciones

    # El self-loop "guardar" se dispara vía PUT/PATCH (CatalogoGenerico.actualizar/2),
    # no vía POST .../transiciones/:accion -- ese endpoint genérico solo
    # mueve estado_id, nunca castea campos de negocio (ver MetaStateEngine.ejecutar_nucleo/4).
    conn_guardar = put(conn, ~p"/api/pty_motocicletas/#{id}", %{"pty_motocicletas_marca" => "Kawasaki"})

    assert %{"data" => %{"pty_motocicletas_marca" => "Kawasaki", "estado_id" => ^estado_id}} =
             json_response(conn_guardar, 200)

    conn_baja_sin_motivo = post(conn, ~p"/api/pty_motocicletas/#{id}/transiciones/dar_de_baja", %{})

    assert %{"errors" => %{"razones" => [%{"regla" => "dar_de_baja_pre"}]}} =
             json_response(conn_baja_sin_motivo, 422)

    conn_baja =
      post(conn, ~p"/api/pty_motocicletas/#{id}/transiciones/dar_de_baja", %{"motivo_baja" => "venta"})

    assert %{"data" => %{"estado_id" => estado_baja_id}} = json_response(conn_baja, 200)
    assert estado_baja_id == baja.id

    conn_reactivar = post(conn, ~p"/api/pty_motocicletas/#{id}/transiciones/reactivar", %{})
    assert %{"data" => %{"estado_id" => estado_reactivado_id}} = json_response(conn_reactivar, 200)
    assert estado_reactivado_id == activo.id
  end

  test "sin reglas de negocio en estado stub, MetaEstadosAdmin.completitud/1 marca el catálogo completo" do
    assert {:ok, %{completo?: true, reglas: %{negocio_stub: 0}}} = MetaEstadosAdmin.completitud("pty_motocicletas")
  end
end
