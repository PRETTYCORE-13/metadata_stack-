defmodule MetadataApp.BusinessProcessBuilder.AlcanceDeDatosTest do
  @moduledoc """
  Fase 4a del modelo de Alcance de Datos (2026-08-11) — prueba real,
  contra Postgres, de que `aplicar_alcance_de_datos/3` (el choke point
  único de lectura, enganchado en `listar/obtener!/contar/agregar`)
  filtra de verdad, para cada uno de los 6 `alcance_tipo`. Usa
  `MetadataApp.MetaFixtureAlcance` (test/support), un catálogo dedicado
  con las 4 columnas de la jerarquía + creado_por_id.
  """
  use MetadataApp.DataCase

  import MetadataApp.AutenticacionFixtures

  alias MetadataApp.Repo
  alias MetadataApp.Autenticacion
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.Permissions
  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerico, MetaSchemaContext}
  alias MetadataApp.BusinessProcessBuilder.MetaSchema.Header
  alias MetadataApp.MetaFixtureAlcance

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp header_fixture(alcance_habilitado?) do
    {:ok, header} =
      %Header{}
      |> Header.changeset(%{
        schema_context_name: "meta_fixture_alcance",
        schema_context_label: "Fixture alcance",
        schema_context_type: 1,
        schema_context_nav: "/catalogos/fixture-alcance-#{System.unique_integer([:positive])}",
        schema_visible: true,
        alcance_habilitado: alcance_habilitado?
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

  # `crear_empresa_para_usuario/2` deja al creador como "administrador" de
  # esa empresa (comodín total en alcance_tipo_efectivo/2, bypassea
  # CUALQUIER rol_alcance) -- por eso la jerarquía la arma siempre un
  # usuario "dueño" descartable, nunca el usuario bajo prueba, o cada test
  # de alcance no-admin estaría probando contra un administrador sin
  # darse cuenta.
  defp jerarquia do
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa alcance CG #{System.unique_integer()}", dueno.id)
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})

    {:ok, sales_unit} =
      Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})

    {:ok, inventory_location} =
      Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Producto terminado"})

    %{empresa: empresa, branch: branch, sales_unit: sales_unit, inventory_location: inventory_location}
  end

  # Arma un Scope real: rol con alcance_tipo en el header, asignado al
  # usuario, más branches/sales_units/inventory_locations permitidos
  # hidratados a mano (mismo shape que UsuarioAuth.hidratar_alcance/1,
  # sin pasar por el pipeline HTTP completo).
  defp scope_con_alcance(usuario, empresa, header, tipo, alcance_asignado \\ %{}) do
    rol = Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol #{System.unique_integer()}"}) |> elem(1)
    {:ok, _} = Permissions.definir_alcance_de_rol(rol.id, header.id, tipo)
    {:ok, _} = Permissions.asignar_rol(usuario.id, rol.id, empresa.id)

    %Scope{
      usuario: usuario,
      empresa_activa: empresa,
      branches_permitidos: Map.get(alcance_asignado, :branches_permitidos, []),
      sales_units_permitidas: Map.get(alcance_asignado, :sales_units_permitidas, []),
      inventory_locations_permitidas: Map.get(alcance_asignado, :inventory_locations_permitidas, [])
    }
  end

  describe "catálogo con alcance_habilitado: false" do
    test "listar/obtener! no filtran nada, sin importar el scope" do
      header_fixture(false)
      usuario_a = usuario_fixture()
      usuario_b = usuario_fixture()
      registro = fixture_registro(%{creado_por_id: usuario_a.id})

      scope_b = %Scope{usuario: usuario_b, empresa_activa: %{id: -1}}

      assert [^registro] = CatalogoGenerico.listar(MetaFixtureAlcance, scope_b, %{"id" => registro.id})
      assert CatalogoGenerico.obtener!(MetaFixtureAlcance, scope_b, registro.id).id == registro.id
    end
  end

  describe ":sistema bypasea todo, incluso con alcance_habilitado: true" do
    test "ve cualquier fila" do
      header_fixture(true)
      registro = fixture_registro(%{})

      assert [^registro] = CatalogoGenerico.listar(MetaFixtureAlcance, :sistema, %{"id" => registro.id})
    end
  end

  describe "nil (sin autenticar) con alcance_habilitado: true" do
    test "cero filas, deny-by-default" do
      header_fixture(true)
      fixture_registro(%{})

      assert CatalogoGenerico.listar(MetaFixtureAlcance, nil) == []
    end
  end

  describe "alcance_tipo :propio" do
    test "solo ve lo que el propio usuario creó" do
      header = header_fixture(true)
      usuario_a = usuario_fixture()
      usuario_b = usuario_fixture()
      %{empresa: empresa} = jerarquia()

      mio = fixture_registro(%{creado_por_id: usuario_a.id})
      ajeno = fixture_registro(%{creado_por_id: usuario_b.id})

      scope = scope_con_alcance(usuario_a, empresa, header, :propio)

      resultado = CatalogoGenerico.listar(MetaFixtureAlcance, scope)
      ids = Enum.map(resultado, & &1.id)

      assert mio.id in ids
      refute ajeno.id in ids
    end

    test "obtener! sobre una fila ajena da Ecto.NoResultsError, no la fila" do
      header = header_fixture(true)
      usuario_a = usuario_fixture()
      usuario_b = usuario_fixture()
      %{empresa: empresa} = jerarquia()

      ajeno = fixture_registro(%{creado_por_id: usuario_b.id})
      scope = scope_con_alcance(usuario_a, empresa, header, :propio)

      assert_raise Ecto.NoResultsError, fn -> CatalogoGenerico.obtener!(MetaFixtureAlcance, scope, ajeno.id) end
    end
  end

  describe "alcance_tipo :branch" do
    test "ve todas las filas de SUS branches permitidas, ninguna de otra" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida} = jerarquia()
      {:ok, branch_no_permitida} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})

      de_mi_branch = fixture_registro(%{branch_id: branch_permitida.id})
      de_otra_branch = fixture_registro(%{branch_id: branch_no_permitida.id})

      scope = scope_con_alcance(usuario, empresa, header, :branch, %{branches_permitidos: [branch_permitida.id]})

      ids = CatalogoGenerico.listar(MetaFixtureAlcance, scope) |> Enum.map(& &1.id)
      assert de_mi_branch.id in ids
      refute de_otra_branch.id in ids
    end
  end

  describe "alcance_tipo :sales_unit" do
    test "ve solo su Unidad de Ventas puntual, ni siquiera otra de la MISMA sucursal" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch, sales_unit: mi_unidad} = jerarquia()
      {:ok, otra_unidad} = Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 2"})

      de_mi_unidad = fixture_registro(%{sales_unit_id: mi_unidad.id})
      de_otra_unidad = fixture_registro(%{sales_unit_id: otra_unidad.id})

      scope = scope_con_alcance(usuario, empresa, header, :sales_unit, %{sales_units_permitidas: [mi_unidad.id]})

      ids = CatalogoGenerico.listar(MetaFixtureAlcance, scope) |> Enum.map(& &1.id)
      assert de_mi_unidad.id in ids
      refute de_otra_unidad.id in ids
    end
  end

  describe "alcance_tipo :inventory_location" do
    test "ve solo sus ubicaciones de inventario permitidas (\"opera con sus inventarios permitidos\")" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch, inventory_location: mi_ubicacion} = jerarquia()

      {:ok, otra_ubicacion} =
        Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Producción"})

      de_mi_ubicacion = fixture_registro(%{inventory_id: mi_ubicacion.id})
      de_otra_ubicacion = fixture_registro(%{inventory_id: otra_ubicacion.id})

      scope = scope_con_alcance(usuario, empresa, header, :inventory_location, %{inventory_locations_permitidas: [mi_ubicacion.id]})

      ids = CatalogoGenerico.listar(MetaFixtureAlcance, scope) |> Enum.map(& &1.id)
      assert de_mi_ubicacion.id in ids
      refute de_otra_ubicacion.id in ids
    end
  end

  describe "alcance_tipo :empresa y :global" do
    test ":empresa ve todo lo de su empresa activa (columna empresa_id no existe en el fixture -- no-op, ver nota)" do
      # MetaFixtureAlcance no tiene empresa_id (a propósito, para no
      # duplicar lo que branch_id ya cubre) -- este caso confirma el
      # comportamiento no-op documentado en con_columna/3: sin la columna,
      # el filtro simplemente no se aplica, nunca revienta.
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa} = jerarquia()
      registro = fixture_registro(%{})

      scope = scope_con_alcance(usuario, empresa, header, :empresa)
      assert Enum.any?(CatalogoGenerico.listar(MetaFixtureAlcance, scope), &(&1.id == registro.id))
    end

    test ":global no filtra nada" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa} = jerarquia()
      registro = fixture_registro(%{creado_por_id: usuario_fixture().id})

      scope = scope_con_alcance(usuario, empresa, header, :global)
      assert Enum.any?(CatalogoGenerico.listar(MetaFixtureAlcance, scope), &(&1.id == registro.id))
    end
  end

  describe "administrador es comodín (:global) sin fila en meta_schema_rol_alcance" do
    test "ve todo, incluso lo creado por otro usuario" do
      header_fixture(true)
      usuario = usuario_fixture()
      otro = usuario_fixture()
      {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa admin CG #{System.unique_integer()}", usuario.id)

      registro = fixture_registro(%{creado_por_id: otro.id})

      scope = %Scope{usuario: usuario, empresa_activa: empresa}
      assert Enum.any?(CatalogoGenerico.listar(MetaFixtureAlcance, scope), &(&1.id == registro.id))
    end
  end

  describe "contar/agregar respetan el mismo alcance que listar (Fase 4a, sin leak vía agregación)" do
    test "contar/3 solo cuenta las filas dentro del alcance" do
      header = header_fixture(true)
      usuario_a = usuario_fixture()
      usuario_b = usuario_fixture()
      %{empresa: empresa} = jerarquia()

      fixture_registro(%{creado_por_id: usuario_a.id})
      fixture_registro(%{creado_por_id: usuario_b.id})

      scope = scope_con_alcance(usuario_a, empresa, header, :propio)
      assert CatalogoGenerico.contar(MetaFixtureAlcance, scope) == 1
    end
  end

  test "MetaSchemaContext.obtener_header_por_nombre/1 confirma alcance_habilitado persistido" do
    header = header_fixture(true)
    assert MetaSchemaContext.obtener_header_por_nombre("meta_fixture_alcance").id == header.id
    assert MetaSchemaContext.obtener_header_por_nombre("meta_fixture_alcance").alcance_habilitado == true
  end
end
