defmodule MetadataApp.NDT.NumberingTest do
  @moduledoc """
  Motor NDT (Numeración de Documentos Transaccionales) — pruebas contra
  Postgres real, sin mocks. Los perfiles (`pty_ndt_configuracion`) son un
  BC real del motor de catálogos (2026-08-31, ver moduledoc de
  MetadataApp.NDT.Numbering) — se crean acá vía CatalogoGenerico.crear/2,
  igual que cualquier catálogo real, no un schema a mano.
  """
  use MetadataApp.DataCase

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.NDT.{Numbering, NumberRange, NumberingAudit}
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyNdtConfiguracion

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp header_fixture do
    {:ok, header} =
      %Header{}
      |> Header.changeset(%{
        schema_context_name: "ndt_fixture_#{System.unique_integer([:positive])}",
        schema_context_label: "Fixture NDT",
        schema_context_type: 1,
        schema_context_nav: "/catalogos/ndt-fixture-#{System.unique_integer([:positive])}",
        schema_visible: true
      })
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert()

    header
  end

  defp organizacion do
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa NDT #{System.unique_integer()}", dueno.id)
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca #{System.unique_integer()}"})
    %{empresa: empresa, branch: branch}
  end

  # Vía el motor real -- `pty_ndt_configuracion` adoptó el autómata
  # (Activo/Cancelado), así que crear/2 pasa por la transición "alta" y
  # nace en Activo, igual que cualquier catálogo real con estados.
  defp perfil_fixture(header, empresa, attrs \\ %{}) do
    base = %{"documento" => header.id, "organizacion" => empresa.id, "serie" => "PED", "prefijo" => "PED-", "padding" => 6}
    {:ok, perfil} = CatalogoGenerico.crear(PtyNdtConfiguracion, :sistema, Map.merge(base, attrs))
    perfil
  end

  describe "folios" do
    test "primer folio y siguiente folio son consecutivos" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa, %{"numero_inicial" => 1025})

      assert {:ok, %{folio: "PED-001025", secuencia: 1025}} =
               Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)

      assert {:ok, %{folio: "PED-001026", secuencia: 1026}} =
               Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
    end

    test "prefijo + padding personalizados" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa, %{"serie" => "FAC", "prefijo" => "FAC-", "padding" => 4})

      assert {:ok, %{folio: "FAC-0001"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id, serie: "FAC")
    end

    test "sin prefijo/sufijo, solo el número con padding" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa, %{"prefijo" => "", "padding" => 3})

      assert {:ok, %{folio: "001"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
    end

    test "incluir_anio agrega el segmento de año calculado" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa, %{"serie" => "FAC", "prefijo" => "FAC-", "incluir_anio" => "true", "padding" => 6})

      anio = Calendar.strftime(DateTime.utc_now(), "%Y")
      assert {:ok, %{folio: folio}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id, serie: "FAC")
      assert folio == "FAC-#{anio}-000001"
    end

    test "dos series distintas del mismo tipo de documento llevan contadores independientes" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa, %{"serie" => "PED"})
      perfil_fixture(header, empresa, %{"serie" => "PED-WEB", "prefijo" => "PED-WEB-"})

      assert {:ok, %{folio: "PED-000001"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id, serie: "PED")
      assert {:ok, %{folio: "PED-WEB-000001"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id, serie: "PED-WEB")
      assert {:ok, %{folio: "PED-000002"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id, serie: "PED")
    end

    test "más de una serie activa sin indicar cuál es ambiguo" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa, %{"serie" => "PED"})
      perfil_fixture(header, empresa, %{"serie" => "PED-WEB", "prefijo" => "PED-WEB-"})

      assert {:error, :serie_ambigua} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
    end

    test "un perfil Cancelado no califica -- se comporta como si no existiera" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil = perfil_fixture(header, empresa)

      {:ok, _} = MetadataApp.MetaStateEngine.ejecutar_transicion(perfil, "dar_de_baja", %{})

      assert {:error, :perfil_no_encontrado} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
    end

    test "reinicio: períodos distintos no comparten contador (perfil anual)" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil = perfil_fixture(header, empresa, %{"politica_reinicio" => "anual", "incluir_anio" => "true"})

      assert {:ok, %{folio: folio_1}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
      assert {:ok, %{folio: folio_2}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
      assert folio_1 != folio_2

      # Simula el reinicio anual insertando a mano el rango de un año
      # PASADO ya "consumido" -- el rango del año en curso (el que
      # Numbering.next/1 usó arriba) sigue en 2, sin contaminarse.
      periodo_pasado = "#{String.to_integer(Calendar.strftime(DateTime.utc_now(), "%Y")) - 1}"
      %NumberRange{} |> NumberRange.changeset(%{pty_ndt_configuracion_id: perfil.id, periodo: periodo_pasado, numero_actual: 999}) |> Repo.insert!()

      assert {:ok, %{secuencia: 3}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
    end

    test "perfil de unidad operativa específica tiene prioridad, cae a centralizado si no hay" do
      %{empresa: empresa, branch: branch} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa, %{"serie" => "PED", "prefijo" => "CENTRAL-"})

      assert {:ok, %{folio: "CENTRAL-000001"}} =
               Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id, branch_id: branch.id)

      perfil_fixture(header, empresa, %{"serie" => "PED", "unidad_operativa" => branch.id, "prefijo" => "SUCURSAL-"})

      assert {:ok, %{folio: "SUCURSAL-000001"}} =
               Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id, branch_id: branch.id)

      # El centralizado sigue intacto, no fue tocado por el pedido de sucursal.
      assert {:ok, %{folio: "CENTRAL-000002"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
    end
  end

  describe "idempotencia" do
    test "el mismo idempotency_key devuelve el mismo folio sin incrementar de nuevo" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa)

      opts = [meta_schema_header_id: header.id, empresa_id: empresa.id, idempotency_key: "pedido-42"]

      assert {:ok, %{folio: "PED-000001"}} = Numbering.next(opts)
      assert {:ok, %{folio: "PED-000001"}} = Numbering.next(opts)
      assert {:ok, %{folio: "PED-000001"}} = Numbering.next(opts)

      assert {:ok, %{folio: "PED-000002"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
    end
  end

  describe "multi-tenant" do
    test "dos organizaciones con la misma serie no comparten contador" do
      header = header_fixture()
      %{empresa: empresa_a} = organizacion()
      %{empresa: empresa_b} = organizacion()
      perfil_fixture(header, empresa_a)
      perfil_fixture(header, empresa_b)

      assert {:ok, %{folio: "PED-000001"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa_a.id)
      assert {:ok, %{folio: "PED-000001"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa_b.id)
      assert {:ok, %{folio: "PED-000002"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa_a.id)
    end
  end

  describe "concurrencia" do
    test "100 pedidos concurrentes devuelven 100 folios únicos, sin huecos ni duplicados" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa)

      # Este módulo NO se declara `async: true` a propósito -- DataCase
      # arranca el sandbox en modo compartido (`shared: not tags[:async]`,
      # ver setup_sandbox/1) precisamente para esto: que los 100 procesos
      # de Task.async_stream de abajo puedan usar la MISMA conexión sin
      # checkout manual, y de verdad ejercer la carrera contra el lock de
      # fila real (SELECT ... FOR UPDATE) en vez de contra 100 conexiones
      # aisladas que nunca se pisarían entre sí.
      folios =
        1..100
        |> Task.async_stream(
          fn _ -> Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id) end,
          max_concurrency: 20,
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, {:ok, %{folio: folio}}} -> folio end)

      assert length(folios) == 100
      assert length(Enum.uniq(folios)) == 100

      secuencias = Enum.map(folios, fn "PED-" <> numero -> String.to_integer(numero) end)
      assert Enum.sort(secuencias) == Enum.to_list(1..100)
    end
  end

  describe "anular/1" do
    test "marca anulado_at sin liberar ni reutilizar el folio" do
      %{empresa: empresa} = organizacion()
      header = header_fixture()
      perfil_fixture(header, empresa)

      assert {:ok, %{numbering_audit_id: audit_id, folio: "PED-000001"}} =
               Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)

      assert {:ok, %NumberingAudit{anulado_at: %DateTime{}}} = Numbering.anular(audit_id)

      # El siguiente pedido sigue en 2 -- el folio anulado NO se reutiliza.
      assert {:ok, %{folio: "PED-000002"}} = Numbering.next(meta_schema_header_id: header.id, empresa_id: empresa.id)
    end
  end
end
