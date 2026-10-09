defmodule MetadataApp.BusinessProcessBuilder.PrefijoDirectorioTest do
  # SPEC-SYS-2909202601 (Prefijo de directorio), R2/R4/R6/R7.
  use MetadataApp.DataCase, async: true

  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext

  defp unique, do: System.unique_integer([:positive])

  defp attrs_carpeta(prefijo) do
    sufijo = unique()

    %{
      "schema_context_name" => "pty_carpeta_prefijo_#{sufijo}",
      "schema_context_label" => "Carpeta #{sufijo}",
      "schema_context_nav" => "/prefijo-#{sufijo}",
      "schema_visible" => true,
      "schema_context_type" => 2,
      "prefijo_directorio" => prefijo
    }
  end

  defp crear_carpeta(prefijo) do
    MetaSchemaContext.crear_header_con_detalles(Map.put(attrs_carpeta(prefijo), "detalles", []))
  end

  describe "Header.changeset/2" do
    test "pasa el prefijo a mayúsculas" do
      changeset = Header.changeset(%Header{}, attrs_carpeta("ch"))

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :prefijo_directorio) == "CH"
    end

    test "prefijo vacío queda en nil (la obligatoriedad es de la pantalla, no del schema)" do
      changeset = Header.changeset(%Header{}, attrs_carpeta(""))

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :prefijo_directorio) == nil
    end

    test "acepta de 1 a 5 letras o dígitos" do
      for prefijo <- ["C", "CH", "VTA", "RH01", "ABCDE"] do
        assert Header.changeset(%Header{}, attrs_carpeta(prefijo)).valid?, "debió aceptar #{prefijo}"
      end
    end

    test "rechaza más de 5 caracteres y caracteres fuera de A-Z0-9" do
      for prefijo <- ["ABCDEF", "C H", "CÁ", "C-H", "C_H"] do
        changeset = Header.changeset(%Header{}, attrs_carpeta(prefijo))

        refute changeset.valid?, "debió rechazar #{prefijo}"
        assert Keyword.has_key?(changeset.errors, :prefijo_directorio)
      end
    end
  end

  describe "unicidad (índice parcial)" do
    test "rechaza un prefijo repetido con error en prefijo_directorio (R4, R7)" do
      assert {:ok, _} = crear_carpeta("DUP")
      assert {:error, changeset} = crear_carpeta("DUP")

      assert {_mensaje, detalles} = changeset.errors[:prefijo_directorio]
      assert detalles[:constraint] == :unique
    end

    test "dos carpetas sin prefijo conviven (el índice ignora nil)" do
      assert {:ok, _} = crear_carpeta(nil)
      assert {:ok, _} = crear_carpeta(nil)
    end

    test "eliminar una carpeta libera su prefijo (R6)" do
      {:ok, {header, _}} = crear_carpeta("LIB")
      assert :ok = MetaSchemaContext.eliminar_header(header)

      assert {:ok, _} = crear_carpeta("LIB")
    end

    test "obtener_header_por_prefijo_directorio/1 encuentra solo headers vivos" do
      {:ok, {header, _}} = crear_carpeta("BUS")

      assert MetaSchemaContext.obtener_header_por_prefijo_directorio("BUS").id == header.id
      assert MetaSchemaContext.obtener_header_por_prefijo_directorio("NOEX") == nil
    end
  end
end
