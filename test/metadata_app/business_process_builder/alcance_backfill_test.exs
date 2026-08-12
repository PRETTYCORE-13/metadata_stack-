defmodule MetadataApp.BusinessProcessBuilder.AlcanceBackfillTest do
  @moduledoc """
  Fase 6b del modelo de Alcance de Datos (2026-08-11) — prueba real,
  contra Postgres, de `AlcanceBackfill.backfillear_creado_por/1` y de
  la lectura NULL-permisiva que la motiva (`aplicar_where_de_alcance/4`
  en `CatalogoGenerico`).
  """
  use MetadataApp.DataCase

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.Permissions
  alias MetadataApp.BusinessProcessBuilder.{AlcanceBackfill, CatalogoGenerico}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaSchema.Auditoria
  alias MetadataApp.MetaFixtureAlcance

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp header_fixture do
    {:ok, header} =
      %Header{}
      |> Header.changeset(%{
        schema_context_name: "meta_fixture_alcance",
        schema_context_label: "Fixture alcance",
        schema_context_type: 1,
        schema_context_nav: "/catalogos/fixture-alcance-backfill-#{System.unique_integer([:positive])}",
        schema_visible: true,
        alcance_habilitado: true
      })
      |> Ecto.Changeset.put_change(:insert_guid, guid())
      |> Repo.insert()

    header
  end

  defp fixture_registro(attrs) do
    %MetaFixtureAlcance{}
    |> MetaFixtureAlcance.changeset(Map.merge(%{nombre: "registro #{System.unique_integer([:positive])}"}, attrs))
    |> Ecto.Changeset.put_change(:insert_guid, guid())
    |> Repo.insert!()
  end

  defp registrar_alta(registro, usuario_id) do
    %Auditoria{}
    |> Auditoria.changeset(%{
      bc: "meta_fixture_alcance",
      operacion: "alta",
      guid: guid(),
      entidad_id: registro.id,
      datos: %{},
      usuario_id: usuario_id
    })
    |> Repo.insert!()
  end

  defp scope_propio(usuario, empresa, header) do
    rol = Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol #{System.unique_integer()}"}) |> elem(1)
    {:ok, _} = Permissions.definir_alcance_de_rol(rol.id, header.id, :propio)
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)
    %Scope{usuario: usuario, empresa_activa: empresa}
  end

  test "backfillear_creado_por/1 completa creado_por_id desde el evento 'alta' de auditoría" do
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa backfill #{System.unique_integer()}", dueno.id)
    header = header_fixture()

    autor = usuario_fixture()
    registro = fixture_registro(%{})
    registrar_alta(registro, autor.id)

    assert AlcanceBackfill.backfillear_creado_por(MetaFixtureAlcance) == 1
    assert Repo.get!(MetaFixtureAlcance, registro.id).creado_por_id == autor.id

    scope = scope_propio(autor, empresa, header)
    resultado = CatalogoGenerico.listar(MetaFixtureAlcance, scope)
    assert Enum.any?(resultado, &(&1.id == registro.id))

    otro = usuario_fixture()
    scope_otro = scope_propio(otro, empresa, header)
    resultado_otro = CatalogoGenerico.listar(MetaFixtureAlcance, scope_otro)
    refute Enum.any?(resultado_otro, &(&1.id == registro.id))
  end

  test "un registro sin rastro en auditoría se queda con creado_por_id nil pero sigue visible (NULL-permisivo)" do
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa backfill #{System.unique_integer()}", dueno.id)
    header = header_fixture()

    huerfano = fixture_registro(%{})
    # Sin evento de auditoría "alta" para este registro.

    assert AlcanceBackfill.backfillear_creado_por(MetaFixtureAlcance) == 0
    assert Repo.get!(MetaFixtureAlcance, huerfano.id).creado_por_id == nil

    cualquiera = usuario_fixture()
    scope = scope_propio(cualquiera, empresa, header)
    resultado = CatalogoGenerico.listar(MetaFixtureAlcance, scope)
    assert Enum.any?(resultado, &(&1.id == huerfano.id))
  end

  test "el backfill nunca toca branch_id/sales_unit_id/inventory_id" do
    autor = usuario_fixture()
    registro = fixture_registro(%{})
    registrar_alta(registro, autor.id)

    AlcanceBackfill.backfillear_creado_por(MetaFixtureAlcance)

    actualizado = Repo.get!(MetaFixtureAlcance, registro.id)
    assert actualizado.branch_id == nil
    assert actualizado.sales_unit_id == nil
    assert actualizado.inventory_id == nil
  end

  test "backfillear_creado_por/1 es no-op para un schema sin columna creado_por_id" do
    assert AlcanceBackfill.backfillear_creado_por(MetadataApp.Autenticacion.Empresa) == 0
  end
end
