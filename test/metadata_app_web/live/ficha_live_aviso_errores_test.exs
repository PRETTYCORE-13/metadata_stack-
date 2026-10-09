defmodule MetadataAppWeb.FichaLiveAvisoErroresTest do
  @moduledoc """
  Aviso de "No se pudo guardar" de la Ficha: el error de un campo que no se
  puede marcar en rojo (de solo lectura, o fuera de la plantilla publicada)
  se lista con su etiqueta; el de un campo editable visible se queda junto
  a su input.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MetadataAppWeb.FichaLive

  defp columnas, do: [col("folio", "Folio"), col("total", "Total")]

  defp col(campo, etiqueta), do: %{schema_context_field: campo, schema_context_properties: %{"etiqueta" => etiqueta}}

  defp aviso(errores, opts \\ []) do
    render_component(&FichaLive.aviso_errores/1,
      errores: errores,
      columnas: columnas(),
      campos_editables: Keyword.get(opts, :editables, ["folio"]),
      plantilla: Keyword.get(opts, :plantilla)
    )
  end

  test "un campo de solo lectura con error se lista con su etiqueta" do
    html = aviso(%{total: ["no puede tener más de 2 decimales"]})
    assert html =~ "Total"
    assert html =~ "no puede tener más de 2 decimales"
    refute html =~ "marcados en rojo"
  end

  test "un campo editable visible solo pide revisar los marcados en rojo" do
    html = aviso(%{folio: ["no puede estar vacío"]})
    assert html =~ "revisa los campos marcados en rojo"
    refute html =~ "<li"
  end

  test "un campo editable que no está en la plantilla publicada también se lista" do
    plantilla = %{definicion: %{"tipo" => "raiz", "propiedades" => %{}, "hijos" => []}}
    html = aviso(%{folio: ["no puede estar vacío"]}, plantilla: plantilla)
    assert html =~ "Folio"
    assert html =~ "no puede estar vacío"
  end

  test "sin errores no pinta nada" do
    refute aviso(%{}) =~ "aviso-errores-guardado"
  end
end
