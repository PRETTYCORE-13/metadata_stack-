defmodule MetadataApp.BusinessProcessBuilder.IdentificadoresTransaccionalesEngancheTest do
  @moduledoc """
  SPEC-SYS-0109202601 (Administrador de Folios) — Grupo E, tareas 20/21.
  A diferencia de `IdentificadoresTransaccionalesTest` (que llama
  `asignar/4` directo), esto pasa por el camino REAL de creación
  (`CatalogoGenerico.crear/3`), para los dos puntos de enganche que
  documenta design.md §1.1: `crear_simple/4` (sin motor de estados) y
  `MetaStateEngine.ejecutar_nucleo_alta/4` (con motor de estados, vía
  una transición "alta" configurada).

  Tarea 20 (regresión TRN): un catálogo transaccional SIN folio sigue
  recibiendo TRN igual que antes de este enganche, por los dos caminos.
  Tarea 21 (R7, atomicidad): si la creación falla DESPUÉS de que el
  folio ya se generó (folio_historial insertado, numero_actual
  incrementado), toda la transacción revierte -- ni el registro, ni el
  folio, ni el incremento quedan persistidos.
  """
  use MetadataApp.DataCase

  alias MetadataApp.Repo
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaFixtureAlcance
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyFolioPerfiles
  alias MetadataApp.IdentificadoresTransaccionales.FolioPerfil
  alias MetadataApp.IdentificadoresTransaccionales.FolioHistorial

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp header_fixture(attrs \\ %{}) do
    base = %{
      schema_context_name: "meta_fixture_alcance",
      schema_context_label: "Fixture enganche",
      schema_context_type: 1,
      schema_context_nav: "/catalogos/fixture-enganche-#{System.unique_integer([:positive])}",
      schema_visible: true,
      schema_es_transaccional: true,
      codigo_trn: "ENG1"
    }

    {:ok, header} =
      %Header{}
      |> Header.changeset(Map.merge(base, attrs))
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert()

    header
  end

  # Mismo patrón que alcance_de_datos_escritura_test.exs -- da de alta
  # una transición "alta" para forzar el camino MetaStateEngine.dar_de_alta/5
  # en vez de crear_simple/4.
  defp con_transicion_alta(header) do
    {:ok, estado} =
      %MetadataApp.MetaSchema.Estado{}
      |> MetadataApp.MetaSchema.Estado.changeset(%{
        meta_schema_header_id: header.id,
        nombre: "inicial_#{System.unique_integer([:positive])}",
        es_inicial: true,
        orden: System.unique_integer([:positive])
      })
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert()

    {:ok, _transicion} =
      %MetadataApp.MetaSchema.Transicion{}
      |> MetadataApp.MetaSchema.Transicion.changeset(%{
        meta_schema_header_id: header.id,
        accion: "alta",
        etiqueta: "Alta",
        estado_origen_id: nil,
        estado_destino_id: estado.id
      })
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert()

    :ok
  end

  defp perfil_fixture(header, attrs \\ %{}) do
    base = %{"documento" => header.id, "serie" => "AAAA", "numero_inicial" => 1}
    {:ok, perfil} = CatalogoGenerico.crear(PtyFolioPerfiles, :sistema, Map.merge(base, attrs))
    perfil
  end

  defp numero_actual(perfil_id), do: Repo.get!(FolioPerfil, perfil_id).numero_actual

  describe "Tarea 20 — regresión TRN (catálogo transaccional SIN folio)" do
    test "vía crear_simple/4 (sin motor de estados)" do
      _header = header_fixture(%{requiere_folio: false})

      assert {:ok, registro} = CatalogoGenerico.crear(MetaFixtureAlcance, :sistema, %{"nombre" => "sin folio simple"})

      assert registro.trn
      assert String.starts_with?(registro.trn, "ENG1-")
      assert registro.ulid
      assert is_nil(registro.folio_serie)
      assert is_nil(registro.folio_numero)
    end

    test "vía MetaStateEngine.ejecutar_nucleo_alta/4 (con motor de estados)" do
      header = header_fixture(%{requiere_folio: false})
      :ok = con_transicion_alta(header)

      assert {:ok, registro} = CatalogoGenerico.crear(MetaFixtureAlcance, :sistema, %{"nombre" => "sin folio motor"})

      assert registro.trn
      assert String.starts_with?(registro.trn, "ENG1-")
      assert registro.ulid
    end
  end

  describe "Tarea 21 — atomicidad R7 (folio+documento revierten juntos)" do
    test "si la creación falla DESPUÉS de generar el folio, nada queda persistido" do
      header = header_fixture(%{requiere_folio: true})
      perfil = perfil_fixture(header, %{"serie" => "R7XX"})

      assert numero_actual(perfil.id) == 0

      # renglones_spec apunta a un catálogo detalle inexistente ->
      # Renglones.crear_todos/3 falla DESPUÉS de que
      # IdentificadoresTransaccionales.asignar/4 ya insertó el folio y
      # actualizó numero_actual -- fuerza exactamente el escenario de R7.
      resultado =
        CatalogoGenerico.crear(
          MetaFixtureAlcance,
          :sistema,
          %{"nombre" => "r7 falla"},
          renglones: %{"catalogo_detalle_que_no_existe_zzz" => [%{}]}
        )

      assert {:error, _motivo} = resultado

      refute Repo.get_by(MetaFixtureAlcance, nombre: "r7 falla")
      assert numero_actual(perfil.id) == 0
      assert Repo.aggregate(FolioHistorial, :count, :id) == 0
    end

    test "sin falla, folio y documento se confirman juntos" do
      header = header_fixture(%{requiere_folio: true})
      perfil = perfil_fixture(header, %{"serie" => "R7OK"})

      assert {:ok, registro} = CatalogoGenerico.crear(MetaFixtureAlcance, :sistema, %{"nombre" => "r7 ok"})

      assert registro.folio_serie == "R7OK"
      assert registro.folio_numero == 1
      assert registro.trn
      assert numero_actual(perfil.id) == 1
      assert Repo.aggregate(FolioHistorial, :count, :id) == 1
    end
  end
end
