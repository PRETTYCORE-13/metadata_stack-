defmodule MetadataApp.BusinessProcessBuilder.AlcanceDeDatosEscrituraTest do
  @moduledoc """
  Fase 4b del modelo de Alcance de Datos (2026-08-11) — lado escritura:
  `preparar_attrs_con_alcance/3` (crear) y `validar_alcance_en_changeset/3`
  (actualizar). Mismo catálogo dedicado que la Fase 4a
  (`MetadataApp.MetaFixtureAlcance`).
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

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  defp header_fixture(alcance_habilitado?) do
    {:ok, header} =
      %Header{}
      |> Header.changeset(%{
        schema_context_name: "meta_fixture_alcance",
        schema_context_label: "Fixture alcance",
        schema_context_type: 1,
        schema_context_nav: "/catalogos/fixture-alcance-escritura-#{System.unique_integer([:positive])}",
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

  # Mismo cuidado que en la Fase 4a: la jerarquía la arma siempre un
  # usuario "dueño" descartable, nunca el usuario bajo prueba -- si no,
  # crear_empresa_para_usuario/2 lo deja "administrador" (comodín total).
  defp jerarquia do
    dueno = usuario_fixture()
    {:ok, empresa} = Autenticacion.crear_empresa_para_usuario("Empresa alcance CG escritura #{System.unique_integer()}", dueno.id)
    {:ok, branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Toluca"})

    {:ok, sales_unit} =
      Autenticacion.crear_sales_unit(%{empresa_id: empresa.id, branch_id: branch.id, sales_unit_name: "Preventa 1"})

    {:ok, inventory_location} =
      Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Producto terminado"})

    %{empresa: empresa, branch: branch, sales_unit: sales_unit, inventory_location: inventory_location}
  end

  defp scope_con_alcance(usuario, empresa, header, tipo, alcance_asignado \\ %{}) do
    {:ok, rol} = Permissions.crear_rol(%{empresa_id: empresa.id, nombre: "Rol #{System.unique_integer()}"})
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

  describe "crear/4 — catálogo con alcance_habilitado: false" do
    test "no estampa creado_por_id ni valida nada" do
      header_fixture(false)
      usuario = usuario_fixture()
      scope = %Scope{usuario: usuario, empresa_activa: %{id: -1}}

      assert {:ok, registro} = CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{"nombre" => "sin alcance"})
      refute registro.creado_por_id
    end
  end

  describe "crear/4 — :sistema bypasea todo" do
    test "crea sin estampar ni validar, aunque alcance_habilitado: true" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_no_permitida} = jerarquia()
      scope_con_alcance(usuario, empresa, header, :branch, %{branches_permitidos: []})

      assert {:ok, registro} =
               CatalogoGenerico.crear(MetaFixtureAlcance, :sistema, %{"nombre" => "sistema", "branch_id" => branch_no_permitida.id})

      assert registro.branch_id == branch_no_permitida.id
      refute registro.creado_por_id
    end
  end

  # Bug operacional (2026-08-13, reportado por el usuario contra un
  # catálogo real: un administrador creó un registro y quedó sin
  # sucursal/almacén). validar_tipo_en_attrs(:global, ...) no exige nada
  # -- a propósito, describe QUÉ FILAS puede FILTRAR ese alcance_tipo
  # ("ve todo"), no si el registro nace con sucursal/almacén cargados.
  # validar_jerarquia_requerida_en_attrs/2 es la validación NUEVA e
  # INDEPENDIENTE de alcance_tipo que cierra ese hueco: si el catálogo
  # tiene Alcance de Datos, TODO registro nuevo exige sucursal + almacén,
  # sin importar quién lo crea ni qué alcance_tipo tenga.
  describe "crear/4 — alcance_tipo :global (administrador)" do
    test "bloquea igual que cualquier otro tipo si no hay sucursal/almacén activos" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa} = jerarquia()
      scope = scope_con_alcance(usuario, empresa, header, :global)

      assert {:error, {:alcance_requerido, "branch_id"}} =
               CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{"nombre" => "admin sin jerarquia"})
    end

    test "con sucursal/almacén activos en el scope, autocompleta y crea igual" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch, inventory_location: inventory_location} = jerarquia()

      scope =
        usuario
        |> scope_con_alcance(empresa, header, :global)
        |> Map.put(:branch_activo, branch)
        |> Map.put(:inventory_location_activo, inventory_location)

      assert {:ok, registro} = CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{"nombre" => "admin con jerarquia"})
      assert registro.branch_id == branch.id
      assert registro.inventory_id == inventory_location.id
    end
  end

  describe "crear/4 — nil (sin autenticar) con alcance_habilitado: true" do
    test "se rechaza, nunca llega a la base" do
      header_fixture(true)
      assert {:error, :sin_scope} = CatalogoGenerico.crear(MetaFixtureAlcance, nil, %{"nombre" => "anonimo"})
    end
  end

  describe "crear/4 — alcance_tipo :propio" do
    test "estampa creado_por_id con el usuario del scope, sin importar lo que venga en attrs" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      otro = usuario_fixture()
      %{empresa: empresa, branch: branch, inventory_location: inventory_location} = jerarquia()

      # Bug operacional (2026-08-13): branch/almacén activos en el scope --
      # sin importar el alcance_tipo (acá :propio, que no exige nada por sí
      # solo), validar_jerarquia_requerida_en_attrs/2 igual bloquea si el
      # registro nacería sin sucursal/almacén. Este test es sobre
      # creado_por_id, no sobre esa validación, así que le da lo que hace
      # falta para no chocar con ella.
      scope =
        usuario
        |> scope_con_alcance(empresa, header, :propio)
        |> Map.put(:branch_activo, branch)
        |> Map.put(:inventory_location_activo, inventory_location)

      assert {:ok, registro} =
               CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{"nombre" => "mio", "creado_por_id" => otro.id})

      # El intento de suplantar a "otro" como creador se ignora -- el
      # changeset generado ni siquiera castea creado_por_id (no es un
      # "campo" de meta_schema_detail), mismo mecanismo que ya protege
      # estado_id.
      assert registro.creado_por_id == usuario.id
    end
  end

  describe "crear/4 — alcance_tipo :branch" do
    test "rechaza crear con branch_id fuera de lo permitido" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida} = jerarquia()
      {:ok, branch_no_permitida} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})

      scope = scope_con_alcance(usuario, empresa, header, :branch, %{branches_permitidos: [branch_permitida.id]})

      assert {:error, "branch_id"} =
               CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{"nombre" => "fuera", "branch_id" => branch_no_permitida.id})
    end

    test "permite crear con branch_id dentro de lo permitido" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida, inventory_location: inventory_location} = jerarquia()
      scope = scope_con_alcance(usuario, empresa, header, :branch, %{branches_permitidos: [branch_permitida.id]})

      assert {:ok, registro} =
               CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{
                 "nombre" => "adentro",
                 "branch_id" => branch_permitida.id,
                 "inventory_id" => inventory_location.id
               })

      assert registro.branch_id == branch_permitida.id
    end

    # Comportamiento cambiado a propósito con la jerarquía operativa
    # activa (2026-08-11, extensión sobre Alcance de Datos): antes esto
    # devolvía {:ok, _} ("nada que validar" si branch_id no venía en
    # attrs). Ahora, si tampoco hay un branch ACTIVO en el scope
    # (Scope.branch_activo, ver UsuarioAuth.hidratar_jerarquia_activa/4),
    # el catálogo SÍ exige branch_id para :branch -- crearlo con la
    # columna en NULL sería visible para cualquiera bajo la regla
    # NULL-permisiva de Fase 6b, decisión de producto confirmada: bloquear
    # con un error claro y procesable en su lugar. Ver el par de tests de
    # abajo para el caso "SÍ hay branch activo" (autocompleta en vez de
    # bloquear).
    test "rechaza (bloquea) si no hay branch_id en attrs NI branch activo en el scope" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida} = jerarquia()
      scope = scope_con_alcance(usuario, empresa, header, :branch, %{branches_permitidos: [branch_permitida.id]})

      assert {:error, {:alcance_requerido, "branch_id"}} =
               CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{"nombre" => "sin branch"})
    end

    test "autocompleta branch_id con el branch activo del scope si attrs no trae uno explícito" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida, inventory_location: inventory_location} = jerarquia()

      scope =
        usuario
        |> scope_con_alcance(empresa, header, :branch, %{branches_permitidos: [branch_permitida.id]})
        |> Map.put(:branch_activo, branch_permitida)
        |> Map.put(:inventory_location_activo, inventory_location)

      assert {:ok, registro} = CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{"nombre" => "auto"})
      assert registro.branch_id == branch_permitida.id
    end

    test "un branch_id explícito en attrs gana sobre el branch activo del scope" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida, inventory_location: inventory_location} = jerarquia()
      {:ok, otra_branch_permitida} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Guadalajara"})
      Autenticacion.asignar_branch(usuario.id, otra_branch_permitida.id)

      scope =
        usuario
        |> scope_con_alcance(empresa, header, :branch, %{branches_permitidos: [branch_permitida.id, otra_branch_permitida.id]})
        |> Map.put(:branch_activo, branch_permitida)
        |> Map.put(:inventory_location_activo, inventory_location)

      assert {:ok, registro} =
               CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{"nombre" => "explicito", "branch_id" => otra_branch_permitida.id})

      assert registro.branch_id == otra_branch_permitida.id
    end
  end

  describe "crear/4 — alcance_tipo :inventory_location (\"opera con sus inventarios permitidos\")" do
    test "rechaza crear con inventory_id fuera de lo permitido" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch, inventory_location: mi_ubicacion} = jerarquia()

      {:ok, otra_ubicacion} =
        Autenticacion.crear_inventory_location(%{empresa_id: empresa.id, branch_id: branch.id, inventory_name: "Producción"})

      scope = scope_con_alcance(usuario, empresa, header, :inventory_location, %{inventory_locations_permitidas: [mi_ubicacion.id]})

      assert {:error, "inventory_id"} =
               CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{"nombre" => "fuera", "inventory_id" => otra_ubicacion.id})
    end
  end

  describe "actualizar/4" do
    test "editar un campo que NO es la dimensión de alcance funciona igual (no revalida lo que no cambió)" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida} = jerarquia()
      {:ok, branch_no_permitida} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})

      registro = fixture_registro(%{branch_id: branch_no_permitida.id})
      scope = scope_con_alcance(usuario, empresa, header, :branch, %{branches_permitidos: [branch_permitida.id]})

      # El registro ya existía con una branch FUERA del alcance del
      # usuario (creado directo por fixture, sin pasar por el choke
      # point) -- igual puede editar "nombre" sin tocar branch_id, porque
      # get_field/2 solo revisa el valor EFECTIVO cuando la dimensión
      # scopeada aparece en el changeset.
      assert {:ok, actualizado} = CatalogoGenerico.actualizar(registro, scope, %{"nombre" => "renombrado"})
      assert actualizado.nombre == "renombrado"
    end

    test "rechaza cambiar branch_id a un valor fuera de lo permitido" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida} = jerarquia()
      {:ok, branch_no_permitida} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})

      registro = fixture_registro(%{branch_id: branch_permitida.id})
      scope = scope_con_alcance(usuario, empresa, header, :branch, %{branches_permitidos: [branch_permitida.id]})

      assert {:error, changeset} = CatalogoGenerico.actualizar(registro, scope, %{"branch_id" => branch_no_permitida.id})
      assert %{branch_id: ["fuera de tu alcance permitido"]} = errors_on(changeset)
    end

    test "permite cambiar branch_id a otro valor SÍ permitido" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida} = jerarquia()
      {:ok, otra_branch_permitida} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Querétaro"})

      registro = fixture_registro(%{branch_id: branch_permitida.id})

      scope =
        scope_con_alcance(usuario, empresa, header, :branch, %{
          branches_permitidos: [branch_permitida.id, otra_branch_permitida.id]
        })

      assert {:ok, actualizado} = CatalogoGenerico.actualizar(registro, scope, %{"branch_id" => otra_branch_permitida.id})
      assert actualizado.branch_id == otra_branch_permitida.id
    end

    test ":sistema bypasea la validación de escritura" do
      header_fixture(true)
      %{empresa: empresa, branch: branch} = jerarquia()
      {:ok, otra_branch} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Otra"})

      registro = fixture_registro(%{branch_id: branch.id})

      assert {:ok, actualizado} = CatalogoGenerico.actualizar(registro, :sistema, %{"branch_id" => otra_branch.id})
      assert actualizado.branch_id == otra_branch.id
    end
  end

  describe "crear_muchos/4" do
    test "todo o nada -- si UN item viola el alcance, ninguno se crea" do
      header = header_fixture(true)
      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida} = jerarquia()
      {:ok, branch_no_permitida} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})

      scope = scope_con_alcance(usuario, empresa, header, :branch, %{branches_permitidos: [branch_permitida.id]})

      lista = [
        %{"nombre" => "ok", "branch_id" => branch_permitida.id},
        %{"nombre" => "malo", "branch_id" => branch_no_permitida.id}
      ]

      assert {:error, _motivo} = CatalogoGenerico.crear_muchos(MetaFixtureAlcance, scope, lista)
      refute Repo.get_by(MetaFixtureAlcance, nombre: "ok")
    end
  end

  # Hallazgo real (2026-08-11, catálogo pty_dsd_empleados_funcion en uso
  # real) -- un catálogo que ADEMÁS adoptó el motor de estados (transición
  # "alta") crea sus registros vía MetaStateEngine.dar_de_alta/5, un
  # camino de creación DISTINTO de crear_simple/3 -- sin
  # estampar_campos_alcance_post_insert/3 (agregado acá), branch_id/
  # sales_unit_id/inventory_id/creado_por_id quedaban NULL para siempre en
  # cada alta, sin ningún error visible, aunque preparar_attrs_con_alcance/3
  # ya los hubiera validado/estampado en `attrs` correctamente.
  describe "crear/4 — catálogo con motor de estados adoptado (transición \"alta\")" do
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

    test "estampa creado_por_id y valida/persiste branch_id igual que crear_simple/3" do
      header = header_fixture(true)
      :ok = con_transicion_alta(header)

      usuario = usuario_fixture()
      %{empresa: empresa, branch: branch_permitida, inventory_location: inventory_location} = jerarquia()
      {:ok, branch_no_permitida} = Autenticacion.crear_branch(%{empresa_id: empresa.id, branch_name: "Puebla"})
      scope = scope_con_alcance(usuario, empresa, header, :branch, %{branches_permitidos: [branch_permitida.id]})

      assert {:error, "branch_id"} =
               CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{
                 "nombre" => "fuera",
                 "branch_id" => branch_no_permitida.id,
                 "inventory_id" => inventory_location.id
               })

      assert {:ok, registro} =
               CatalogoGenerico.crear(MetaFixtureAlcance, scope, %{
                 "nombre" => "adentro",
                 "branch_id" => branch_permitida.id,
                 "inventory_id" => inventory_location.id
               })

      assert registro.creado_por_id == usuario.id
      assert registro.branch_id == branch_permitida.id
      # dar_de_alta/5 sigue siendo quien asigna el estado -- confirma que
      # el paso extra no interfiere con el ciclo normal del motor.
      assert registro.estado_id
    end
  end
end
