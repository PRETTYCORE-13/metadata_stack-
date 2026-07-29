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

  test "reordenar_raices/1 hace que el orden manual gane sobre el alfabético" do
    sufijo = unique()
    nombre_a = "aaa_orden_#{sufijo}"
    nombre_z = "zzz_orden_#{sufijo}"

    crear_carpeta_raiz(nombre_a, "Alfa #{sufijo}")
    crear_carpeta_raiz(nombre_z, "Zeta #{sufijo}")

    # "Zeta" primero a propósito — sin esto el orden alfabético ya la
    # pondría después, no probaría nada.
    :ok = MetaSchemaContext.reordenar_raices([nombre_z, nombre_a])

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
    :ok = MetaSchemaContext.reordenar_raices([nombre_z, nombre_a])

    nombres =
      MetaSchemaContext.listar_menu_arbol()
      |> Enum.filter(&(&1.tipo == :carpeta and String.ends_with?(&1.id || "", "_#{sufijo}")))
      |> Enum.map(& &1.nombre)

    assert nombres == ["Zeta #{sufijo}", "Alfa #{sufijo}"]
  end

  test "reordenar_raices/1 ignora nil en la lista en vez de reventar (carpeta implícita sin Header propio)" do
    sufijo = unique()
    nombre_a = "aaa_orden_#{sufijo}"
    crear_carpeta_raiz(nombre_a, "Alfa #{sufijo}")

    assert :ok = MetaSchemaContext.reordenar_raices([nil, nombre_a, nil])
  end

  test "una carpeta con orden manual siempre va antes que una sin orden asignado" do
    sufijo = unique()
    # "aaa" ganaría alfabéticamente si no fuera por el orden manual en "zzz".
    nombre_a = "aaa_orden_#{sufijo}"
    nombre_z = "zzz_orden_#{sufijo}"

    crear_carpeta_raiz(nombre_a, "Alfa #{sufijo}")
    crear_carpeta_raiz(nombre_z, "Zeta #{sufijo}")
    :ok = MetaSchemaContext.reordenar_raices([nombre_z])

    nombres =
      MetaSchemaContext.listar_headers_arbol()
      |> Enum.filter(&(&1.tipo == :carpeta and String.ends_with?(&1.id || "", "_#{sufijo}")))
      |> Enum.map(& &1.nombre)

    assert nombres == ["Zeta #{sufijo}", "Alfa #{sufijo}"]
  end
end
