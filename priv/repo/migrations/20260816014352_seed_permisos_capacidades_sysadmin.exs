defmodule MetadataApp.Repo.Migrations.SeedPermisosCapacidadesSysadmin do
  use Ecto.Migration

  # UI/permisos-sysadmin (2026-08-16, a pedido explícito): hasta acá, TODA
  # la administración de RBAC (Roles, Usuarios, RBAC Business Context,
  # Jerarquía organizacional, Credenciales, Acciones externas) compartía
  # un único recurso grueso "rbac_admin" -- quien podía entrar a UNA de
  # esas 6 pantallas podía entrar a las 6. Tepache compartía "sysadmin_bc"
  # con el resto del Business Process Builder de la misma forma. Esto
  # siembra un recurso PROPIO por pantalla (una por opción del menú
  # "Sysadmin", ver menu_layout.ex) + un rol de sistema dedicado con ESE
  # único permiso -- así el switch nuevo en la pestaña "Sysadmin" de
  # UsuariosEmpresaLive puede conceder/revocar una pantalla puntual sin
  # tocar las demás, reusando asignar_rol/revocar_rol tal cual (ver
  # Permissions.capacidades_sysadmin/0).
  #
  # Business Process Builder es la EXCEPCIÓN: bc_list/bc_motor/
  # plantilla_constructor/consulta_editor/bc_nuevo_completo/buscador_trn
  # ya comparten el recurso "sysadmin_bc" en 3 acciones (leer/crear/editar,
  # sembradas en 20260725020000) -- separarlo en un recurso nuevo exigiría
  # tocar 6 LiveViews con 3 acciones cada una, mucho más de lo pedido acá.
  # En vez de eso, el rol nuevo "acceso_sysadmin_bc" se linkea DIRECTO a
  # los 3 permisos "sysadmin_bc" YA EXISTENTES -- ni recurso ni LiveView
  # nuevos, el switch es simplemente una forma más cómoda de conceder ese
  # mismo bucket de siempre.
  #
  # Los roles de sistema VIEJOS ("rbac_admin"/"sysadmin_bc" como recurso)
  # NO se borran -- si algún rol no-administrador ya tenía "rbac_admin"
  # concedido, se le suman acá los 6 equivalentes finos; si ya tenía
  # "sysadmin_bc", se le suma el equivalente fino de Tepache. Así nadie
  # pierde acceso que ya tenía. "administrador" no necesita nada de esto
  # (bypasea todo permiso vivo, ver Permissions.cargar_permisos_de_db/2).
  @capacidades [
    {"sysadmin_tepache", "acceso_sysadmin_tepache", "Tepache Exp/Imp"},
    {"sysadmin_roles", "acceso_sysadmin_roles", "Roles"},
    {"sysadmin_empresas", "acceso_sysadmin_empresas", "Empresas"},
    {"sysadmin_usuarios", "acceso_sysadmin_usuarios", "RBAC Usuarios"},
    {"sysadmin_catalogos_permisos", "acceso_sysadmin_catalogos_permisos", "RBAC Business Context"},
    {"sysadmin_jerarquia", "acceso_sysadmin_jerarquia", "Jerarquía organizacional"},
    {"sysadmin_credenciales", "acceso_sysadmin_credenciales", "Credenciales"},
    {"sysadmin_acciones_externas", "acceso_sysadmin_acciones_externas", "Acciones externas"}
  ]

  def up do
    for {recurso, rol_nombre, etiqueta} <- @capacidades do
      {1, [%{id: permiso_id}]} =
        repo().insert_all(
          "meta_schema_permiso",
          [%{recurso: recurso, accion: "leer", descripcion: "Acceso a #{etiqueta} (Sysadmin)", insert_guid: guid()}],
          returning: [:id]
        )

      rol_id = crear_rol_sistema(rol_nombre, "Acceso a #{etiqueta} (Sysadmin)")
      repo().insert_all("meta_schema_rol_permiso", [%{rol_id: rol_id, permiso_id: permiso_id, insert_guid: guid()}])
    end

    # Compat hacia atrás ANTES de crear acceso_sysadmin_bc a propósito --
    # si corriera después, la búsqueda de "quién tiene sysadmin_bc/leer
    # concedido" encontraría el rol RECIÉN CREADO (que se linkea a
    # sysadmin_bc de fábrica, ver más abajo) y le sumaría sysadmin_tepache
    # a sí mismo -- contaminación real encontrada al probar esta migración.
    migrar_grants_existentes("rbac_admin", [
      "sysadmin_roles",
      "sysadmin_usuarios",
      "sysadmin_catalogos_permisos",
      "sysadmin_jerarquia",
      "sysadmin_credenciales",
      "sysadmin_acciones_externas"
    ])

    migrar_grants_existentes("sysadmin_bc", ["sysadmin_tepache"])

    bc_rol_id = crear_rol_sistema("acceso_sysadmin_bc", "Acceso a Business Process Builder (Sysadmin)")

    %{rows: permisos_bc} = repo().query!("SELECT id FROM meta_schema_permiso WHERE recurso = 'sysadmin_bc'")

    filas_bc = for [permiso_id] <- permisos_bc, do: %{rol_id: bc_rol_id, permiso_id: permiso_id, insert_guid: guid()}
    repo().insert_all("meta_schema_rol_permiso", filas_bc)
  end

  defp crear_rol_sistema(nombre, descripcion) do
    {1, [%{id: rol_id}]} =
      repo().insert_all(
        "meta_schema_rol",
        [%{empresa_id: nil, nombre: nombre, descripcion: descripcion, es_sistema: true, insert_guid: guid()}],
        returning: [:id]
      )

    rol_id
  end

  # Cualquier rol (que no sea "administrador", ya cubierto por bypass) que
  # tuviera el permiso VIEJO concedido recibe acá los permisos NUEVOS
  # equivalentes -- conserva el acceso que ya tenía, sin que nadie tenga
  # que volver a tildar nada a mano.
  defp migrar_grants_existentes(recurso_viejo, recursos_nuevos) do
    %{rows: roles_con_el_viejo} =
      repo().query!(
        """
        SELECT DISTINCT rp.rol_id
        FROM meta_schema_rol_permiso rp
        JOIN meta_schema_permiso p ON p.id = rp.permiso_id AND p.delete_guid IS NULL
        JOIN meta_schema_rol r ON r.id = rp.rol_id AND r.delete_guid IS NULL
        WHERE p.recurso = $1 AND p.accion = 'leer' AND rp.delete_guid IS NULL
          AND NOT (r.es_sistema = true AND r.nombre = 'administrador')
        """,
        [recurso_viejo]
      )

    for [rol_id] <- roles_con_el_viejo, recurso_nuevo <- recursos_nuevos do
      %{rows: [[permiso_id]]} =
        repo().query!("SELECT id FROM meta_schema_permiso WHERE recurso = $1 AND accion = 'leer'", [recurso_nuevo])

      repo().query!(
        """
        INSERT INTO meta_schema_rol_permiso (rol_id, permiso_id, insert_guid)
        VALUES ($1, $2, $3)
        ON CONFLICT DO NOTHING
        """,
        [rol_id, permiso_id, guid()]
      )
    end
  end

  defp guid, do: Ecto.UUID.generate() |> String.replace("-", "")

  def down do
    for {recurso, rol_nombre, _etiqueta} <- @capacidades do
      execute("DELETE FROM meta_schema_rol WHERE nombre = '#{rol_nombre}' AND es_sistema = true")
      execute("DELETE FROM meta_schema_permiso WHERE recurso = '#{recurso}'")
    end

    execute("DELETE FROM meta_schema_rol WHERE nombre = 'acceso_sysadmin_bc' AND es_sistema = true")
  end
end
