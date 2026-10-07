defmodule MetadataApp.MetaTepacheTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.MetaTepache
  alias MetadataApp.MetaPublicador
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  describe "armar_notas/3" do
    test "sin descripcion ni problemas" do
      notas = MetaTepache.armar_notas("", ["pty_aly_marcas"], [])

      assert notas =~ "**Catálogos incluidos:** pty_aly_marcas"
      assert notas =~ "Sin advertencias."
    end

    test "con descripcion libre, va primero" do
      notas = MetaTepache.armar_notas("Agrego validación de crédito.", ["pty_aly_marcas"], [])

      assert String.starts_with?(notas, "Agrego validación de crédito.")
      assert notas =~ "**Catálogos incluidos:** pty_aly_marcas"
    end

    test "con advertencias del validador" do
      problemas = [%{severidad: :advertencia, mensaje: "algo raro"}, %{severidad: :error, mensaje: "algo peor"}]
      notas = MetaTepache.armar_notas("", ["pty_x"], problemas)

      assert notas =~ "**Advertencias:**"
      assert notas =~ "- [advertencia] algo raro"
      assert notas =~ "- [error] algo peor"
      refute notas =~ "Sin advertencias."
    end
  end

  describe "catalogos_en_bundle/1" do
    # El tar.exe nativo de Windows termina cada línea de "-tzf" en "\r\n" --
    # sin el String.trim/1 por línea, "nombres" volvía [] (visto real:
    # aplicar_import/1 corrió sin registrar_permisos ni detectar campos
    # removidos porque no encontraba ningún ".meta.json" en el listado).
    test "detecta los catálogos sin importar el line ending que use el tar del sistema" do
      dir = System.tmp_dir!()
      catalogo = "catalogo_bundle_test_#{System.unique_integer([:positive])}"
      meta_nombre = "#{catalogo}.meta.json"
      meta_path = Path.join(dir, meta_nombre)
      bundle_path = Path.join(dir, "bundle-test-#{System.unique_integer([:positive])}.tar.gz")

      File.write!(meta_path, "{}")
      {_salida, 0} = System.cmd("tar", ["-czf", bundle_path, "-C", dir, meta_nombre])

      on_exit(fn ->
        File.rm(meta_path)
        File.rm(bundle_path)
      end)

      assert {:ok, [^catalogo]} = MetaTepache.catalogos_en_bundle(bundle_path)
    end
  end

  # SPEC-SYS-0710202601 R9: si falta seleccionar una dependencia real
  # (acá, un catálogo detalle), exportar/2 tiene que rechazar ANTES de
  # tocar disco o GitHub -- por eso estos tests llaman exportar/2 de
  # verdad (no mockean MetaPublicador) pero nunca llegan a necesitar
  # `gh`/`tar`: el camino de rechazo corta antes de regenerar_schemas/0
  # y de armar_y_publicar/4.
  describe "exportar/2 — R9, rechaza si falta alguna dependencia por seleccionar" do
    setup do
      s = System.unique_integer([:positive])
      maestro = "pty_tep_m#{s}"
      detalle = "#{maestro}_det"

      {:ok, {h_maestro, _}} = MetaSchemaContext.crear_header_con_detalles(attrs(maestro, 1))

      {:ok, {_, _}} =
        MetaSchemaContext.crear_header_con_detalles(
          Map.put(attrs(detalle, 1), "schema_encabezado_id", h_maestro.id)
        )

      %{maestro: maestro, detalle: detalle}
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

    test "rechaza y lista la dependencia faltante por nombre, sin crear ningún release", c do
      assert {:error, mensaje} = MetaTepache.exportar([c.maestro])

      assert mensaje =~ "Faltan agregar estas dependencias antes de exportar"
      assert mensaje =~ c.detalle
    end

    # R20: el rechazo de R9 ocurre en la etapa 1 -- nunca llega a avisar
    # la 2 (regenerar schemas) ni las siguientes.
    test "con callback de progreso, el rechazo solo emite la etapa 1", c do
      yo = self()

      assert {:error, _} = MetaTepache.exportar([c.maestro], "", progreso: &send(yo, {:etapa, &1}))

      assert_received {:etapa, 1}
      refute_received {:etapa, _}
    end

    # No se llama exportar/2 acá (tocaría gh/tar de verdad) -- se verifica
    # directo contra MetaPublicador.validar/1, que es lo que exportar/2
    # usa para decidir si hay algo pendiente de seleccionar (R9).
    test "con la dependencia ya incluida en la selección, no queda nada pendiente", c do
      assert {:ok, %{catalogos: catalogos}} = MetaPublicador.validar([c.maestro, c.detalle])
      assert catalogos -- [c.maestro, c.detalle] == []
    end
  end

  # SPEC-SYS-0710202601 R22: con un tag que no existe, descargar/1 falla
  # (por GitHub, o por no tener `gh` -- R19) y preparar_import/2 nunca
  # llega a la etapa 2. Consulta GitHub de verdad, pero no crea nada.
  describe "preparar_import/2 — R22, progreso" do
    test "con un tag inexistente solo emite la etapa 1 y devuelve error" do
      yo = self()
      tag = "TEPACHE-NO-EXISTE-#{System.unique_integer([:positive])}"

      assert {:error, _} = MetaTepache.preparar_import(tag, progreso: &send(yo, {:etapa, &1}))

      assert_received {:etapa, 1}
      refute_received {:etapa, _}
    end
  end

  # SPEC-SYS-0710202601 R14.1: el directorio local de catálogos puede
  # tener .json de otros catálogos -- el import de un tepache solo debe
  # procesar los del bundle.
  describe "importar_catalogos/2 — R14.1, solo los catálogos del bundle" do
    test "importa el catálogo del bundle e ignora otro .meta.json del mismo directorio" do
      s = System.unique_integer([:positive])
      del_bundle = "pty_tep_b#{s}"
      ajeno = "pty_tep_ajeno#{s}"

      {:ok, _} =
        MetaSchemaContext.crear_header_con_detalles(%{
          "schema_context_name" => del_bundle,
          "schema_context_label" => del_bundle,
          "schema_context_nav" => "/#{del_bundle}",
          "schema_visible" => true,
          "schema_context_type" => 1,
          "detalles" => []
        })

      dir = Path.join(System.tmp_dir!(), "tepache_test_#{s}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      for {nombre, extra} <- [{del_bundle, %{"orden_columnas_tabla" => ["id", "estado"]}}, {ajeno, %{}}] do
        contexto =
          Map.merge(
            %{
              "schema_context_name" => nombre,
              "schema_context_label" => nombre,
              "schema_context_nav" => "/#{nombre}",
              "schema_visible" => true,
              "schema_context_type" => 1,
              "detalles" => []
            },
            extra
          )

        File.write!(Path.join(dir, "#{nombre}.meta.json"), Jason.encode!(contexto))
      end

      mensajes = MetaTepache.importar_catalogos([del_bundle], dir)

      assert MetaSchemaContext.obtener_header_por_nombre(del_bundle).orden_columnas_tabla == ["id", "estado"]
      assert MetaSchemaContext.obtener_header_por_nombre(ajeno) == nil
      refute Enum.any?(mensajes, &(&1 =~ ajeno))
    end
  end
end
