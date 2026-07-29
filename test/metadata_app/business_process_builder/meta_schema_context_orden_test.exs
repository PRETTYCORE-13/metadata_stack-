defmodule MetadataApp.BusinessProcessBuilder.MetaSchemaContextOrdenTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  defp unique, do: System.unique_integer([:positive])

  defp crear_carpeta_raiz(nombre, etiqueta) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => etiqueta,
        "schema_context_nav" => "/#{nombre}",
        "schema_visible" => true,
        "schema_context_type" => 2,
        "detalles" => []
      })

    header
  end

  defp crear_catalogo(nombre, etiqueta, nav) do
    {:ok, {header, _}} =
      MetaSchemaContext.crear_header_con_detalles(%{
        "schema_context_name" => nombre,
        "schema_context_label" => etiqueta,
        "schema_context_nav" => nav,
        "schema_visible" => true,
        "schema_context_type" => 1,
        "detalles" => []
      })

    header
  end

  test "sin orden asignado, las carpetas raíz quedan alfabéticas (comportamiento de siempre)" do
    sufijo = unique()
    crear_carpeta_raiz("zzz_orden_#{sufijo}", "Zeta #{sufijo}")
    crear_carpeta_raiz("aaa_orden_#{sufijo}", "Alfa #{sufijo}")

    nombres =
      MetaSchemaContext.listar_headers_arbol()
      |> Enum.filter(&(&1.tipo == :carpeta and String.ends_with?(&1.id || "", "_#{sufijo}")))
      |> Enum.map(& &1.nombre)

    assert nombres == ["Alfa #{sufijo}", "Zeta #{sufijo}"]
  end

  test "reordenar_hermanos/1 hace que el orden manual gane sobre el alfabético" do
    sufijo = unique()
    nombre_a = "aaa_orden_#{sufijo}"
    nombre_z = "zzz_orden_#{sufijo}"

    crear_carpeta_raiz(nombre_a, "Alfa #{sufijo}")
    crear_carpeta_raiz(nombre_z, "Zeta #{sufijo}")

    # "Zeta" primero a propósito — sin esto el orden alfabético ya la
    # pondría después, no probaría nada.
    :ok = MetaSchemaContext.reordenar_hermanos([nombre_z, nombre_a])

    nombres =
      MetaSchemaContext.listar_headers_arbol()
      |> Enum.filter(&(&1.tipo == :carpeta and String.ends_with?(&1.id || "", "_#{sufijo}")))
      |> Enum.map(& &1.nombre)

    assert nombres == ["Zeta #{sufijo}", "Alfa #{sufijo}"]
  end

  test "el orden manual se refleja también en el menú lateral (listar_menu_arbol/0)" do
    sufijo = unique()
    nombre_a = "aaa_orden_#{sufijo}"
    nombre_z = "zzz_orden_#{sufijo}"

    crear_carpeta_raiz(nombre_a, "Alfa #{sufijo}")
    crear_carpeta_raiz(nombre_z, "Zeta #{sufijo}")
    :ok = MetaSchemaContext.reordenar_hermanos([nombre_z, nombre_a])

    nombres =
      MetaSchemaContext.listar_menu_arbol()
      |> Enum.filter(&(&1.tipo == :carpeta and String.ends_with?(&1.id || "", "_#{sufijo}")))
      |> Enum.map(& &1.nombre)

    assert nombres == ["Zeta #{sufijo}", "Alfa #{sufijo}"]
  end

  test "reordenar_hermanos/1 ignora nil en la lista en vez de reventar (carpeta implícita sin Header propio)" do
    sufijo = unique()
    nombre_a = "aaa_orden_#{sufijo}"
    crear_carpeta_raiz(nombre_a, "Alfa #{sufijo}")

    assert :ok = MetaSchemaContext.reordenar_hermanos([nil, nombre_a, nil])
  end

  test "una carpeta con orden manual siempre va antes que una sin orden asignado" do
    sufijo = unique()
    # "aaa" ganaría alfabéticamente si no fuera por el orden manual en "zzz".
    nombre_a = "aaa_orden_#{sufijo}"
    nombre_z = "zzz_orden_#{sufijo}"

    crear_carpeta_raiz(nombre_a, "Alfa #{sufijo}")
    crear_carpeta_raiz(nombre_z, "Zeta #{sufijo}")
    :ok = MetaSchemaContext.reordenar_hermanos([nombre_z])

    nombres =
      MetaSchemaContext.listar_headers_arbol()
      |> Enum.filter(&(&1.tipo == :carpeta and String.ends_with?(&1.id || "", "_#{sufijo}")))
      |> Enum.map(& &1.nombre)

    assert nombres == ["Zeta #{sufijo}", "Alfa #{sufijo}"]
  end

  test "reordenar_hermanos/1 mezcla carpetas y catálogos dentro de una misma carpeta padre" do
    sufijo = unique()
    padre = crear_carpeta_raiz("padre_orden_#{sufijo}", "Padre #{sufijo}")
    subcarpeta = crear_carpeta_raiz("padre_orden_#{sufijo}_sub", "Subcarpeta #{sufijo}")
    # La subcarpeta declara su propio nav anidado bajo el padre — recrear
    # su Header con el nav correcto (crear_carpeta_raiz siempre la deja
    # en la raíz).
    {:ok, subcarpeta} = MetaSchemaContext.actualizar_header(subcarpeta, %{"schema_context_nav" => "/#{padre.schema_context_name}/sub"})

    catalogo = crear_catalogo("cat_orden_#{sufijo}", "Zzz Catálogo #{sufijo}", "/#{padre.schema_context_name}/zzz-catalogo")

    # El catálogo ("Zzz...") ganaría siempre al final alfabéticamente
    # frente a una carpeta — acá se fuerza lo contrario: el catálogo
    # primero, la subcarpeta después, para probar que carpeta y página
    # compiten en el MISMO pool numérico cuando ambas tienen orden manual.
    :ok = MetaSchemaContext.reordenar_hermanos([catalogo.schema_context_name, subcarpeta.schema_context_name])

    hijos =
      MetaSchemaContext.listar_headers_arbol()
      |> Enum.find(&(&1.tipo == :carpeta and &1.id == padre.schema_context_name))
      |> Map.fetch!(:hijos)
      |> Enum.map(&{&1.tipo, &1.id})

    assert hijos == [{:pagina, catalogo.schema_context_name}, {:carpeta, subcarpeta.schema_context_name}]
  end
end
