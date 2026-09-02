defmodule MetadataApp.IdentificadoresTransaccionalesTest do
  @moduledoc """
  SPEC-SYS-0109202601 (Administrador de Folios) — motor de asignación,
  probado directo (`asignar/4`) contra Postgres real, sin pasar
  todavía por `catalogo_generico.ex` (eso es Grupo E). Perfiles
  (`pty_folio_perfiles`) se crean vía `CatalogoGenerico.crear/2` real
  — es un BC como cualquier otro, ver design.md §6.
  """
  use MetadataApp.DataCase

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.IdentificadoresTransaccionales
  alias MetadataApp.MetaFixtureAlcance
  alias MetadataApp.MetaStateEngine
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyFolioPerfiles
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtySubtiposTransaccion

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp header_fixture(attrs \\ %{}) do
    base = %{
      schema_context_name: "meta_fixture_alcance",
      schema_context_label: "Fixture folios",
      schema_context_type: 1,
      schema_context_nav: "/catalogos/fixture-folio-#{System.unique_integer([:positive])}",
      schema_visible: true,
      schema_es_transaccional: true,
      codigo_trn: "FLIO",
      requiere_folio: true
    }

    {:ok, header} = %Header{} |> Header.changeset(Map.merge(base, attrs)) |> Ecto.Changeset.put_change(:insert_guid, guid()) |> Repo.insert()
    header
  end

  defp organizacion do
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa folios #{System.unique_integer()}", dueno.id)
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca #{System.unique_integer()}"})
    %{empresa: empresa, branch: branch}
  end

  defp perfil_fixture(header, attrs \\ %{}) do
    base = %{"documento" => header.id, "serie" => "AAAA", "numero_inicial" => 1}
    {:ok, perfil} = CatalogoGenerico.crear(PtyFolioPerfiles, :sistema, Map.merge(base, renombrar_subtipo(attrs)))
    perfil
  end

  # El campo público de subtipo en pty_folio_perfiles se renombró
  # (2026-09-02, vía Field Designer, de `subtipo_transaccion` suelto a
  # `pty_folio_perfiles_subtipos_transaccion` como referencia real →
  # ver identificadores_transaccionales/folio_perfil.ex) -- acá se
  # traduce para no reescribir cada llamada existente a
  # `perfil_fixture/2` en este archivo.
  defp renombrar_subtipo(attrs) do
    case Map.pop(attrs, "subtipo_transaccion") do
      {nil, attrs} -> attrs
      {valor, attrs} -> Map.put(attrs, "pty_folio_perfiles_subtipos_transaccion", valor)
    end
  end

  defp subtipo_fixture(tipo_header, attrs \\ %{}) do
    base = %{"tipo_transaccion" => tipo_header.id, "descripcion" => "Subtipo #{System.unique_integer([:positive])}"}
    {:ok, subtipo} = CatalogoGenerico.crear(PtySubtiposTransaccion, :sistema, Map.merge(base, attrs))
    subtipo
  end

  defp dar_de_baja(subtipo) do
    {:ok, actualizado} = MetaStateEngine.ejecutar_transicion(subtipo, "baja", %{})
    actualizado
  end

  defp registro_fixture(attrs \\ %{}) do
    %MetaFixtureAlcance{} |> MetaFixtureAlcance.changeset(Map.merge(%{"nombre" => "reg #{System.unique_integer()}"}, attrs)) |> Ecto.Changeset.put_change(:insert_guid, guid()) |> Repo.insert!()
  end

  describe "asignar/4 — folio consecutivo" do
    test "primer folio respeta numero_inicial, siguiente es consecutivo" do
      header = header_fixture()
      perfil_fixture(header, %{"serie" => "PED1", "numero_inicial" => 1025})

      registro_1 = registro_fixture()
      assert {:ok, actualizado_1} = IdentificadoresTransaccionales.asignar(Repo, registro_1, header)
      assert actualizado_1.folio_serie == "PED1"
      assert actualizado_1.folio_numero == 1025

      registro_2 = registro_fixture()
      assert {:ok, actualizado_2} = IdentificadoresTransaccionales.asignar(Repo, registro_2, header)
      assert actualizado_2.folio_numero == 1026
    end

    test "Serie sin relleno de ceros en el folio (R1a) -- solo la Serie es fija en 4" do
      header = header_fixture()
      perfil_fixture(header, %{"serie" => "AB01"})
      registro = registro_fixture()

      assert {:ok, actualizado} = IdentificadoresTransaccionales.asignar(Repo, registro, header)
      assert actualizado.folio_serie == "AB01"
      assert actualizado.folio_numero == 1
    end

    test "TRN también se asigna en el mismo paso (design.md §1.2)" do
      header = header_fixture()
      perfil_fixture(header)
      registro = registro_fixture()

      assert {:ok, actualizado} = IdentificadoresTransaccionales.asignar(Repo, registro, header)
      assert actualizado.trn
      assert actualizado.ulid
    end
  end

  describe "asignar/4 — Sucursal: fallback a global" do
    test "perfil específico de Sucursal tiene prioridad; sin uno, cae a global" do
      %{branch: branch} = organizacion()
      header = header_fixture()
      perfil_fixture(header, %{"serie" => "GLOB", "sucursal" => nil})

      reg_sin_branch = registro_fixture()
      assert {:ok, %{folio_serie: "GLOB", folio_numero: 1}} = IdentificadoresTransaccionales.asignar(Repo, reg_sin_branch, header)

      reg_con_branch = registro_fixture(%{"branch_id" => branch.id})
      assert {:ok, %{folio_serie: "GLOB", folio_numero: 2}} = IdentificadoresTransaccionales.asignar(Repo, reg_con_branch, header)

      perfil_fixture(header, %{"serie" => "SUC1", "sucursal" => branch.id})

      reg_con_branch_2 = registro_fixture(%{"branch_id" => branch.id})
      assert {:ok, %{folio_serie: "SUC1", folio_numero: 1}} = IdentificadoresTransaccionales.asignar(Repo, reg_con_branch_2, header)

      # El global sigue intacto, no lo tocó el pedido con perfil específico.
      reg_sin_branch_2 = registro_fixture()
      assert {:ok, %{folio_serie: "GLOB", folio_numero: 3}} = IdentificadoresTransaccionales.asignar(Repo, reg_sin_branch_2, header)
    end
  end

  describe "asignar/4 — Subtipo: sin fallback (decisión confirmada)" do
    test "un subtipo sin perfil configurado explícitamente falla, no cae a un perfil genérico" do
      header = header_fixture()
      perfil_fixture(header, %{"subtipo_transaccion" => nil})

      registro = registro_fixture(%{"subtipo_transaccion" => 99})
      assert {:error, :perfil_no_encontrado} = IdentificadoresTransaccionales.asignar(Repo, registro, header)
    end

    test "con el subtipo exacto configurado, sí resuelve" do
      header = header_fixture()
      # subtipo_transaccion en pty_folio_perfiles pasó a ser `referencia`
      # con FK real (2026-09-02, vía Field Designer) -- necesita un
      # subtipo real, ya no alcanza un entero cualquiera.
      subtipo = subtipo_fixture(header)
      perfil_fixture(header, %{"subtipo_transaccion" => subtipo.id, "serie" => "SUB7"})

      registro = registro_fixture(%{"subtipo_transaccion" => subtipo.id})
      assert {:ok, %{folio_serie: "SUB7"}} = IdentificadoresTransaccionales.asignar(Repo, registro, header)
    end
  end

  describe "asignar/4 — sin perfil configurado" do
    test "falla con :perfil_no_encontrado" do
      header = header_fixture()
      registro = registro_fixture()

      assert {:error, :perfil_no_encontrado} = IdentificadoresTransaccionales.asignar(Repo, registro, header)
    end
  end

  describe "asignar/4 — subtipo dado de baja no puede foliar (2026-09-01, a pedido explícito)" do
    test "subtipo activo folía normal" do
      header = header_fixture()
      subtipo = subtipo_fixture(header)
      perfil_fixture(header, %{"serie" => "SUBX", "subtipo_transaccion" => subtipo.id})

      registro = registro_fixture(%{"subtipo_transaccion" => subtipo.id})
      assert {:ok, actualizado} = IdentificadoresTransaccionales.asignar(Repo, registro, header)
      assert actualizado.folio_serie == "SUBX"
      assert actualizado.folio_numero == 1
    end

    test "subtipo dado de baja bloquea el folio, ni toca el perfil" do
      header = header_fixture()
      subtipo = header |> subtipo_fixture() |> dar_de_baja()
      perfil = perfil_fixture(header, %{"serie" => "SUBB", "subtipo_transaccion" => subtipo.id})

      registro = registro_fixture(%{"subtipo_transaccion" => subtipo.id})
      assert {:error, :subtipo_dado_de_baja} = IdentificadoresTransaccionales.asignar(Repo, registro, header)

      # No se llegó ni a resolver_perfil -- el numero_actual del perfil
      # configurado para este subtipo sigue en 0, sin lock ni incremento.
      perfil_recargado = Repo.get!(MetadataApp.IdentificadoresTransaccionales.FolioPerfil, perfil.id)
      assert perfil_recargado.numero_actual == 0
    end
  end

  describe "asignar/4 — concurrencia (R3)" do
    test "100 pedidos concurrentes devuelven 100 folios únicos, consecutivos sin huecos" do
      header = header_fixture()
      perfil_fixture(header)

      registros = for _ <- 1..100, do: registro_fixture()

      # Este módulo NO se declara async: true a propósito -- DataCase
      # arranca el sandbox compartido (shared: not tags[:async]) para
      # que los 100 procesos de abajo puedan usar la misma conexión y
      # de verdad ejercer la carrera contra el SELECT ... FOR UPDATE.
      resultados =
        registros
        |> Task.async_stream(fn r -> IdentificadoresTransaccionales.asignar(Repo, r, header) end, max_concurrency: 20, timeout: 15_000)
        |> Enum.map(fn {:ok, {:ok, actualizado}} -> actualizado.folio_numero end)

      assert length(resultados) == 100
      assert length(Enum.uniq(resultados)) == 100
      assert Enum.sort(resultados) == Enum.to_list(1..100)
    end
  end
end
