defmodule MetadataApp.FolioTest do
  @moduledoc """
  NDT (Numeración de Documentos Transaccionales) — el gancho que asigna
  folio al crear, de punta a punta vía `CatalogoGenerico.crear/2` real
  (mismo catálogo dedicado que alcance_de_datos_escritura_test.exs,
  extendido con trn/ulid/folio — ver la migración
  agregar_trn_folio_a_meta_fixture_alcance).
  """
  use MetadataApp.DataCase

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.Permissions
  alias MetadataApp.BusinessProcessBuilder.CatalogoGenerico
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaFixtureAlcance
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyNdtConfiguracion

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp header_fixture(attrs \\ %{}) do
    base = %{
      schema_context_name: "meta_fixture_alcance",
      schema_context_label: "Fixture alcance",
      schema_context_type: 1,
      schema_context_nav: "/catalogos/fixture-folio-#{System.unique_integer([:positive])}",
      schema_visible: true,
      schema_es_transaccional: true,
      codigo_trn: "FLIO",
      alcance_habilitado: true
    }

    {:ok, header} = %Header{} |> Header.changeset(Map.merge(base, attrs)) |> Ecto.Changeset.put_change(:insert_guid, guid()) |> Repo.insert()
    header
  end

  defp jerarquia do
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa folio #{System.unique_integer()}", dueno.id)
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca #{System.unique_integer()}"})

    {:ok, inventory_location} =
      Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Producto terminado"})

    %{empresa: empresa, branch: branch, inventory_location: inventory_location}
  end

  defp scope_global(usuario, empresa, header) do
    {:ok, rol} = Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol #{System.unique_integer()}"})
    {:ok, _} = Permissions.definir_alcance_de_rol(rol.id, header.id, :global)
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)
    %Scope{usuario: usuario, empresa_activa: empresa, branch_activo: nil}
  end

  # `pty_ndt_configuracion` es un BC real del motor de catálogos
  # (2026-08-31) -- crear/2 pasa por su autómata (nace en Activo), igual
  # que cualquier catálogo real, ver moduledoc de MetadataApp.NDT.Numbering.
  defp perfil_fixture(header, empresa) do
    {:ok, perfil} =
      CatalogoGenerico.crear(PtyNdtConfiguracion, :sistema, %{
        "documento" => header.id,
        "organizacion" => empresa.id,
        "serie" => "TST",
        "prefijo" => "TST-",
        "padding" => 4
      })

    perfil
  end

  test "requiere_folio: false (default) no toca folio, aunque el catálogo sea transaccional" do
    header = header_fixture()
    %{empresa: empresa, branch: branch, inventory_location: inventory} = jerarquia()
    usuario = usuario_fixture()
    scope = scope_global(usuario, empresa, header)

    assert {:ok, registro} =
             CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{
               "nombre" => "sin folio",
               "branch_id" => branch.id,
               "inventory_id" => inventory.id
             })

    assert registro.trn
    refute registro.folio
  end

  test "requiere_folio: true asigna folio además del trn, resolviendo la Organización vía branch_id" do
    header = header_fixture(%{requiere_folio: true})
    %{empresa: empresa, branch: branch, inventory_location: inventory} = jerarquia()
    perfil_fixture(header, empresa)
    usuario = usuario_fixture()
    scope = scope_global(usuario, empresa, header)

    assert {:ok, registro} =
             CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{
               "nombre" => "con folio",
               "branch_id" => branch.id,
               "inventory_id" => inventory.id
             })

    assert registro.trn
    assert registro.folio == "TST-0001"

    assert {:ok, registro_2} =
             CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{
               "nombre" => "con folio dos",
               "branch_id" => branch.id,
               "inventory_id" => inventory.id
             })

    assert registro_2.folio == "TST-0002"
  end

  test "requiere_folio: true sin ningún perfil configurado para esa organización falla la creación" do
    header = header_fixture(%{requiere_folio: true})
    %{empresa: empresa, branch: branch, inventory_location: inventory} = jerarquia()
    # A propósito, SIN perfil_fixture/2.
    usuario = usuario_fixture()
    scope = scope_global(usuario, empresa, header)

    assert {:error, :perfil_no_encontrado} =
             CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{
               "nombre" => "sin perfil",
               "branch_id" => branch.id,
               "inventory_id" => inventory.id
             })
  end

  describe "Header.changeset/2 — validación de requiere_folio" do
    test "rechaza requiere_folio: true sin schema_es_transaccional" do
      changeset =
        Header.changeset(%Header{}, %{
          schema_context_name: "x_#{System.unique_integer()}",
          schema_context_label: "X",
          schema_context_type: 1,
          schema_context_nav: "/catalogos/x-#{System.unique_integer()}",
          schema_visible: true,
          schema_es_transaccional: false,
          alcance_habilitado: true,
          requiere_folio: true
        })

      refute changeset.valid?
      assert %{requiere_folio: mensajes} = errors_on(changeset)
      assert Enum.any?(mensajes, &(&1 =~ "transaccional"))
    end

    test "rechaza requiere_folio: true sin alcance_habilitado" do
      changeset =
        Header.changeset(%Header{}, %{
          schema_context_name: "x_#{System.unique_integer()}",
          schema_context_label: "X",
          schema_context_type: 1,
          schema_context_nav: "/catalogos/x-#{System.unique_integer()}",
          schema_visible: true,
          schema_es_transaccional: true,
          codigo_trn: "TEST",
          alcance_habilitado: false,
          requiere_folio: true
        })

      refute changeset.valid?
      assert %{requiere_folio: mensajes} = errors_on(changeset)
      assert Enum.any?(mensajes, &(&1 =~ "Alcance de Datos"))
    end

    test "acepta requiere_folio: true con ambos flags activos" do
      changeset =
        Header.changeset(%Header{}, %{
          schema_context_name: "x_#{System.unique_integer()}",
          schema_context_label: "X",
          schema_context_type: 1,
          schema_context_nav: "/catalogos/x-#{System.unique_integer()}",
          schema_visible: true,
          schema_es_transaccional: true,
          codigo_trn: "TEST",
          alcance_habilitado: true,
          requiere_folio: true
        })

      assert changeset.valid?
    end
  end
end
