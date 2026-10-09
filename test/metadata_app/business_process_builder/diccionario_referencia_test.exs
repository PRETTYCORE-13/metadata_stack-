defmodule MetadataApp.BusinessProcessBuilder.DiccionarioReferenciaTest do
  @moduledoc """
  SPEC-SYS-2509202601 Grupo G (R24-R28) / SPEC-SYS-1109202601 §2.2: un
  campo referencia que ofrece solo lo que entrega un Diccionario (SQL View).
  """
  use MetadataApp.DataCase, async: true

  alias MetadataApp.ConsultasSql
  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerico, MetaSchemaContext}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
  alias MetadataApp.MetaBusinessProcess.Catalogos.{MetaFixtureCliente, MetaFixtureEquipo}

  defp unique, do: System.unique_integer([:positive])
  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp equipo(nombre) do
    %MetaFixtureEquipo{}
    |> MetaFixtureEquipo.changeset(%{meta_fixture_equipo_nombre_equipo: nombre})
    |> Ecto.Changeset.change(%{insert_guid: guid()})
    |> Repo.insert!()
  end

  # Diccionario de equipos cuyo nombre empieza con "Dic <s>", con una
  # columna "grupo" para probar filtros sobre el Diccionario.
  defp diccionario(s) do
    {:ok, {header, _}} = ConsultasSql.crear(%{"etiqueta" => "Equipos dic", "nav" => "/equipos_dic_#{s}"})

    sql = """
    SELECT e.id, e.meta_fixture_equipo_nombre_equipo AS nombre,
           CASE WHEN e.meta_fixture_equipo_nombre_equipo LIKE '%A' THEN 'A' ELSE 'B' END AS grupo
    FROM meta_fixture_equipo e
    WHERE e.meta_fixture_equipo_nombre_equipo LIKE 'Dic #{s}%'
    """

    {:ok, _} = ConsultasSql.guardar_sql(header.schema_context_name, sql)
    {:ok, _} = ConsultasSql.autorizar_bc(header.schema_context_name, "meta_fixture_cliente")
    header.schema_context_name
  end

  setup do
    s = unique()
    a = equipo("Dic #{s} uno A")
    b = equipo("Dic #{s} dos B")
    fuera = equipo("Otro #{s}")
    %{s: s, dic: diccionario(s), a: a, b: b, fuera: fuera}
  end

  defp props(dic, extra \\ %{}) do
    Map.merge(%{"tipo" => "referencia", "catalogo" => "meta_fixture_equipo", "diccionario" => %{"consulta" => dic, "descripcion" => ["nombre", "grupo"]}}, extra)
  end

  describe "opciones del combo (R26-R27)" do
    test "solo ofrece los id del Diccionario, con la descripción elegida", %{dic: dic, a: a, b: b, fuera: fuera} do
      opciones = CatalogoGenerico.opciones_referencia(props(dic), %{}, nil)
      ids = Enum.map(opciones, &elem(&1, 0))

      assert Enum.sort(ids) == Enum.sort([a.id, b.id])
      refute fuera.id in ids
      assert {a.id, "#{a.meta_fixture_equipo_nombre_equipo} - A"} in opciones
    end

    test "filtro fijo sobre una columna del Diccionario", %{dic: dic, a: a} do
      p = props(dic, %{"filtros_fijos" => [%{"campo" => "grupo", "valores" => ["A"], "origen" => "diccionario"}]})
      assert Enum.map(CatalogoGenerico.opciones_referencia(p, %{}, nil), &elem(&1, 0)) == [a.id]
    end

    test "filtro fijo sobre el catálogo destino (subconsulta)", %{dic: dic, b: b} do
      p = props(dic, %{"filtros_fijos" => [%{"campo" => "meta_fixture_equipo_nombre_equipo", "valores" => [String.upcase(b.meta_fixture_equipo_nombre_equipo)]}]})
      assert Enum.map(CatalogoGenerico.opciones_referencia(p, %{}, nil), &elem(&1, 0)) == [b.id]
    end

    test "dependencia sobre una columna del Diccionario (llave con prefijo)", %{dic: dic, b: b} do
      p = props(dic, %{"dependencias" => [%{"campo_padre" => "padre", "campo_remoto" => "grupo", "origen" => "diccionario"}]})
      assert {:ok, filtros} = MetaSchemaContext.resolver_filtros(p, %{"padre" => "B"})
      assert filtros == %{"diccionario:grupo" => "B"}
      assert Enum.map(CatalogoGenerico.opciones_referencia(p, filtros, nil), &elem(&1, 0)) == [b.id]
    end

    test "sin Diccionario el campo se comporta como siempre", %{a: a, fuera: fuera} do
      ids = CatalogoGenerico.opciones_referencia(%{"tipo" => "referencia", "catalogo" => "meta_fixture_equipo"}, %{}, nil) |> Enum.map(&elem(&1, 0))
      assert a.id in ids and fuera.id in ids
    end
  end

  describe "configuración (R24-R25)" do
    test "diccionarios_para/1 solo lista los autorizados, no visibles y con SQL", %{dic: dic} do
      assert Enum.any?(ConsultasSql.diccionarios_para("meta_fixture_cliente"), &(&1.nombre == dic))
      refute Enum.any?(ConsultasSql.diccionarios_para("meta_fixture_equipo"), &(&1.nombre == dic))
    end

    test "verificar_ids_en_destino/2 rechaza un Diccionario con id que no existen en el destino", %{dic: dic} do
      assert :ok = ConsultasSql.verificar_ids_en_destino(dic, "meta_fixture_equipo")

      {:ok, {h, _}} = ConsultasSql.crear(%{"etiqueta" => "Malo", "nav" => "/dic_malo_#{unique()}"})
      {:ok, _} = ConsultasSql.guardar_sql(h.schema_context_name, "SELECT -1 AS id, 'x' AS nombre")
      assert {:error, mensaje} = ConsultasSql.verificar_ids_en_destino(h.schema_context_name, "meta_fixture_equipo")
      assert mensaje =~ "no existen"
    end
  end

  describe "validación al guardar (R28)" do
    setup %{dic: dic} do
      header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
      detalle = Repo.get_by!(Detail, meta_schema_header_id: header.id, schema_context_field: "meta_fixture_cliente_edad")
      props = Map.merge(detalle.schema_context_properties, props(dic))
      detalle |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()
      :ok
    end

    defp alta(equipo_id) do
      MetaFixtureCliente.changeset(%MetaFixtureCliente{}, %{
        meta_fixture_cliente_nombre: "cliente #{unique()}",
        meta_fixture_cliente_edad: equipo_id,
        meta_fixture_cliente_venta: Decimal.new("1")
      })
    end

    test "acepta un id del Diccionario", %{a: a} do
      assert alta(a.id).valid?
    end

    test "rechaza un id fuera del Diccionario", %{fuera: fuera} do
      changeset = alta(fuera.id)
      refute changeset.valid?
      assert "el valor seleccionado no está en el diccionario de este campo" in errors_on(changeset).meta_fixture_cliente_edad
    end

    test "no valida si el campo no cambió", %{fuera: fuera} do
      viejo = %MetaFixtureCliente{meta_fixture_cliente_nombre: "viejo", meta_fixture_cliente_edad: fuera.id, meta_fixture_cliente_venta: Decimal.new("1")}
      changeset = MetaFixtureCliente.changeset(viejo, %{meta_fixture_cliente_nombre: "viejo editado"})
      refute "el valor seleccionado no está en el diccionario de este campo" in (errors_on(changeset)[:meta_fixture_cliente_edad] || [])
    end
  end
end
