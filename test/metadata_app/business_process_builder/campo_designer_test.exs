defmodule MetadataApp.BusinessProcessBuilder.CampoDesignerTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.BusinessProcessBuilder.{MetaCatalogoGenerico, MetaSchemaContext}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.{Header, Detail}
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente
  alias MetadataAppWeb.Sysadmin.FieldDesignerComponents

  defp unique, do: System.unique_integer([:positive])

  # aplicar_validaciones/2 es pública y opera sobre CUALQUIER changeset +
  # lista de campos_meta — no hace falta un catálogo generado de verdad
  # para probar transformación/longitud mínima, solo un changeset real
  # (reusa %MetaFixtureCliente{} como base, cast/3 no le pide nada más).
  describe "MetaCatalogoGenerico.aplicar_validaciones/2 — transformación" do
    test "mayúsculas transforma el valor antes de guardarse" do
      changeset =
        %MetaFixtureCliente{}
        |> Ecto.Changeset.cast(%{meta_fixture_cliente_nombre: "juan perez"}, [:meta_fixture_cliente_nombre])
        |> MetaCatalogoGenerico.aplicar_validaciones([{:meta_fixture_cliente_nombre, :string, %{transformacion: "mayusculas"}}])

      assert Ecto.Changeset.get_change(changeset, :meta_fixture_cliente_nombre) == "JUAN PEREZ"
    end

    test "minúsculas transforma el valor" do
      changeset =
        %MetaFixtureCliente{}
        |> Ecto.Changeset.cast(%{meta_fixture_cliente_nombre: "JUAN@EJEMPLO.COM"}, [:meta_fixture_cliente_nombre])
        |> MetaCatalogoGenerico.aplicar_validaciones([{:meta_fixture_cliente_nombre, :string, %{transformacion: "minusculas"}}])

      assert Ecto.Changeset.get_change(changeset, :meta_fixture_cliente_nombre) == "juan@ejemplo.com"
    end

    test "capitalizar transforma el valor" do
      changeset =
        %MetaFixtureCliente{}
        |> Ecto.Changeset.cast(%{meta_fixture_cliente_nombre: "juan carlos perez"}, [:meta_fixture_cliente_nombre])
        |> MetaCatalogoGenerico.aplicar_validaciones([{:meta_fixture_cliente_nombre, :string, %{transformacion: "capitalizar"}}])

      assert Ecto.Changeset.get_change(changeset, :meta_fixture_cliente_nombre) == "Juan Carlos Perez"
    end

    test "sin transformación configurada, el valor no se toca" do
      changeset =
        %MetaFixtureCliente{}
        |> Ecto.Changeset.cast(%{meta_fixture_cliente_nombre: "Juan Perez"}, [:meta_fixture_cliente_nombre])
        |> MetaCatalogoGenerico.aplicar_validaciones([{:meta_fixture_cliente_nombre, :string, %{}}])

      refute Ecto.Changeset.get_change(changeset, :meta_fixture_cliente_nombre)
    end
  end

  describe "MetaCatalogoGenerico.aplicar_validaciones/2 — longitud mínima" do
    test "rechaza un valor más corto que el mínimo" do
      changeset =
        %MetaFixtureCliente{}
        |> Ecto.Changeset.cast(%{meta_fixture_cliente_nombre: "ab"}, [:meta_fixture_cliente_nombre])
        |> MetaCatalogoGenerico.aplicar_validaciones([{:meta_fixture_cliente_nombre, :string, %{longitud_minima: 3}}])

      refute changeset.valid?
      assert "tiene que tener al menos 3 caracteres" in errors_on(changeset).meta_fixture_cliente_nombre
    end

    test "acepta un valor que cumple el mínimo" do
      changeset =
        %MetaFixtureCliente{}
        |> Ecto.Changeset.cast(%{meta_fixture_cliente_nombre: "abc"}, [:meta_fixture_cliente_nombre])
        |> MetaCatalogoGenerico.aplicar_validaciones([{:meta_fixture_cliente_nombre, :string, %{longitud_minima: 3}}])

      assert changeset.valid?
    end

    test "longitud mínima y máxima conviven" do
      changeset =
        %MetaFixtureCliente{}
        |> Ecto.Changeset.cast(%{meta_fixture_cliente_nombre: "abcdefghij"}, [:meta_fixture_cliente_nombre])
        |> MetaCatalogoGenerico.aplicar_validaciones([{:meta_fixture_cliente_nombre, :string, %{longitud_minima: 3, longitud: 5}}])

      refute changeset.valid?
      assert "no puede tener más de 5 caracteres" in errors_on(changeset).meta_fixture_cliente_nombre
    end
  end

  # aplicar_campos_calculados/2, a diferencia de transformación/longitud
  # mínima, SÍ se lee en runtime (listar_detalles/1 fresco) — mismo atajo
  # que dependencias_referencia_test.exs/formato_captura_test.exs: reusa
  # el fixture real, mutando su metadata dentro del test.
  describe "MetaSchemaContext.aplicar_campos_calculados/2" do
    defp detalle(campo) do
      header = Repo.get_by!(Header, schema_context_name: "meta_fixture_cliente")
      Repo.get_by!(Detail, meta_schema_header_id: header.id, schema_context_field: campo)
    end

    defp con_formula(campo, formula) do
      d = detalle(campo)
      props = Map.put(d.schema_context_properties, "formula", formula)
      d |> Ecto.Changeset.change(%{schema_context_properties: props}) |> Repo.update!()
      :ok
    end

    setup do
      con_formula("meta_fixture_cliente_edad", "{meta_fixture_cliente_venta} + 1")
      :ok
    end

    test "pisa el valor del campo calculado con el resultado de la fórmula, sin importar lo que llegó" do
      changeset =
        MetaFixtureCliente.changeset(%MetaFixtureCliente{}, %{
          meta_fixture_cliente_nombre: "cliente #{unique()}",
          meta_fixture_cliente_edad: 999,
          meta_fixture_cliente_venta: Decimal.new("10")
        })

      assert Ecto.Changeset.get_field(changeset, :meta_fixture_cliente_edad) == 11
    end

    test "fórmula inválida no rompe el changeset, se deja el valor como llegó" do
      con_formula("meta_fixture_cliente_edad", "{campo_que_no_existe} +")

      changeset =
        MetaFixtureCliente.changeset(%MetaFixtureCliente{}, %{
          meta_fixture_cliente_nombre: "cliente #{unique()}",
          meta_fixture_cliente_edad: 5,
          meta_fixture_cliente_venta: Decimal.new("10")
        })

      assert Ecto.Changeset.get_field(changeset, :meta_fixture_cliente_edad) == 5
    end
  end

  # construir_propiedades/3 no toca la base — arma el mapa
  # schema_context_properties a partir del estado del asistente, se puede
  # probar 100% en memoria.
  describe "FieldDesignerComponents.construir_propiedades/3" do
    defp form_base(tipo) do
      FieldDesignerComponents.estado_inicial()
      |> Map.put("tipo", tipo)
      |> Map.put("nombre", "campo_prueba")
      |> Map.put("etiqueta", "Campo de prueba")
    end

    test "campo string simple, sin capacidades" do
      assert {:ok, "cat_campo_prueba", props} = FieldDesignerComponents.construir_propiedades(form_base("string"), [], "cat")
      assert props["tipo"] == "string"
      assert props["etiqueta"] == "Campo de prueba"
      assert props["opcional"] == true
      assert props["visible"] == true
      assert props["editable"] == true
    end

    test "obligatorio activo produce opcional: false" do
      form = form_base("string") |> Map.put("capacidades", %{"obligatorio" => true})
      assert {:ok, _nombre, props} = FieldDesignerComponents.construir_propiedades(form, [], "cat")
      assert props["opcional"] == false
    end

    test "oculto y solo_lectura activos apagan visible/editable" do
      form = form_base("string") |> Map.put("capacidades", %{"oculto" => true, "solo_lectura" => true})
      assert {:ok, _nombre, props} = FieldDesignerComponents.construir_propiedades(form, [], "cat")
      assert props["visible"] == false
      assert props["editable"] == false
    end

    test "formato automático arma formato_captura habilitado" do
      form =
        form_base("string")
        |> Map.put("capacidades", %{"formato" => true})
        |> Map.put("formato_modo", "telefono")

      assert {:ok, _nombre, props} = FieldDesignerComponents.construir_propiedades(form, [], "cat")
      assert %{"habilitada" => true, "modo" => "telefono", "patron" => "(999) 999-9999"} = props["formato_captura"]
    end

    test "transformación arma la clave transformacion" do
      form =
        form_base("string")
        |> Map.put("capacidades", %{"transformacion" => true})
        |> Map.put("transformacion_tipo", "mayusculas")

      assert {:ok, _nombre, props} = FieldDesignerComponents.construir_propiedades(form, [], "cat")
      assert props["transformacion"] == "mayusculas"
    end

    test "lista sin opciones rechaza con error claro" do
      form = form_base("enum") |> Map.put("valores_lista", ["", ""])
      assert {:error, motivo} = FieldDesignerComponents.construir_propiedades(form, [], "cat")
      assert motivo =~ "opción"
    end

    test "lista con opciones arma la clave valores" do
      form = form_base("enum") |> Map.put("valores_lista", ["Activo", "", "Inactivo"])
      assert {:ok, _nombre, props} = FieldDesignerComponents.construir_propiedades(form, [], "cat")
      assert props["valores"] == ["Activo", "Inactivo"]
    end

    test "nombre inválido rechaza" do
      form = form_base("string") |> Map.put("nombre", "Nombre Invalido")
      assert {:error, motivo} = FieldDesignerComponents.construir_propiedades(form, [], "cat")
      assert motivo =~ "Nombre inválido"
    end

    test "nombre duplicado rechaza" do
      campo_existente = %{schema_context_field: "cat_campo_prueba"}
      assert {:error, motivo} = FieldDesignerComponents.construir_propiedades(form_base("string"), [campo_existente], "cat")
      assert motivo =~ "Ya existe"
    end

    test "referencia sin catálogo elegido rechaza" do
      form = form_base("referencia")
      assert {:error, "Elegí a qué catálogo apunta la referencia."} = FieldDesignerComponents.construir_propiedades(form, [], "cat")
    end
  end
end
