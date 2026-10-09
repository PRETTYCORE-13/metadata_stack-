defmodule MetadataApp.ValoresDefaultTest do
  @moduledoc "SPEC-SYS-1109202601 §2.4 (R41-R48): valores default de los campos y fecha local."
  use MetadataApp.DataCase, async: true

  alias MetadataApp.{Hoy, Repo}
  alias MetadataApp.Autenticacion.Empresa
  alias MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico
  alias MetadataApp.MetaBusinessProcess.Catalogos.MetaFixtureCliente

  describe "Hoy (R48)" do
    test "de noche en México la fecha local sigue siendo hoy aunque en UTC ya sea mañana" do
      # 21:00 del 8 de octubre en Ciudad de México = 03:00 UTC del 9.
      assert Hoy.ahora(~U[2026-10-09 03:00:00Z]) |> DateTime.to_date() == ~D[2026-10-08]
    end
  end

  describe "resolver_valor_default/2 y validar_valor_default/2 (R42, R43)" do
    test "hoy, hoy+N, hoy-N y valores fijos" do
      hoy = Hoy.fecha()
      assert MetaCatalogoGenerico.resolver_valor_default(:date, "hoy") == hoy
      assert MetaCatalogoGenerico.resolver_valor_default(:date, "hoy+3") == Date.add(hoy, 3)
      assert MetaCatalogoGenerico.resolver_valor_default(:date, "hoy-2") == Date.add(hoy, -2)
      assert MetaCatalogoGenerico.resolver_valor_default(:string, "ABC") == "ABC"
    end

    test "acepta lo válido por tipo y rechaza lo demás con el motivo" do
      assert :ok = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "date"}, "hoy+30")
      assert :ok = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "date"}, "2026-12-31")
      assert {:error, _} = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "date"}, "mañana")
      assert {:error, _} = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "date"}, "hoy+0")
      assert :ok = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "hora"}, "ahora")
      assert :ok = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "hora"}, "08:30")
      assert {:error, _} = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "integer"}, "1.5")
      assert :ok = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "decimal"}, "1.5")
      assert {:error, _} = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "boolean"}, "si")
      assert {:error, _} = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "enum", "valores" => ["A", "B"]}, "C")
      assert {:error, _} = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "string", "longitud" => 3}, "ABCD")
      assert :ok = MetaCatalogoGenerico.validar_valor_default(%{"tipo" => "string"}, "")
    end
  end

  describe "forzar_defaults/3 (R45-R47)" do
    setup do
      {:ok, empresa} = %Empresa{} |> Empresa.changeset(%{nombre: "Empresa default #{System.unique_integer()}"}) |> Repo.insert()

      campos = [
        {:fecha, :date, %{opcional: false, valor_default: "hoy"}},
        {:nota, :string, %{opcional: true, valor_default: "sin nota"}},
        {:empresa, :integer, %{opcional: true, tabla_referenciada: "meta_schema_empresa", valor_default: to_string(empresa.id)}},
        {:otra, :integer, %{opcional: true, tabla_referenciada: "meta_schema_empresa", valor_default: "999999999"}}
      ]

      %{campos: campos, empresa: empresa}
    end

    test "en un alta llena obligatorio y opcional ausentes; referencia solo si existe", %{campos: campos, empresa: empresa} do
      attrs = MetaCatalogoGenerico.forzar_defaults(%MetaFixtureCliente{}, %{}, campos)

      assert attrs["fecha"] == Hoy.fecha()
      assert attrs["nota"] == "sin nota"
      assert attrs["empresa"] == empresa.id
      refute Map.has_key?(attrs, "otra")
    end

    test "un opcional que llega vacío se respeta; un obligatorio vacío toma el default", %{campos: campos} do
      attrs = MetaCatalogoGenerico.forzar_defaults(%MetaFixtureCliente{}, %{"nota" => "", "fecha" => ""}, campos)

      assert attrs["nota"] == ""
      assert attrs["fecha"] == Hoy.fecha()
    end

    test "al editar un registro existente no aplica (R46)", %{campos: campos} do
      guardado = Ecto.put_meta(%MetaFixtureCliente{}, state: :loaded)
      assert MetaCatalogoGenerico.forzar_defaults(guardado, %{"nota" => "x"}, campos) == %{"nota" => "x"}
    end

    test "respeta llaves de átomo en attrs", %{campos: campos} do
      attrs = MetaCatalogoGenerico.forzar_defaults(%MetaFixtureCliente{}, %{nota: "x"}, campos)
      assert attrs[:fecha] == Hoy.fecha()
      assert attrs[:nota] == "x"
    end
  end
end
