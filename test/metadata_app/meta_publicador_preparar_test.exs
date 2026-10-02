defmodule MetadataApp.MetaPublicadorPrepararTest do
  @moduledoc "MetaPublicador.preparar_paquete/3 (SPEC-SYS-0210202601, Grupo A)."
  use MetadataApp.DataCase, async: true

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.{MetaPlantillas, MetaPublicador}
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  setup do
    s = System.unique_integer([:positive])
    maestro = "pty_pp_m#{s}"
    detalle = "#{maestro}_det"
    carpeta = "pty_pp_carpeta#{s}"
    servicio = "pty_sql_pp#{s}"

    {:ok, {h_maestro, _}} = MetaSchemaContext.crear_header_con_detalles(attrs(maestro, 1))

    {:ok, {_, _}} =
      MetaSchemaContext.crear_header_con_detalles(
        Map.put(attrs(detalle, 1), "schema_encabezado_id", h_maestro.id)
      )

    {:ok, {_, _}} = MetaSchemaContext.crear_header_con_detalles(attrs(carpeta, 2))
    {:ok, {h_servicio, _}} = MetaSchemaContext.crear_header_con_detalles(attrs(servicio, 4))
    {:ok, _} = MetaPlantillas.crear_plantilla_default(h_maestro)

    dir = Path.join(System.tmp_dir!(), "preparar_#{s}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    # Ajenos: uno "de git" y uno "de otra persona", sin catálogo en la base.
    File.write!(Path.join(dir, "consulta_de_alguien.meta.json"), ~s({"original": true}))
    File.write!(Path.join(dir, "pty_de_otro.plantillas.json"), ~s({"original": true}))

    yo = self()
    regenerar = fn nombre -> send(yo, {:regenerado, nombre}) && {:ok, %{}} end

    %{
      maestro: maestro,
      detalle: detalle,
      carpeta: carpeta,
      servicio: servicio,
      h_servicio: h_servicio,
      dir: dir,
      opts: [regenerar: regenerar]
    }
  end

  defp attrs(nombre, tipo) do
    %{
      "schema_context_name" => nombre,
      "schema_context_label" => nombre,
      "schema_context_nav" => "/#{nombre}",
      "schema_visible" => true,
      "schema_context_type" => tipo,
      "detalles" => []
    }
  end

  defp archivos(dir), do: dir |> File.ls!() |> Enum.sort()

  test "exporta solo el paquete y no toca ni borra archivos ajenos", c do
    assert :ok = MetaPublicador.preparar_paquete([c.detalle, c.maestro], c.dir, c.opts)

    assert archivos(c.dir) ==
             Enum.sort([
               "consulta_de_alguien.meta.json",
               "pty_de_otro.plantillas.json",
               "#{c.maestro}.meta.json",
               "#{c.maestro}.plantillas.json",
               "#{c.detalle}.meta.json"
             ])

    assert File.read!(Path.join(c.dir, "consulta_de_alguien.meta.json")) == ~s({"original": true})
    assert File.read!(Path.join(c.dir, "pty_de_otro.plantillas.json")) == ~s({"original": true})
    # La carpeta no está en el paquete: ni se exporta.
    refute File.exists?(Path.join(c.dir, "#{c.carpeta}.meta.json"))
  end

  test "regenera los catálogos del paquete, nunca una carpeta", c do
    assert :ok = MetaPublicador.preparar_paquete([c.carpeta, c.maestro], c.dir, c.opts)

    assert_received {:regenerado, maestro}
    assert maestro == c.maestro
    refute_received {:regenerado, _}
    assert File.exists?(Path.join(c.dir, "#{c.carpeta}.meta.json"))
  end

  test "si regenerar falla, se detiene sin exportar", c do
    opts = [regenerar: fn _ -> {:error, "no compila"} end]

    assert {:error, mensaje} = MetaPublicador.preparar_paquete([c.maestro], c.dir, opts)
    assert mensaje =~ "#{c.maestro}: no compila"
    refute File.exists?(Path.join(c.dir, "#{c.maestro}.meta.json"))
  end

  describe "endpoints" do
    setup c do
      admin = usuario_fixture()

      {:ok, empresa} =
        MetadataApp.Autenticacion.crear_empresa_para_usuario(
          "Empresa pp #{System.unique_integer()}",
          admin.id
        )

      ahora = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      {1, [%{id: sql_id}]} =
        Repo.insert_all(
          "meta_schema_consulta_sql",
          [
            %{
              meta_schema_header_id: c.h_servicio.id,
              uso: "servicio",
              insert_guid: "x",
              inserted_at: ahora,
              updated_at: ahora
            }
          ],
          returning: [:id]
        )

      Repo.insert_all("meta_schema_consulta_endpoint", [
        %{
          nombre: "ep_pp",
          metodo: "GET",
          ruta: "pp#{System.unique_integer([:positive])}",
          empresa_id: empresa.id,
          meta_schema_consulta_sql_id: sql_id,
          insert_guid: "x",
          inserted_at: ahora,
          updated_at: ahora
        }
      ])

      :ok
    end

    test "exporta el .endpoint.json de un Endpoint del paquete, no el de otro", c do
      assert :ok = MetaPublicador.preparar_paquete([c.servicio], c.dir, c.opts)

      assert %{"servicio" => true, "nombre" => "ep_pp"} =
               Jason.decode!(File.read!(Path.join(c.dir, "#{c.servicio}.endpoint.json")))

      File.rm!(Path.join(c.dir, "#{c.servicio}.endpoint.json"))
      assert :ok = MetaPublicador.preparar_paquete([c.maestro], c.dir, c.opts)
      refute File.exists?(Path.join(c.dir, "#{c.servicio}.endpoint.json"))
    end

    test "no pisa la marca de baja de endpoint.despublicar", c do
      marca = Path.join(c.dir, "#{c.servicio}.endpoint.json")
      File.write!(marca, ~s({"eliminado": true}))

      assert :ok = MetaPublicador.preparar_paquete([c.servicio], c.dir, c.opts)
      assert File.read!(marca) == ~s({"eliminado": true})
    end
  end
end
