defmodule MetadataApp.SeedMasterdataReferenciaTest do
  use MetadataApp.DataCase, async: true

  alias MetadataApp.SeedMasterdata
  alias MetadataApp.Autenticacion.Empresa

  # Empresa (catálogo de sistema, siempre disponible, sin depender de
  # ningún pty_* de dev) como catálogo destino de una referencia —
  # mismo patrón ya usado en meta_consultas_test.exs.
  defp unique, do: System.unique_integer([:positive])

  describe "resolver_referencia/2 — encuentra por valor natural (R11)" do
    test "campo_visualizacion modo \"descripcion\"" do
      {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa Seed Test #{unique()}"}) |> Repo.insert()

      props = %{
        "tipo" => "referencia",
        "catalogo" => "meta_schema_empresa",
        "campo_visualizacion" => %{"modo" => "descripcion", "campo_descripcion" => "nombre"}
      }

      assert SeedMasterdata.resolver_referencia(props, empresa.nombre) == {:ok, empresa.id}
    end

    test "sin campo_visualizacion, cae a campos_acompanamiento" do
      {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa Acompanamiento #{unique()}"}) |> Repo.insert()

      props = %{"tipo" => "referencia", "catalogo" => "meta_schema_empresa", "campos_acompanamiento" => ["nombre"]}

      assert SeedMasterdata.resolver_referencia(props, empresa.nombre) == {:ok, empresa.id}
    end
  end

  describe "resolver_referencia/2 — errores" do
    test "no encuentra el valor -> error claro, no crashea" do
      props = %{
        "tipo" => "referencia",
        "catalogo" => "meta_schema_empresa",
        "campo_visualizacion" => %{"modo" => "descripcion", "campo_descripcion" => "nombre"}
      }

      assert {:error, mensaje} = SeedMasterdata.resolver_referencia(props, "Empresa que no existe #{unique()}")
      assert mensaje =~ "no se encontró"
      assert mensaje =~ "meta_schema_empresa"
    end

    test "catálogo destino SIN campo_visualizacion ni campos_acompanamiento -> error proactivo, no \"no encontrado\"" do
      {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa Sin Config #{unique()}"}) |> Repo.insert()

      props = %{"tipo" => "referencia", "catalogo" => "meta_schema_empresa"}

      assert {:error, mensaje} = SeedMasterdata.resolver_referencia(props, empresa.nombre)
      assert mensaje =~ "no tiene campo_visualizacion ni campos_acompanamiento configurado"
    end
  end
end
