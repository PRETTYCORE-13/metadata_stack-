defmodule MetadataApp.Adn.ConfigSalesUnit do
  @moduledoc """
  SPEC-ADN-2209202601 — Configuración de Sales Unit (app móvil).

  Punto único para escribir un valor de Perfil/Excepción. Existe
  porque un catálogo detalle (`pty_config_perfilesdet` y las dos
  `..._exc`) nunca corre reglas PRE al insertar un renglón nuevo —
  hallazgo real de esta spec, ver `02.design.md` §5.1/§5.2: las PRE
  solo corren cuando un renglón YA EXISTENTE se edita vía la
  transición del maestro, nunca al crearlo. La unicidad (R6/R12/R14)
  sí queda cubierta siempre, vía índice único real de Postgres
  (`20260922233000_indice_unico_parametro_por_perfil.exs` y
  equivalentes) — acá solo hace falta traducir la excepción de
  constraint a un error legible. La validación de tipo (R7/R15) SOLO
  se aplica si se entra por acá — insertar un renglón directo contra
  la API genérica del catálogo la saltea (límite conocido, documentado
  en el diseño).
  """

  alias MetadataApp.BusinessProcessBuilder.{CatalogoGenerico, MetaSchemaContext}

  @doc "R8: si un Perfil tiene un valor cargado para cada Parámetro Base vivo, y cuáles le faltan."
  @spec completitud_perfil(integer()) :: %{completo?: boolean(), faltantes: [integer()]}
  def completitud_perfil(perfil_id) do
    modulo_parametros = MetaSchemaContext.modulo_por_nombre("pty_config")
    modulo_valores = MetaSchemaContext.modulo_por_nombre("pty_config_perfilesdet")

    # "vivo" acá es estado Activo, no solo delete_guid -- listar/2 SOLO
    # filtra delete_guid (verificado real: un parámetro "dado de baja"
    # por el autómata sigue con delete_guid nil, nunca se soft-elimina,
    # solo cambia estado_id). Sin este filtro extra, un parámetro de
    # baja seguía exigiéndose en la completitud, violando R3.
    activo_id = MetadataApp.MetaStateEngine.estado_inicial("pty_config").id
    vivos = modulo_parametros |> CatalogoGenerico.listar(:sistema, %{"estado_id" => activo_id}) |> MapSet.new(& &1.id)

    cargados =
      modulo_valores
      |> CatalogoGenerico.listar(:sistema, %{"encabezado_id" => perfil_id})
      |> MapSet.new(& &1.pty_config_perfilesdet_parametro)

    faltantes = MapSet.difference(vivos, cargados)
    %{completo?: MapSet.size(faltantes) == 0, faltantes: MapSet.to_list(faltantes)}
  end

  @doc "Agrega (o falla) un valor de parámetro dentro de un Perfil de Configuración."
  @spec agregar_valor_perfil(integer(), integer(), String.t()) :: {:ok, struct()} | {:error, String.t()}
  def agregar_valor_perfil(perfil_id, parametro_id, valor) do
    escribir_valor("pty_config_perfilesdet", "pty_config_perfilesdet_parametro", "pty_config_perfilesdet_parametro_valor", perfil_id, parametro_id, valor)
  end

  @doc "Agrega (o falla) una Excepción de parámetro para una Sales Unit Config (eje Ventas)."
  @spec agregar_excepcion_ventas(integer(), integer(), String.t()) :: {:ok, struct()} | {:error, String.t()}
  def agregar_excepcion_ventas(sales_unit_config_id, parametro_id, valor) do
    escribir_valor(
      "pty_config_perfiles_salesu_exc",
      "pty_config_perfiles_salesu_exc_parametro",
      "pty_config_perfiles_salesu_exc_parametro_valor",
      sales_unit_config_id,
      parametro_id,
      valor
    )
  end

  @doc "Agrega (o falla) una Excepción de parámetro para un Inventory Location Config (eje Reparto)."
  @spec agregar_excepcion_reparto(integer(), integer(), String.t()) :: {:ok, struct()} | {:error, String.t()}
  def agregar_excepcion_reparto(invlocation_config_id, parametro_id, valor) do
    escribir_valor(
      "pty_config_perfiles_invlocation_exc",
      "pty_config_perfiles_invlocation_exc_parametro",
      "pty_config_perfiles_invlocation_exc_parametro_valor",
      invlocation_config_id,
      parametro_id,
      valor
    )
  end

  defp escribir_valor(catalogo_detalle, campo_parametro, campo_valor, encabezado_id, parametro_id, valor) do
    with {:ok, parametro} <- obtener_parametro(parametro_id),
         :ok <- validar_tipo(valor, parametro.pty_config_parametro_tipo, parametro.pty_config_parametro) do
      insertar(catalogo_detalle, campo_parametro, campo_valor, encabezado_id, parametro_id, valor)
    end
  end

  defp obtener_parametro(parametro_id) do
    modulo = MetaSchemaContext.modulo_por_nombre("pty_config")

    try do
      {:ok, CatalogoGenerico.obtener!(modulo, :sistema, parametro_id)}
    rescue
      Ecto.NoResultsError -> {:error, "el parámetro referenciado no existe"}
    end
  end

  defp validar_tipo(valor, "boolean", _codigo) when valor in ["true", "false"], do: :ok
  defp validar_tipo(valor, "integer", _codigo) do
    if match?({_n, ""}, Integer.parse(valor)), do: :ok, else: {:error, "\"#{valor}\" no es un entero válido"}
  end

  defp validar_tipo(valor, "decimal", _codigo) do
    if match?({_n, ""}, Decimal.parse(valor)), do: :ok, else: {:error, "\"#{valor}\" no es un decimal válido"}
  end

  defp validar_tipo(_valor, tipo, _codigo) when tipo in ["string", "enum"], do: :ok

  defp validar_tipo(valor, tipo, codigo),
    do: {:error, "\"#{valor}\" no es válido para el tipo \"#{tipo}\" del parámetro \"#{codigo}\""}

  # Pre-chequeo de unicidad ANTES de insertar (no solo confiar en el
  # índice de la migración de R6): una violación de constraint real
  # deja la transacción Postgres envolvente "abortada" para cualquier
  # query siguiente salvo que el insert use `mode: :savepoint` --
  # CatalogoGenerico.crear/4 no expone esa opción (es la función
  # genérica compartida por todo el motor, no se toca para esto). El
  # índice de la migración queda como red de seguridad real ante una
  # carrera (dos requests simultáneos) — ese caso sí puede poisonear la
  # transacción del caller, aceptado como límite conocido y de
  # probabilidad baja, no resuelto acá.
  defp insertar(catalogo_detalle, campo_parametro, campo_valor, encabezado_id, parametro_id, valor) do
    modulo = MetaSchemaContext.modulo_por_nombre(catalogo_detalle)

    if ya_existe?(modulo, campo_parametro, encabezado_id, parametro_id) do
      {:error, "este Perfil/Sales Unit ya tiene un valor cargado para ese parámetro"}
    else
      attrs = %{"encabezado_id" => encabezado_id, campo_parametro => parametro_id, campo_valor => valor}

      case CatalogoGenerico.crear(modulo, :sistema, attrs) do
        {:ok, registro} -> {:ok, registro}
        {:error, _changeset} -> {:error, "no se pudo guardar el valor"}
      end
    end
  end

  defp ya_existe?(modulo, campo_parametro, encabezado_id, parametro_id) do
    modulo
    |> CatalogoGenerico.listar(:sistema, %{"encabezado_id" => encabezado_id, campo_parametro => parametro_id})
    |> Enum.any?()
  end

  # --- R16-R18: configuración efectiva ---------------------------------

  @doc "R16-R18: config efectiva (Excepción → Perfil → default) para una Sales Unit, eje Ventas."
  @spec efectiva_ventas(integer()) :: %{String.t() => term()}
  def efectiva_ventas(sales_unit_id) do
    resolver_efectiva(
      "pty_config_perfiles_salesu",
      "pty_config_perfiles_salesu_sales_unit",
      "pty_config_perfiles_salesu_perfil",
      "pty_config_perfiles_salesu_exc",
      "pty_config_perfiles_salesu_exc_parametro",
      "pty_config_perfiles_salesu_exc_parametro_valor",
      sales_unit_id
    )
  end

  @doc "R16-R18: config efectiva (Excepción → Perfil → default) para un Almacén, eje Reparto."
  @spec efectiva_reparto(integer()) :: %{String.t() => term()}
  def efectiva_reparto(inventory_location_id) do
    resolver_efectiva(
      "pty_config_perfiles_invlocation",
      "pty_config_perfiles_invlocation_inventory_location",
      "pty_config_perfiles_invlocation_perfil",
      "pty_config_perfiles_invlocation_exc",
      "pty_config_perfiles_invlocation_exc_parametro",
      "pty_config_perfiles_invlocation_exc_parametro_valor",
      inventory_location_id
    )
  end

  defp resolver_efectiva(catalogo_maestro, campo_entidad, campo_perfil, catalogo_exc, campo_exc_parametro, campo_exc_valor, entidad_id) do
    parametros = parametros_base_vivos()

    case buscar_asignacion_viva(catalogo_maestro, campo_entidad, entidad_id) do
      # R17: sin asignación -- responde igual, puros defaults.
      nil ->
        Map.new(parametros, fn p -> {p.codigo, tipar(p.default, p.tipo)} end)

      asignacion ->
        perfil_id = Map.fetch!(asignacion, String.to_existing_atom(campo_perfil))
        valores_perfil = valores_por_parametro("pty_config_perfilesdet", "pty_config_perfilesdet_parametro", "pty_config_perfilesdet_parametro_valor", perfil_id)
        excepciones = valores_por_parametro(catalogo_exc, campo_exc_parametro, campo_exc_valor, asignacion.id)

        Map.new(parametros, fn p ->
          valor = Map.get(excepciones, p.id) || Map.get(valores_perfil, p.id) || p.default
          {p.codigo, tipar(valor, p.tipo)}
        end)
    end
  end

  defp parametros_base_vivos do
    modulo = MetaSchemaContext.modulo_por_nombre("pty_config")
    activo_id = MetadataApp.MetaStateEngine.estado_inicial("pty_config").id

    modulo
    |> CatalogoGenerico.listar(:sistema, %{"estado_id" => activo_id})
    |> Enum.map(&%{id: &1.id, codigo: &1.pty_config_parametro, tipo: &1.pty_config_parametro_tipo, default: &1.pty_config_parametro_valor})
  end

  # "Viva" acá = estado Activo del propio catálogo maestro del eje
  # (mismo criterio que completitud_perfil/1) -- una asignación dada de
  # baja no debe seguir resolviendo configuración.
  defp buscar_asignacion_viva(catalogo_maestro, campo_entidad, entidad_id) do
    modulo = MetaSchemaContext.modulo_por_nombre(catalogo_maestro)
    activo_id = MetadataApp.MetaStateEngine.estado_inicial(catalogo_maestro).id

    modulo
    |> CatalogoGenerico.listar(:sistema, %{campo_entidad => entidad_id, "estado_id" => activo_id})
    |> List.first()
  end

  defp valores_por_parametro(_catalogo, _campo_parametro, _campo_valor, nil), do: %{}

  defp valores_por_parametro(catalogo, campo_parametro, campo_valor, encabezado_id) do
    modulo = MetaSchemaContext.modulo_por_nombre(catalogo)
    campo_parametro_atom = String.to_existing_atom(campo_parametro)
    campo_valor_atom = String.to_existing_atom(campo_valor)

    modulo
    |> CatalogoGenerico.listar(:sistema, %{"encabezado_id" => encabezado_id})
    |> Map.new(&{Map.fetch!(&1, campo_parametro_atom), Map.fetch!(&1, campo_valor_atom)})
  end

  defp tipar(nil, _tipo), do: nil
  defp tipar(valor, "boolean"), do: valor == "true"
  defp tipar(valor, "integer"), do: String.to_integer(valor)
  defp tipar(valor, "decimal"), do: Decimal.to_float(elem(Decimal.parse(valor), 0))
  defp tipar(valor, _string_o_enum), do: valor
end
