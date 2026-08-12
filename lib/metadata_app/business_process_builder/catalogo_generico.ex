defmodule MetadataApp.BusinessProcessBuilder.CatalogoGenerico do
  alias MetadataApp.Repo
  alias MetadataApp.Permissions
  alias MetadataApp.Autenticacion.Scope
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  import Ecto.Query

  # Fase 5 del modelo de Alcance de Datos (2026-08-11) — tipos compartidos
  # para las @spec de abajo. `scope :: Scope.t_ou_sistema()` en cada
  # función pública de lectura/escritura es la mitad del guardrail
  # estructural (la otra mitad es el check de Credo,
  # MetadataApp.CredoChecks.RepoDirectoConVariable) — Dialyzer atrapa un
  # valor del tipo equivocado (ej. `nil` colado por un typo de assign),
  # el compilador ya atrapa gratis la falta total del argumento (es
  # posicional, sin default).
  @typep busqueda :: {String.t(), [atom() | String.t()]} | nil

  # filtros: %{"campo" => valor, ...} — combinados con AND, solo columnas
  # reales de la tabla (no campos calculados como estado_nombre). Usado por
  # MetaBcApi.listar/2 para que una regla de negocio pueda filtrar otro
  # catálogo sin escribir la query a mano. `valor` acepta también una tupla
  # con operador — {:ilike, texto}, {:gte, valor}, {:lte, valor},
  # {:entre, {desde, hasta}} (cualquiera de los dos puede ir nil, ej.
  # {:entre, {100, nil}} es "desde 100 en adelante") — usado por
  # CatalogoLive para los filtros dinámicos por columna. Un valor plano
  # (no tupla) sigue siendo igualdad exacta, como siempre.
  #
  # opciones: [] por default — sin :limit/:offset trae TODO, el
  # comportamiento de siempre. MetaBcApi.listar/2 sigue llamando sin
  # opciones a propósito: una regla de negocio necesita ver el conjunto
  # COMPLETO de relacionados (sin_relacionados, mutar_relacionados), no una
  # página — paginar ahí rompería esas reglas en silencio. El único caller
  # que pasa :limit/:offset es CatalogoController.index/2 (la API HTTP).
  #
  # busqueda: nil por default, o {texto, campos} — a diferencia de filtros
  # (AND por columna, para acotar), esto es OR entre TODAS las columnas
  # dadas (para buscar rápido sin saber en qué campo está). campos castea
  # cada columna a texto para poder buscar "999" y encontrar un precio,
  # aunque la columna sea numérica.
  #
  # order_by es incondicional, no depende de opciones: sin un orden
  # estable, Postgres no garantiza el mismo resultado entre llamadas — con
  # LIMIT/OFFSET eso significa filas repetidas o salteadas entre páginas,
  # en silencio. Mismo tipo de bug ya visto antes en este proyecto
  # (exports sin order_by producían diffs sin sentido).
  # `scope` (Fase 4a del modelo de Alcance de Datos, 2026-08-11) — SIEMPRE
  # posicional, SIN default: obliga a que cada call site decida a
  # propósito quién pregunta (un Scope real, o el sentinel :sistema para
  # código interno sin usuario humano) en vez de dejarlo pasar en
  # silencio. Ver aplicar_alcance_de_datos/3 más abajo -- no-op si el
  # catálogo nunca activó alcance_habilitado, así que pasar el Scope real
  # acá es siempre seguro, nunca sobre-filtra un catálogo que no lo pidió.
  @spec listar(module(), Scope.t_ou_sistema(), map(), keyword(), busqueda()) :: [struct()]
  def listar(schema_mod, scope, filtros \\ %{}, opciones \\ [], busqueda \\ nil) do
    from(r in schema_mod, where: is_nil(r.delete_guid), order_by: [asc: r.id])
    |> aplicar_alcance_de_datos(scope, schema_mod)
    |> aplicar_filtros(filtros)
    |> aplicar_busqueda(busqueda)
    |> aplicar_paginacion(opciones)
    |> Repo.all()
  end

  # Total de filas para los mismos filtros/búsqueda, sin paginar — para
  # calcular total_paginas en la respuesta HTTP.
  @spec contar(module(), Scope.t_ou_sistema(), map(), busqueda()) :: non_neg_integer()
  def contar(schema_mod, scope, filtros \\ %{}, busqueda \\ nil) do
    from(r in schema_mod, where: is_nil(r.delete_guid))
    |> aplicar_alcance_de_datos(scope, schema_mod)
    |> aplicar_filtros(filtros)
    |> aplicar_busqueda(busqueda)
    |> Repo.aggregate(:count)
  end

  # Agregación (suma/promedio/mínimo/máximo/conteo) de una columna
  # numérica sobre TODAS las filas que matchean filtros/búsqueda — no
  # solo la página actual (ver "Resumen" en CatalogoLive). `funcion` es
  # uno de :sum/:avg/:min/:max/:count, el mismo vocabulario que acepta
  # Repo.aggregate/3 nativo — sin reinventar nada acá, solo reusar el
  # mismo filtrado que ya usan listar/3 y contar/3. Alcance acá también
  # (Fase 4a) -- sin esto, un usuario acotado seguiría viendo la suma/
  # conteo VERDADERO (sin filtrar) en el pie de la tabla aunque las filas
  # sí estén filtradas, un leak real vía agregación.
  @spec agregar(module(), Scope.t_ou_sistema(), atom() | String.t(), atom(), map(), busqueda()) :: number() | nil
  def agregar(schema_mod, scope, campo, funcion, filtros \\ %{}, busqueda \\ nil) do
    campo_atom = String.to_existing_atom(to_string(campo))

    from(r in schema_mod, where: is_nil(r.delete_guid))
    |> aplicar_alcance_de_datos(scope, schema_mod)
    |> aplicar_filtros(filtros)
    |> aplicar_busqueda(busqueda)
    |> Repo.aggregate(funcion, campo_atom)
  end

  # Público (no defp) — MetaConsultas.ejecutar/3 reusa exactamente esta
  # misma semántica de filtros para las Consultas Ecto (banda de filtros
  # idéntica a la de cualquier catálogo, en vez de reinventarla).
  def aplicar_filtros(query, filtros) do
    Enum.reduce(filtros, query, fn {campo, valor}, acc ->
      campo_atom = String.to_existing_atom(to_string(campo))
      aplicar_filtro(acc, campo_atom, valor)
    end)
  end

  defp aplicar_filtro(query, campo, {:ilike, texto}) do
    patron = "%#{texto}%"
    from(r in query, where: ilike(field(r, ^campo), ^patron))
  end

  defp aplicar_filtro(query, campo, {:gte, valor}) do
    from(r in query, where: field(r, ^campo) >= ^valor)
  end

  defp aplicar_filtro(query, campo, {:lte, valor}) do
    from(r in query, where: field(r, ^campo) <= ^valor)
  end

  defp aplicar_filtro(query, _campo, {:entre, {nil, nil}}), do: query
  defp aplicar_filtro(query, campo, {:entre, {desde, nil}}), do: aplicar_filtro(query, campo, {:gte, desde})
  defp aplicar_filtro(query, campo, {:entre, {nil, hasta}}), do: aplicar_filtro(query, campo, {:lte, hasta})

  defp aplicar_filtro(query, campo, {:entre, {desde, hasta}}) do
    from(r in query, where: field(r, ^campo) >= ^desde and field(r, ^campo) <= ^hasta)
  end

  # Pertenencia a una lista — usado por CatalogoLive para el filtro
  # "por default" de fecha de alta (ver MetaAuditoria.ids_creados_en_rango/3):
  # como los catálogos generados no tienen columna de timestamp propia, se
  # resuelve la lista de :id por afuera (vía auditoría) y se filtra acá.
  defp aplicar_filtro(query, campo, {:en, lista}) do
    from(r in query, where: field(r, ^campo) in ^lista)
  end

  defp aplicar_filtro(query, campo, valor) do
    from(r in query, where: field(r, ^campo) == ^valor)
  end

  def aplicar_busqueda(query, nil), do: query
  def aplicar_busqueda(query, {texto, _campos}) when texto in [nil, ""], do: query

  def aplicar_busqueda(query, {texto, campos}) do
    patron = "%#{texto}%"

    condicion =
      Enum.reduce(campos, dynamic(false), fn campo, acc ->
        campo_atom = String.to_existing_atom(to_string(campo))
        dynamic([r], ^acc or fragment("?::text ILIKE ?", field(r, ^campo_atom), ^patron))
      end)

    from(r in query, where: ^condicion)
  end

  def aplicar_paginacion(query, opciones) do
    query
    |> aplicar_limit(Keyword.get(opciones, :limit))
    |> aplicar_offset(Keyword.get(opciones, :offset))
  end

  defp aplicar_limit(query, nil), do: query
  defp aplicar_limit(query, limit), do: from(r in query, limit: ^limit)

  defp aplicar_offset(query, nil), do: query
  defp aplicar_offset(query, offset), do: from(r in query, offset: ^offset)

  @spec obtener!(module(), Scope.t_ou_sistema(), integer() | String.t()) :: struct()
  def obtener!(schema_mod, scope, id) do
    from(r in schema_mod, where: r.id == ^id and is_nil(r.delete_guid))
    |> aplicar_alcance_de_datos(scope, schema_mod)
    |> Repo.one!()
  end

  ## Alcance de Datos (Fase 4a, 2026-08-11) -- ver el moduledoc de
  ## MetadataApp.Autenticacion.Scope para el diseño completo. Único choke
  ## point de LECTURA: cualquier llamada a listar/contar/agregar/obtener!
  ## pasa por acá antes de tocar la base.

  defp aplicar_alcance_de_datos(query, :sistema, _schema_mod), do: query

  # `current_scope` es `nil` en un request sin autenticar (ver
  # Scope.for_usuario(nil)) -- deny-by-default real, no un crash: si el
  # catálogo tiene alcance activado, cero filas en vez de reventar o (peor)
  # devolver todo. En la práctica no debería llegar acá nunca (las rutas
  # que tocan catálogos ya exigen sesión), pero un choke point de
  # seguridad no debe confiar en que el caller nunca se equivoque.
  defp aplicar_alcance_de_datos(query, nil, schema_mod) do
    case MetaSchemaContext.obtener_header_por_nombre(schema_mod.__schema__(:source)) do
      %{alcance_habilitado: true} -> from(r in query, where: false)
      _ -> query
    end
  end

  defp aplicar_alcance_de_datos(query, %Scope{} = scope, schema_mod) do
    catalogo = schema_mod.__schema__(:source)

    case MetaSchemaContext.obtener_header_por_nombre(catalogo) do
      %{alcance_habilitado: true} = header ->
        scope
        |> Permissions.alcance_tipo_efectivo(header.id)
        |> aplicar_where_de_alcance(query, scope, schema_mod)

      # nil (catálogo sin header, ej. una tabla de sistema) o
      # alcance_habilitado: false -- sin cambios, comportamiento de
      # siempre. Deliberado: el flag es opt-in por catálogo (Fase 3), no
      # universal.
      _ ->
        query
    end
  end

  defp aplicar_where_de_alcance(:global, query, _scope, _schema_mod), do: query

  # `is_nil(field) or ...` en las 4 cláusulas de abajo (Fase 6b, backfill,
  # 2026-08-11) — a propósito, no un descuido: una fila que YA EXISTÍA
  # antes de activar alcance_habilitado en este catálogo no tiene forma de
  # saber a qué branch/sales_unit/inventory_location/usuario pertenece
  # (esos datos simplemente no existían) — sin este permiso, esas filas se
  # volverían invisibles de un día para el otro para cualquiera que no sea
  # :global/:empresa, la MISMA regresión que ya se evitó una vez con el
  # backfill de EstadoDetallePermiso. Fila NULL = visible para cualquier
  # alcance_tipo (mismo comportamiento que tenía el catálogo antes de
  # activar el flag); fila CON valor = filtrada normal. `creado_por_id` se
  # backfillea best-effort desde meta_schema_auditoria al prender el
  # toggle (ver AlcanceBackfill.backfillear_creado_por/1); branch/
  # sales_unit/inventory no tienen backfill automático posible (ningún
  # dato existente permite inferirlos) — quedan NULL, visibles para
  # todos, hasta que alguien los edite a mano.
  defp aplicar_where_de_alcance(:empresa, query, scope, schema_mod) do
    con_columna(query, schema_mod, :empresa_id, fn campo ->
      from(r in query, where: is_nil(field(r, ^campo)) or field(r, ^campo) == ^scope.empresa_activa.id)
    end)
  end

  defp aplicar_where_de_alcance(:branch, query, scope, schema_mod) do
    con_columna(query, schema_mod, :branch_id, fn campo ->
      from(r in query, where: is_nil(field(r, ^campo)) or field(r, ^campo) in ^scope.branches_permitidos)
    end)
  end

  defp aplicar_where_de_alcance(:sales_unit, query, scope, schema_mod) do
    con_columna(query, schema_mod, :sales_unit_id, fn campo ->
      from(r in query, where: is_nil(field(r, ^campo)) or field(r, ^campo) in ^scope.sales_units_permitidas)
    end)
  end

  defp aplicar_where_de_alcance(:inventory_location, query, scope, schema_mod) do
    con_columna(query, schema_mod, :inventory_id, fn campo ->
      from(r in query, where: is_nil(field(r, ^campo)) or field(r, ^campo) in ^scope.inventory_locations_permitidas)
    end)
  end

  defp aplicar_where_de_alcance(:propio, query, scope, schema_mod) do
    con_columna(query, schema_mod, :creado_por_id, fn campo ->
      from(r in query, where: is_nil(field(r, ^campo)) or field(r, ^campo) == ^scope.usuario.id)
    end)
  end

  # Deliberadamente permisivo (no-op, nunca raise) si el catálogo no tiene
  # la columna que ESE tipo de alcance necesita -- validar que un catálogo
  # con alcance_tipo :branch tenga de verdad branch_id es responsabilidad
  # de la UI que lo configura (Fase 6), no de este choke point de
  # lectura, que no puede distinguir "configurado mal" de "no aplica acá".
  defp con_columna(query, schema_mod, campo, construir_where) do
    if campo in schema_mod.__schema__(:fields), do: construir_where.(campo), else: query
  end

  # Si el catálogo definió una transición "alta" (estado_origen_id nil, ver
  # MetaStateEngine.transicion_alta/1), el nacimiento del registro pasa por el
  # mismo ciclo de reglas pre/post que cualquier transición — permite
  # prevalidar (campos_requeridos, requiere_rol, ...) o disparar efectos
  # (estampar_valor, notificar, ...) al crear, no solo al transicionar
  # después. Si el catálogo nunca definió esa transición (ej. pty_clientes
  # hoy), sigue el insert directo de siempre — 100% retrocompatible.
  #
  # Catálogo Maestro-Detalle (R6, alta atómica): `opciones[:renglones]`
  # (mapa `%{"catalogo_detalle" => [attrs, ...]}`, default `%{}`) crea los
  # renglones iniciales del maestro en el MISMO ciclo — ver
  # `MetadataApp.Renglones.crear_todos/3`. `%{}` = comportamiento 100%
  # igual que siempre para cualquier catálogo sin detalles.
  # `scope` (Fase 4b del modelo de Alcance de Datos, 2026-08-11) —
  # posicional, sin default, mismo criterio que listar/2. Se resuelve
  # ANTES de bifurcar a crear_simple/3 o MetaStateEngine.dar_de_alta/5
  # (esta última vive en otro módulo, sin changeset propio hasta adentro)
  # trabajando sobre `attrs` directo -- ver preparar_attrs_con_alcance/3.
  @spec crear(module(), Scope.t_ou_sistema(), map(), keyword()) :: {:ok, struct()} | {:error, term()}
  def crear(schema_mod, scope, attrs, opciones \\ []) do
    catalogo = schema_mod.__schema__(:source)
    renglones_spec = Keyword.get(opciones, :renglones, %{})
    contexto = Keyword.get(opciones, :contexto, %{})

    case preparar_attrs_con_alcance(schema_mod, scope, attrs) do
      {:error, _motivo} = error -> error
      {:ok, attrs} -> crear_con_attrs_preparados(schema_mod, catalogo, attrs, renglones_spec, contexto)
    end
  end

  defp crear_con_attrs_preparados(schema_mod, catalogo, attrs, renglones_spec, contexto) do
    # NOTA (2026-08-06): acá debería ir el contexto real (usuario_id/
    # empresa_id), no `attrs` de nuevo — MetaStateEngine.dar_de_alta/5
    # nunca ve quién hizo el alta, así que ningún TransicionEvento de
    # "alta" queda con usuario (ver tab Historial de la Ficha 360°) y el
    # chequeo automático de permisos por transición
    # (MetaStateEngine.verificar_permiso_transicion/3) se salta siempre
    # (mira `Map.has_key?(contexto, "usuario_id")`, y `attrs` no trae esa
    # llave). Detectado al investigar por qué el Historial no mostraba
    # usuario — el arreglo (pasar `Map.merge(attrs, contexto_confiable)`,
    # mismo criterio que aplicar_encabezado/6 en ficha_live.ex) queda
    # pendiente a propósito: activar el chequeo real de permisos deja sin
    # poder dar de alta a pty_marcas/pty_productos/pty_prueba/pty_prueba2/
    # pty_prueba3 (ningún rol tiene el permiso "alta" registrado ahí
    # todavía) hasta que alguien lo registre y conceda desde Permisos —
    # corregir esto sin ese paso antes rompe esos catálogos para todos,
    # incluido administrador.
    resultado =
      case MetadataApp.MetaStateEngine.transicion_alta(catalogo) do
        nil ->
          crear_simple(schema_mod, attrs, renglones_spec)

        transicion ->
          schema_mod
          |> MetadataApp.MetaStateEngine.dar_de_alta(attrs, transicion, attrs, renglones_spec)
          |> estampar_campos_alcance_post_insert(schema_mod, attrs)
      end

    # PrettyCore TRN (Fase 1) — Regla #1: ninguna operación transaccional
    # nace sin TRN. Corre DESPUÉS del insert (no en el mismo changeset)
    # para no acoplar MetadataApp.MetaStateEngine —deliberadamente
    # agnóstico del catálogo— a este concepto de negocio. Sin ventana
    # observable desde afuera: crear/2 no devuelve el registro hasta que
    # esto termina. No hace nada si el catálogo no es transaccional.
    resultado
    |> MetadataApp.TRN.asignar_si_transaccional()
    |> auditar_alta(catalogo, contexto)
  end

  ## Alcance de Datos en escritura (Fase 4b, 2026-08-11) — ver el moduledoc
  ## de MetadataApp.Autenticacion.Scope. A diferencia de la lectura
  ## (Fase 4a, un choke point único sobre Ecto.Query), acá trabaja sobre
  ## el MAPA `attrs` (crear/4 bifurca a crear_simple/3 o
  ## MetaStateEngine.dar_de_alta/5 ANTES de que exista ningún changeset) --
  ## por eso "preparar_attrs" y no "validar_changeset" en este lado.

  defp preparar_attrs_con_alcance(schema_mod, scope, attrs) do
    catalogo = schema_mod.__schema__(:source)

    case MetaSchemaContext.obtener_header_por_nombre(catalogo) do
      %{alcance_habilitado: true} = header -> preparar_attrs_alcance(schema_mod, scope, header, attrs)
      _ -> {:ok, attrs}
    end
  end

  defp preparar_attrs_alcance(_schema_mod, :sistema, _header, attrs), do: {:ok, attrs}
  defp preparar_attrs_alcance(_schema_mod, nil, _header, _attrs), do: {:error, :sin_scope}

  defp preparar_attrs_alcance(schema_mod, %Scope{} = scope, header, attrs) do
    attrs =
      attrs
      |> then(&estampar_creado_por_en_attrs(schema_mod, scope, &1))
      |> then(&estampar_jerarquia_activa_en_attrs(schema_mod, scope, &1))

    tipo = Permissions.alcance_tipo_efectivo(scope, header.id)

    with :ok <- validar_tipo_en_attrs(tipo, schema_mod, scope, attrs),
         :ok <- validar_jerarquia_requerida_en_attrs(schema_mod, attrs) do
      {:ok, attrs}
    end
  end

  # Bug operacional (2026-08-13): validar_tipo_en_attrs/4 de abajo describe
  # QUÉ FILAS puede FILTRAR cada alcance_tipo (:global/:propio no exigen
  # nada ahí, a propósito -- "ve todo"/"solo lo suyo" no necesitan acotar
  # ningún campo para FILTRAR). Pero eso es una pregunta distinta de "¿el
  # registro nace CON sucursal/almacén cargados?" -- si el catálogo activó
  # Alcance de Datos, la respuesta tiene que ser sí SIEMPRE, sin importar
  # el alcance_tipo de quien lo crea. Un administrador (:global, ve todo)
  # NO está exento: "ver todo" no es lo mismo que "no quedar registrado
  # dónde pasó esto". La jerarquía activa ya intentó autocompletar
  # branch_id/inventory_id (estampar_jerarquia_activa_en_attrs/3, arriba)
  # -- si acá sigue faltando es porque quien crea (admin incluido) no
  # tiene sucursal/almacén activa elegida en la banda de pie, y hay que
  # bloquear con el mismo error claro que ya usa validar_campo_requerido_en_attrs/4,
  # no dejar pasar el registro con la columna en NULL. sales_unit_id queda
  # afuera a propósito -- es el único opcional de los tres (ver moduledoc
  # de MetadataApp.Autenticacion.Scope).
  defp validar_jerarquia_requerida_en_attrs(schema_mod, attrs) do
    with :ok <- validar_presencia_en_attrs(schema_mod, attrs, "branch_id") do
      validar_presencia_en_attrs(schema_mod, attrs, "inventory_id")
    end
  end

  defp validar_presencia_en_attrs(schema_mod, attrs, campo) do
    campo_atom = String.to_existing_atom(campo)

    if campo_atom in schema_mod.__schema__(:fields) do
      case Map.get(attrs, campo) || Map.get(attrs, campo_atom) do
        nil -> {:error, {:alcance_requerido, campo}}
        _valor -> :ok
      end
    else
      :ok
    end
  end

  # Jerarquía operativa activa (2026-08-11, extensión sobre el modelo de
  # Alcance de Datos) -- al CREAR (nunca al actualizar/4: editar un campo
  # cualquiera de un registro existente no debería poder cambiarle la
  # sucursal por izquierda), branch_id/inventory_id/sales_unit_id se
  # autocompletan con lo que el usuario tiene activo (Scope.branch_activo
  # etc., ver UsuarioAuth.hidratar_jerarquia_activa/4) SOLO si el
  # formulario no trajo un valor explícito -- el valor explícito siempre
  # gana (ej. un campo de negocio real mapeado a branch_id), esto es
  # apenas el fallback para cuando no hay nada más. Mismo mecanismo de
  # con_columna que el resto del módulo: no-op si la columna no existe.
  defp estampar_jerarquia_activa_en_attrs(schema_mod, %Scope{} = scope, attrs) do
    attrs
    |> estampar_campo_activo(schema_mod, "branch_id", scope.branch_activo)
    |> estampar_campo_activo(schema_mod, "inventory_id", scope.inventory_location_activo)
    |> estampar_campo_activo(schema_mod, "sales_unit_id", scope.sales_unit_activo)
  end

  defp estampar_campo_activo(attrs, schema_mod, campo, activo) do
    campo_atom = String.to_existing_atom(campo)
    ya_trae_valor? = Map.has_key?(attrs, campo) or Map.has_key?(attrs, campo_atom)

    if campo_atom in schema_mod.__schema__(:fields) and not ya_trae_valor? and activo do
      Map.put(attrs, campo, activo.id)
    else
      attrs
    end
  end

  # creado_por_id (caso ":propio") se autoestampa SIEMPRE que la columna
  # exista, sin importar el alcance_tipo configurado -- es dato de
  # auditoría útil aunque el catálogo hoy no filtre por él, y evita tener
  # que re-crear el rol_alcance si más adelante alguien lo cambia a
  # :propio. Nunca editable después -- ver la nota en actualizar_directo/5,
  # el changeset generado ni siquiera lo castea (mismo mecanismo que ya
  # protege estado_id).
  defp estampar_creado_por_en_attrs(schema_mod, %Scope{usuario: usuario}, attrs) when not is_nil(usuario) do
    if :creado_por_id in schema_mod.__schema__(:fields) do
      Map.put(attrs, "creado_por_id", usuario.id)
    else
      attrs
    end
  end

  defp estampar_creado_por_en_attrs(_schema_mod, _scope, attrs), do: attrs

  defp validar_tipo_en_attrs(:global, _schema_mod, _scope, _attrs), do: :ok
  defp validar_tipo_en_attrs(:propio, _schema_mod, _scope, _attrs), do: :ok

  defp validar_tipo_en_attrs(:empresa, schema_mod, scope, attrs),
    do: validar_campo_en_attrs(schema_mod, attrs, "empresa_id", [scope.empresa_activa.id])

  defp validar_tipo_en_attrs(:branch, schema_mod, scope, attrs),
    do: validar_campo_requerido_en_attrs(schema_mod, attrs, "branch_id", scope.branches_permitidos)

  defp validar_tipo_en_attrs(:sales_unit, schema_mod, scope, attrs),
    do: validar_campo_requerido_en_attrs(schema_mod, attrs, "sales_unit_id", scope.sales_units_permitidas)

  defp validar_tipo_en_attrs(:inventory_location, schema_mod, scope, attrs),
    do: validar_campo_requerido_en_attrs(schema_mod, attrs, "inventory_id", scope.inventory_locations_permitidas)

  # Sin valor en attrs (ninguna de las dos formas de llave) = nada que
  # validar acá -- si el campo es requerido, validate_required ya lo
  # rechaza más adelante en el changeset real; esto solo cuida que, SI
  # viene un valor, esté dentro de lo permitido. Único uso hoy: :empresa
  # (empresa_id no se autocompleta como branch/sales_unit/inventory --
  # ver estampar_jerarquia_activa_en_attrs/3 -- porque empresa_activa
  # nunca hace falta pedirla explícita, ya viene resuelta de la sesión).
  defp validar_campo_en_attrs(schema_mod, attrs, campo, permitidos) do
    campo_atom = String.to_existing_atom(campo)

    if campo_atom in schema_mod.__schema__(:fields) do
      case Map.get(attrs, campo) || Map.get(attrs, campo_atom) do
        nil -> :ok
        valor -> if normalizar_id(valor) in permitidos, do: :ok, else: {:error, campo}
      end
    else
      :ok
    end
  end

  # Fase 5 de jerarquía operativa (2026-08-11) -- a diferencia de
  # validar_campo_en_attrs/4 de arriba, ACÁ un valor faltante SÍ bloquea:
  # branch_id/sales_unit_id/inventory_id ya se intentaron autocompletar
  # con el activo del scope (estampar_jerarquia_activa_en_attrs/3, corre
  # ANTES en preparar_attrs_alcance/4) -- si DESPUÉS de eso attrs sigue
  # sin valor, es porque el usuario tampoco tiene una sucursal/almacén/
  # unidad de venta activa elegida, y el catálogo de verdad necesita esa
  # dimensión para filtrar. Crear el registro igual, con la columna en
  # NULL (visible para cualquiera bajo la regla NULL-permisiva de Fase
  # 6b), sería más sorpresa silenciosa -- decisión de producto confirmada:
  # bloquear con un error claro y procesable en su lugar.
  defp validar_campo_requerido_en_attrs(schema_mod, attrs, campo, permitidos) do
    campo_atom = String.to_existing_atom(campo)

    if campo_atom in schema_mod.__schema__(:fields) do
      case Map.get(attrs, campo) || Map.get(attrs, campo_atom) do
        nil -> {:error, {:alcance_requerido, campo}}
        valor -> if normalizar_id(valor) in permitidos, do: :ok, else: {:error, campo}
      end
    else
      :ok
    end
  end

  defp normalizar_id(id) when is_binary(id), do: String.to_integer(id)
  defp normalizar_id(id), do: id

  # Hallazgo de Fase 9 (2026-08-11, validación end-to-end contra un
  # catálogo REAL, no el fixture de test): branch_id/sales_unit_id/
  # inventory_id/creado_por_id están deliberadamente fuera de `@campos`
  # en MetaCatalogoGenerico (mismo criterio que estado_id/encabezado_id/
  # renglon_id) -- eso significa que `cast(attrs, @campos)` los DESCARTA
  # en silencio para cualquier catálogo generado de verdad. validar_campo_en_attrs/4
  # ya valida el VALOR que viene en `attrs` contra el scope, pero sin esto
  # ese valor nunca llegaba a persistirse -- quedaba NULL para siempre
  # aunque la validación hubiera pasado. `MetaFixtureAlcance` (el fixture
  # de Fase 4a/4b) no tenía este problema porque su changeset -- escrito a
  # mano, sin pasar por el macro -- SÍ castea estos campos directo; por
  # eso el gap sobrevivió sin que ningún test lo agarrara hasta Fase 9.
  # Mismo mecanismo que asignar_estado_inicial/2: put_change directo
  # sobre el changeset YA construido, nunca vía cast. No-op si la columna
  # no existe (con_columna-style) o si `attrs` no trae ese campo.
  # `campos_permitidos` es explícito por call site a propósito:
  # creado_por_id SOLO se estampa al crear (crear_simple/3) -- si
  # actualizar_directo/5 lo incluyera acá, un PUT/PATCH que por descuido
  # (o a propósito) traiga "creado_por_id" en el body podría pisar el
  # autor real, exactamente el tampering que cast(attrs, @campos) ya
  # bloqueaba antes de este fix. branch_id/sales_unit_id/inventory_id SÍ
  # son editables en ambos casos (ver Fase 4b: "permite cambiar branch_id
  # a otro valor SÍ permitido").
  defp aplicar_campos_alcance_en_changeset(changeset, schema_mod, attrs, campos_permitidos) do
    campos_schema = schema_mod.__schema__(:fields)

    Enum.reduce(campos_permitidos, changeset, fn campo, cs ->
      if campo in campos_schema do
        case Map.get(attrs, Atom.to_string(campo)) || Map.get(attrs, campo) do
          nil -> cs
          valor -> Ecto.Changeset.put_change(cs, campo, normalizar_id(valor))
        end
      else
        cs
      end
    end)
  end

  # Hallazgo real (2026-08-11, catálogo pty_dsd_empleados_funcion en uso):
  # un catálogo que adoptó el motor de estados (define transición "alta")
  # crea sus registros vía MetaStateEngine.dar_de_alta/5, que arma su
  # propio changeset (construir_changeset_valido/2, en meta_state_engine.ex)
  # sin pasar por aplicar_campos_alcance_en_changeset/4 -- ese módulo se
  # dejó deliberadamente sin tocar (agnóstico del catálogo, mismo criterio
  # ya documentado arriba para TRN.asignar_si_transaccional/1), así que
  # branch_id/sales_unit_id/inventory_id/creado_por_id (ya presentes en
  # `attrs` gracias a preparar_attrs_con_alcance/3, que corre ANTES de
  # bifurcar a crear_simple/dar_de_alta) quedaban NULL para siempre en
  # cada alta, sin ningún error visible -- exactamente el mismo bug que
  # crear_simple/3 tenía antes de la Fase 9, pero en el otro camino de
  # creación. Mismo patrón que TRN: paso separado DESPUÉS del insert, no
  # acopla MetaStateEngine a este concepto de negocio.
  defp estampar_campos_alcance_post_insert({:error, _} = error, _schema_mod, _attrs), do: error

  defp estampar_campos_alcance_post_insert({:ok, registro}, schema_mod, attrs) do
    changeset =
      registro
      |> Ecto.Changeset.change()
      |> aplicar_campos_alcance_en_changeset(schema_mod, attrs, [:branch_id, :sales_unit_id, :inventory_id, :creado_por_id])

    if changeset.changes == %{}, do: {:ok, registro}, else: Repo.update(changeset)
  end

  # Auditoría de DATOS (roadmap #6) — mismo criterio de "corre DESPUÉS,
  # como paso separado" que TRN.asignar_si_transaccional/1 de arriba: no
  # queda anidado en la misma transacción SQL que crear_simple/3 (ni la
  # de dar_de_alta/5, que vive en MetaStateEngine) — aceptable porque ya
  # es exactamente el mismo nivel de no-atomicidad que TRN acepta hoy
  # para el mismo insert, no una garantía nueva que se está bajando.
  defp auditar_alta({:ok, registro} = resultado, catalogo, contexto) do
    MetadataApp.MetaAuditoria.registrar(
      catalogo,
      "alta",
      registro.insert_guid,
      registro,
      %{"despues" => serializar(registro)},
      contexto
    )

    resultado
  end

  defp auditar_alta(error, _catalogo, _contexto), do: error

  # Envuelto en Repo.transaction/1 (aunque un solo Repo.insert/1 ya sería
  # atómico por sí mismo) porque MetadataApp.Renglones.preparar/3 puede
  # necesitar un SELECT ... FOR UPDATE previo sobre la fila del maestro
  # (catálogos detalle) que tiene que quedar en la MISMA transacción que el
  # insert final — para un catálogo que no es detalle, es un no-op extra
  # sin costo real. Devuelve el mismo shape de siempre ({:ok, registro} |
  # {:error, changeset}), Repo.transaction/1 solo envuelve, no lo cambia.
  # `renglones_spec` (Fase 6, R6): después del insert, crea los renglones
  # iniciales de ESTE registro (si tiene catálogos detalle) — mismo
  # aplanado de transacción anidada que ya describe el moduledoc de
  # `MetadataApp.Renglones`.
  defp crear_simple(schema_mod, attrs, renglones_spec) do
    catalogo = schema_mod.__schema__(:source)
    estado_inicial = MetadataApp.MetaStateEngine.estado_inicial(catalogo)

    Repo.transaction(fn ->
      resultado =
        schema_mod
        |> struct()
        |> schema_mod.changeset(attrs)
        |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
        |> asignar_estado_inicial(estado_inicial)
        |> aplicar_campos_alcance_en_changeset(schema_mod, attrs, [:branch_id, :sales_unit_id, :inventory_id, :creado_por_id])
        |> MetadataApp.Renglones.preparar(catalogo, attrs)
        |> Repo.insert()

      case resultado do
        {:ok, registro} ->
          case MetadataApp.Renglones.crear_todos(catalogo, registro.id, renglones_spec) do
            {:ok, _renglones} -> registro
            {:error, motivo} -> Repo.rollback(motivo)
          end

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  # Si el catálogo adoptó el motor de estados, todo registro nuevo nace en
  # su estado inicial — si no, no hay nada que asignar (estado_id queda nil,
  # como siempre para catálogos sin motor de estados).
  defp asignar_estado_inicial(changeset, nil), do: changeset

  defp asignar_estado_inicial(changeset, estado_inicial),
    do: Ecto.Changeset.change(changeset, %{estado_id: estado_inicial.id})

  # Crea varios registros del mismo catálogo en una sola transacción.
  # Si alguno falla, se revierten todos (todo o nada). Cada item puede
  # traer su propia "renglones" (R6) — un lote de maestros, cada uno con
  # sus propios renglones iniciales.
  @spec crear_muchos(module(), Scope.t_ou_sistema(), [map()], map()) :: {:ok, [struct()]} | {:error, term()}
  def crear_muchos(schema_mod, scope, lista_attrs, contexto \\ %{}) when is_list(lista_attrs) do
    Repo.transaction(fn ->
      Enum.map(lista_attrs, fn item ->
        {renglones, attrs} = Map.pop(item, "renglones", %{})

        case crear(schema_mod, scope, attrs, renglones: renglones, contexto: contexto) do
          {:ok, registro} -> registro
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  # Si el catálogo definió una transición "guardar" (self-loop en el estado
  # actual, ver MetaStateEngine.transicion_guardar/2), la edición corre el
  # mismo ciclo de reglas pre/post que cualquier transición — las PRE ven
  # los valores YA PROPUESTOS (permite bloquear "no puede llamarse X" en el
  # momento de guardar, no después), y las POST pueden reaccionar al
  # cambio. Si el catálogo nunca definió esa transición, sigue el update
  # directo de siempre — 100% retrocompatible.
  #
  # CompliancePty (docs/compliance-pty.md, C6): un catálogo detalle NUNCA
  # acepta PUT/PATCH directo — bug real encontrado en producción antes de
  # esta guarda: campos_editables/2 mira SI EL CATÁLOGO adoptó el motor
  # consultando SUS PROPIOS meta_schema_estados, que un catálogo detalle
  # nunca tiene (viven en el maestro, R3) — así que lo trataba como "sin
  # motor" y dejaba editar CUALQUIER campo sin pasar por ninguna
  # transición, sin campos_editables, sin evento de auditoría. La única
  # forma de tocar un campo de un renglón es una transición del maestro
  # con "renglones" (R4) — mismo criterio que ya usa eliminar/1 para
  # bloquear el DELETE de un renglón (R12).
  # `scope` (Fase 4b) posicional, sin default -- mismo criterio que
  # crear/4. Acá SÍ hay changeset antes de bifurcar (ver
  # actualizar_directo/5), así que la validación de alcance corre sobre
  # el changeset real, no sobre `attrs` crudo como en crear/4.
  @spec actualizar(struct(), Scope.t_ou_sistema(), map(), map()) :: {:ok, struct()} | {:error, %Ecto.Changeset{} | String.t()}
  def actualizar(registro, scope, attrs, contexto \\ %{}) do
    schema_mod = registro.__struct__
    catalogo = schema_mod.__schema__(:source)
    header = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.obtener_header_por_nombre(catalogo)

    if header && header.schema_encabezado_id do
      {:error,
       "los campos de un renglón de un catálogo detalle no se editan por PUT/PATCH directo — use una transición del maestro con \"renglones\""}
    else
      antes = serializar(registro)

      # Mismo lookup que actualizar_directo/5 hace por su cuenta para
      # decidir el ciclo de reglas — repetirlo acá (barato, un SELECT) es
      # más simple que cambiar el contrato de retorno de esa función solo
      # para poder etiquetar la auditoría con el nombre de la transición.
      operacion =
        case MetadataApp.MetaStateEngine.transicion_guardar(catalogo, registro.estado_id) do
          nil -> "edicion"
          transicion -> "transicion:#{transicion.accion}"
        end

      registro
      |> actualizar_directo(scope, attrs, schema_mod, catalogo)
      |> auditar_edicion(catalogo, operacion, antes, contexto)
    end
  end

  defp auditar_edicion({:ok, registro} = resultado, catalogo, operacion, antes, contexto) do
    MetadataApp.MetaAuditoria.registrar(
      catalogo,
      operacion,
      registro.update_guid,
      registro,
      %{"antes" => antes, "despues" => serializar(registro)},
      contexto
    )

    resultado
  end

  defp auditar_edicion(error, _catalogo, _operacion, _antes, _contexto), do: error

  defp actualizar_directo(registro, scope, attrs, schema_mod, catalogo) do
    transicion = MetadataApp.MetaStateEngine.transicion_guardar(catalogo, registro.estado_id)

    detalles = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.listar_detalles(catalogo)
    todos_los_campos = Enum.map(detalles, & &1.schema_context_field)

    # La propiedad "editable" del contrato (fija, por campo) manda además
    # de — no en vez de — la whitelist que arma el motor de estados: un
    # campo solo se puede tocar si pasa las dos restricciones.
    campos_editables_contrato =
      detalles
      |> Enum.filter(&(&1.schema_context_properties["editable"] == true))
      |> Enum.map(& &1.schema_context_field)

    editables =
      catalogo
      |> MetadataApp.MetaStateEngine.campos_editables(transicion)
      |> Enum.filter(&(&1 in campos_editables_contrato))

    changeset =
      registro
      |> schema_mod.changeset(attrs)
      |> rechazar_no_editables(attrs, todos_los_campos, editables)
      |> Ecto.Changeset.change(%{update_guid: generar_guid()})
      |> aplicar_campos_alcance_en_changeset(schema_mod, attrs, [:branch_id, :sales_unit_id, :inventory_id])
      |> validar_alcance_en_changeset(scope, schema_mod)

    if changeset.valid? do
      case transicion do
        nil -> Repo.update(changeset)
        transicion -> MetadataApp.MetaStateEngine.editar_con_transicion(changeset, transicion, attrs)
      end
    else
      {:error, changeset}
    end
  end

  # Rechaza explícitamente (error visible en el changeset, no ignorado en
  # silencio) cualquier intento de tocar un campo que no esté en la
  # whitelist de editables para el estado actual del registro. `estado_id`
  # y `trn`/`ulid` se protegen aparte porque no son campos "de negocio"
  # (no viven en meta_schema_detail, así que nunca aparecen en
  # `todos_los_campos`) — el único camino para cambiarlos es
  # `MetaStateEngine.ejecutar_transicion/3` y `MetadataApp.TRN`
  # respectivamente, nunca un PATCH.
  defp rechazar_no_editables(changeset, attrs, todos_los_campos, editables) do
    editables_set = MapSet.new(editables)
    protegidos = ["estado_id", "trn", "ulid" | todos_los_campos]

    attrs
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in protegidos and &1 not in editables_set))
    |> Enum.reduce(changeset, fn campo, cs ->
      Ecto.Changeset.add_error(
        cs,
        String.to_existing_atom(campo),
        "no editable en el estado actual"
      )
    end)
  end

  # Alcance de Datos en escritura, lado UPDATE (Fase 4b) — a diferencia
  # del lado CREATE (preparar_attrs_con_alcance/3, sobre `attrs` crudo),
  # acá ya hay un changeset real armado (actualizar_directo/5), así que se
  # valida contra Ecto.Changeset.get_change/2 (NO get_field/2, ver la nota
  # en validar_campo_en_changeset/4 más abajo) -- si el campo no viene en
  # ESTA edición puntual, no hay nada que validar, nunca rechaza una
  # edición que no toca la dimensión de alcance.
  defp validar_alcance_en_changeset(changeset, scope, schema_mod) do
    catalogo = schema_mod.__schema__(:source)

    case MetaSchemaContext.obtener_header_por_nombre(catalogo) do
      %{alcance_habilitado: true} = header -> validar_tipo_en_changeset(changeset, scope, schema_mod, header)
      _ -> changeset
    end
  end

  defp validar_tipo_en_changeset(changeset, :sistema, _schema_mod, _header), do: changeset

  defp validar_tipo_en_changeset(changeset, nil, _schema_mod, _header),
    do: Ecto.Changeset.add_error(changeset, :base, "no autenticado")

  defp validar_tipo_en_changeset(changeset, %Scope{} = scope, schema_mod, header) do
    scope
    |> Permissions.alcance_tipo_efectivo(header.id)
    |> aplicar_validacion_de_tipo(changeset, scope, schema_mod)
  end

  defp aplicar_validacion_de_tipo(:global, changeset, _scope, _schema_mod), do: changeset
  defp aplicar_validacion_de_tipo(:propio, changeset, _scope, _schema_mod), do: changeset

  defp aplicar_validacion_de_tipo(:empresa, changeset, scope, schema_mod),
    do: validar_campo_en_changeset(changeset, schema_mod, :empresa_id, [scope.empresa_activa.id])

  defp aplicar_validacion_de_tipo(:branch, changeset, scope, schema_mod),
    do: validar_campo_en_changeset(changeset, schema_mod, :branch_id, scope.branches_permitidos)

  defp aplicar_validacion_de_tipo(:sales_unit, changeset, scope, schema_mod),
    do: validar_campo_en_changeset(changeset, schema_mod, :sales_unit_id, scope.sales_units_permitidas)

  defp aplicar_validacion_de_tipo(:inventory_location, changeset, scope, schema_mod),
    do: validar_campo_en_changeset(changeset, schema_mod, :inventory_id, scope.inventory_locations_permitidas)

  # get_change/2 (NO get_field/2) a propósito: get_field/2 devuelve el
  # valor YA PERSISTIDO cuando el campo no viene en esta edición, así que
  # con get_field/2 CUALQUIER registro cuya dimensión de alcance haya
  # quedado desactualizada (ej. reasignaron branches) sería imposible de
  # editar en NINGÚN campo, ni uno sin relación -- encontrado real
  # escribiendo el test "editar un campo que no es la dimensión de
  # alcance". get_change/2 solo mira lo que este PATCH/PUT puntual
  # intenta cambiar.
  defp validar_campo_en_changeset(changeset, schema_mod, campo, permitidos) do
    if campo in schema_mod.__schema__(:fields) do
      case Ecto.Changeset.get_change(changeset, campo) do
        nil -> changeset
        valor -> if valor in permitidos, do: changeset, else: Ecto.Changeset.add_error(changeset, campo, "fuera de tu alcance permitido")
      end
    else
      changeset
    end
  end

  # R12 del Maestro-Detalle: un renglón de un catálogo detalle nunca se
  # borra (ni soft-delete) — el único camino para "sacarlo" es una
  # transición del autómata a un estado tipo Cancelado. `header` se
  # resuelve por nombre de tabla (mismo patrón que MetadataApp.TRN), no
  # por una función exportada por el schema — evita otro mecanismo de
  # "preguntarle al módulo" aparte del que ya existe.
  def eliminar(registro, contexto \\ %{}) do
    catalogo = registro.__struct__.__schema__(:source)
    header = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.obtener_header_por_nombre(catalogo)

    if header && header.schema_encabezado_id do
      {:error,
       "los renglones de un catálogo detalle no se borran — use una transición del autómata para pasarlo a un estado tipo \"Cancelado\""}
    else
      antes = serializar(registro)

      registro
      |> Ecto.Changeset.change(%{delete_guid: generar_guid()})
      |> Repo.update()
      |> auditar_baja(catalogo, antes, contexto)
    end
  end

  defp auditar_baja({:ok, registro} = resultado, catalogo, antes, contexto) do
    MetadataApp.MetaAuditoria.registrar(catalogo, "baja", registro.delete_guid, registro, %{"antes" => antes}, contexto)
    resultado
  end

  defp auditar_baja(error, _catalogo, _antes, _contexto), do: error

  # estados_por_id: %{estado_id => nombre} (ver MetaStateEngine.mapa_nombres_estados/1)
  # — opcional para no romper otros llamadores; sin él, o si el registro no
  # tiene estado_id asignado, no agrega estado_nombre.
  #
  # acompanamiento: %{campo => %{id_referenciado => %{...}}} (ver
  # mapa_acompanamiento/2) — opcional, mismo motivo. Reemplaza el id crudo
  # de un campo tipo "referencia" por el objeto resuelto, ej.
  # %{cliente_ecc: 1} -> %{cliente_ecc: %{id: 1, razon_social: "..."}}.
  def serializar(registro, estados_por_id \\ %{}, acompanamiento \\ %{}) do
    registro
    |> Map.from_struct()
    |> Map.drop([:__meta__, :insert_guid, :update_guid, :delete_guid])
    |> agregar_estado_nombre(estados_por_id)
    |> agregar_acompanamiento(acompanamiento)
  end

  # Arma, para cada campo tipo "referencia" con "campo_visualizacion" o
  # "campos_acompanamiento" configurado, un mapa %{id_referenciado =>
  # etiqueta} usando SOLO los ids que de verdad aparecen en `filas` — una
  # query batch por relación por página de resultados, nunca una query
  # por fila (mismo espíritu que MetaStateEngine.mapa_nombres_estados/1
  # para estado_nombre). La etiqueta se arma con etiqueta_para_referencia/2
  # — la misma función que ya usa opciones_referencia/1 para el picker de
  # FichaLive — para que la tabla y el formulario muestren siempre lo
  # mismo, sin un segundo mecanismo que se pueda desincronizar del
  # primero (bug real: acá solo se chequeaba campos_acompanamiento, así
  # que un campo configurado con el modo nuevo campo_visualizacion
  # quedaba mostrando el id crudo solo en la tabla).
  def mapa_acompanamiento(catalogo, filas) do
    catalogo
    |> MetadataApp.BusinessProcessBuilder.MetaSchemaContext.listar_detalles()
    |> Enum.filter(&campo_con_acompanamiento?/1)
    |> Map.new(fn detalle ->
      campo = String.to_existing_atom(detalle.schema_context_field)
      props = detalle.schema_context_properties
      modulo_destino = MetadataApp.BusinessProcessBuilder.MetaSchemaContext.modulo_por_nombre(props["catalogo"])

      ids =
        filas
        |> Enum.map(&Map.get(&1, campo))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      {campo, resolver_acompanamiento(modulo_destino, ids, props)}
    end)
  end

  defp campo_con_acompanamiento?(detalle) do
    props = detalle.schema_context_properties || %{}

    props["tipo"] == "referencia" and
      ((is_map(props["campo_visualizacion"]) and props["campo_visualizacion"] != %{}) or
         (is_list(props["campos_acompanamiento"]) and props["campos_acompanamiento"] != []))
  end

  # Opciones para el <select> de un campo tipo "referencia" en
  # CampoInputComponents.campo_input/1 (picker simple, sin búsqueda) — TODOS
  # los registros del catálogo destino, con la etiqueta armada por
  # etiqueta_para_referencia/2: prioriza "campo_visualizacion" (BcMotorLive →
  # Relaciones → Configuración de visualización) si está configurado, y si
  # no cae al join de "campos_acompanamiento" de siempre (retrocompatible,
  # sin migración de datos — ver validar_campo_visualizacion/1 en
  # MetaSchemaContext). Tope de 500 registros a propósito: un <select> con
  # más opciones que eso deja de ser usable de todos modos (búsqueda con
  # filtro real es Fase 2, ver docs/roadmap-campos-acompanamiento.md).
  def opciones_referencia(props), do: opciones_referencia(props, %{})

  @doc """
  Igual que `opciones_referencia/1` pero acotando el catálogo destino con
  `filtros` (mismo mapa que `listar/4` — ver `aplicar_filtros/2`) antes de
  traer las filas — usado por un campo "referencia" con "dependencias"
  configuradas (ver `MetaSchemaContext.resolver_filtros/3`) para traer
  SOLO las opciones válidas para el valor actual de su campo padre, en vez
  del catálogo destino entero.
  """
  def opciones_referencia(props, filtros) do
    case MetadataApp.BusinessProcessBuilder.MetaSchemaContext.modulo_por_nombre(props["catalogo"]) do
      nil ->
        []

      modulo ->
        # :sistema (Fase 4a del modelo de Alcance de Datos) -- llamado
        # desde componentes de función (campo_input/1 y afines) sin acceso
        # directo al Scope del socket. Filtrar las opciones de un picker
        # "referencia" por el alcance del usuario es una mejora real
        # pendiente (hoy siempre ve el catálogo destino entero), marcada a
        # propósito para no threadear Scope por todo el árbol de
        # componentes en esta fase.
        modulo |> listar(:sistema, filtros, limit: 500) |> Enum.map(&{&1.id, etiqueta_para_referencia(&1, props)})
    end
  end

  @doc "Pública para la vista previa en vivo del panel de Relaciones (BcMotorLive)."
  def etiqueta_para_referencia(registro, %{"campo_visualizacion" => %{} = config}), do: etiqueta_con_visualizacion(registro, config)
  def etiqueta_para_referencia(registro, props), do: etiqueta_opcion_referencia(registro, props["campos_acompanamiento"])

  defp etiqueta_con_visualizacion(registro, %{"modo" => "descripcion", "campo_descripcion" => campo}) do
    valor_campo(registro, campo) || "##{registro.id}"
  end

  defp etiqueta_con_visualizacion(registro, %{"modo" => "codigo_descripcion"} = config) do
    [valor_campo(registro, config["campo_codigo"]), valor_campo(registro, config["campo_descripcion"])]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "##{registro.id}"
      partes -> Enum.join(partes, " - ")
    end
  end

  defp etiqueta_con_visualizacion(registro, %{"modo" => "plantilla", "plantilla" => plantilla}) when is_binary(plantilla) do
    sustituir_variables(plantilla, registro)
  end

  defp etiqueta_con_visualizacion(registro, %{"modo" => "calculado", "formula" => formula}) when is_binary(formula) do
    valores = registro |> Map.from_struct() |> Map.new(fn {campo, valor} -> {Atom.to_string(campo), valor} end)

    case MetadataApp.MetaPlantillas.Formula.evaluar(formula, valores) do
      {:ok, resultado} -> to_string(resultado)
      {:error, _motivo} -> "##{registro.id}"
    end
  end

  defp etiqueta_con_visualizacion(registro, _config), do: "##{registro.id}"

  defp valor_campo(_registro, nil), do: nil

  defp valor_campo(registro, campo) do
    case Map.get(registro, safe_atom(campo)) do
      valor when valor in [nil, ""] -> nil
      valor -> to_string(valor)
    end
  end

  # "{campo}" -> el valor real de esa columna en `registro`; cualquier otra
  # cosa (texto literal entre las llaves, un typo) se deja intacta —
  # validar_campo_visualizacion/1 ya impide guardar una plantilla con
  # variables que no existen, esto es la segunda capa de defensa en tiempo
  # de lectura (fail-open, nunca rompe el picker por una config vieja).
  @doc "Pública para Integraciones.ejecutar/4 (Fase 4, 2026-08-07) — mismo templating \"{campo}\" para url/headers/body de una acción externa, sin reinventar el reemplazo acá."
  def sustituir_variables(plantilla, registro) do
    Regex.replace(~r/\{(\w+)\}/, plantilla, fn original, campo ->
      valor_campo(registro, campo) || original
    end)
  end

  defp safe_atom(campo) do
    String.to_existing_atom(campo)
  rescue
    ArgumentError -> nil
  end

  defp etiqueta_opcion_referencia(registro, campos) when is_list(campos) and campos != [] do
    campos
    |> Enum.map(&Map.get(registro, String.to_existing_atom(&1)))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> "##{registro.id}"
      valores -> Enum.map_join(valores, " · ", &to_string/1)
    end
  end

  defp etiqueta_opcion_referencia(registro, _campos), do: "##{registro.id}"

  defp resolver_acompanamiento(nil, _ids, _props), do: %{}
  defp resolver_acompanamiento(_modulo, [], _props), do: %{}

  # Trae la fila completa (no un `select: map(...)` acotado a
  # campos_acompanamiento) porque etiqueta_para_referencia/2 con
  # campo_visualizacion modo "calculado"/"plantilla" puede referenciar
  # cualquier campo del registro, no solo los de una lista fija conocida
  # de antemano.
  defp resolver_acompanamiento(modulo, ids, props) do
    from(t in modulo, where: t.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, etiqueta_para_referencia(&1, props)})
  end

  defp agregar_acompanamiento(mapa, acompanamiento) when acompanamiento == %{}, do: mapa

  defp agregar_acompanamiento(mapa, acompanamiento) do
    Enum.reduce(acompanamiento, mapa, fn {campo, resueltos}, acc ->
      case Map.get(acc, campo) do
        nil -> acc
        id -> Map.put(acc, campo, Map.get(resueltos, id))
      end
    end)
  end

  # Reordena el mapa de serializar/2 para que el TRN quede siempre al final,
  # después del estado. Aparte de serializar/2 (que otros módulos internos
  # como CatalogoLive siguen usando como mapa plano) porque esto devuelve un
  # Jason.OrderedObject — solo debe usarse justo antes de json/2 en los
  # controllers, no como resultado de uso interno.
  def trn_al_final(mapa) do
    case Map.pop(mapa, :trn) do
      {nil, _mapa} -> mapa
      {trn, resto} -> Jason.OrderedObject.new(Map.to_list(resto) ++ [trn: trn])
    end
  end

  defp agregar_estado_nombre(%{estado_id: nil} = mapa, _estados_por_id), do: mapa

  defp agregar_estado_nombre(%{estado_id: estado_id} = mapa, estados_por_id) do
    Map.put(mapa, :estado_nombre, Map.get(estados_por_id, estado_id))
  end

  defp agregar_estado_nombre(mapa, _estados_por_id), do: mapa

  # Valida que el valor de `campo` no exista ya como `campo_externo` en
  # `tabla_externa` (unicidad cross-catálogo). `tabla_externa` es un nombre de
  # tabla, no un módulo — se consulta sin schema Ecto compilado.
  def validar_unico_en(changeset, campo, tabla_externa, campo_externo) do
    case Ecto.Changeset.get_change(changeset, campo) do
      nil ->
        changeset

      valor ->
        campo_externo_atom = String.to_existing_atom(campo_externo)

        existe? =
          Repo.exists?(
            from t in tabla_externa,
              where: field(t, ^campo_externo_atom) == ^valor,
              where: is_nil(field(t, :delete_guid))
          )

        if existe? do
          Ecto.Changeset.add_error(changeset, campo, "ya existe en #{tabla_externa}")
        else
          changeset
        end
    end
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
