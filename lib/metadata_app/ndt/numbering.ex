defmodule MetadataApp.NDT.Numbering do
  @moduledoc """
  Motor de Numeración de Documentos Transaccionales (NDT) — único punto
  de entrada para pedir un folio. Ningún módulo consumidor (Sales,
  Purchasing, Inventory, ...) arma un folio a mano; todos llaman
  `next/1`.

  ## El perfil es un BC real (2026-08-31)

  `pty_ndt_configuracion` (carpeta Sistema/Transacciones, "NDT
  Configuración") es un catálogo del motor normal, NO un schema hecho a
  mano — administrado con el mismo Get/Post que cualquier otro BC, con
  su propio autómata (Activo/Cancelado, transiciones Registrar/Activar/
  Dar de baja/Reactivar). Reemplaza la tabla `ndt_numbering_profiles` de
  la Fase 1. Solo un perfil en estado "Activo" califica para `next/1` —
  "Cancelado" lo saca de circulación sin borrarlo (soft-delete real
  queda aparte, vía `delete_guid`, para cuando de verdad haya que
  eliminarlo).

  ## reserve() vs next() (sección 23 del spec)

  Deliberadamente NO existe un `reserve/1` separado de `next/1`, ni un
  estado `RESERVED` distinto de `ASSIGNED`. `next/1` asigna en el mismo
  paso que incrementa el contador — si la transacción que lo pidió
  falla DESPUÉS, ese folio queda asignado y no se reutiliza (hueco en la
  secuencia, ver ejemplo de la sección 23: 001025, 001026, 001028 es
  válido). Justificación: separar RESERVED/ASSIGNED solo tiene sentido
  si existe un requisito real de "no quiero un folio hasta que la
  transacción sea segura" — eso no está pedido hoy, y agregarlo
  "porque parece útil" es exactamente lo que el spec pide evitar. Si
  una localización fiscal concreta exige consecutividad estricta sin
  huecos, eso es una necesidad de ESE dominio (validarla ahí, con sus
  propias reglas), no una propiedad universal de NDT.

  ## Concurrencia

  Postgres es la única fuente de verdad. `next/1` bloquea la fila de
  `ndt_number_ranges` correspondiente al (perfil, período) con
  `SELECT ... FOR UPDATE` dentro de una transacción — dos pedidos para
  el MISMO perfil+período serializan; perfiles o períodos distintos
  jamás contienden entre sí (no hay lock global, no hay contador en
  memoria ni GenServer como fuente de verdad).

  ## Idempotencia

  Pasar `idempotency_key:` — si ya existe un audit con esa clave para
  el mismo perfil, `next/1` devuelve el folio YA asignado en vez de
  incrementar de nuevo. Ver `ndt_numbering_audits_idempotencia_unica_index`.
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.Estado
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias MetadataApp.NDT.{NumberRange, NumberingAudit}
  alias MetadataApp.MetaBusinessProcess.Catalogos.PtyNdtConfiguracion, as: Perfil

  @doc """
  Asigna el siguiente folio para `meta_schema_header_id` + `empresa_id`
  (Organización), acotando opcionalmente por `branch_id` (Unidad
  Operativa) y `serie`. Resolución de perfil (sección 16, granularidad):

    1. Si se pasa `branch_id`, busca un perfil ESPECÍFICO de esa unidad,
       en estado Activo.
    2. Si no hay ninguno, cae al perfil CENTRALIZADO (Unidad Operativa
       vacía) de la Organización, también Activo.
    3. Si más de un perfil sigue calificando (varias series activas para
       el mismo tipo de documento), hay que pasar `serie:` explícito —
       `{:error, :serie_ambigua}` si no se hizo.

  Devuelve `{:ok, %{folio:, secuencia:, serie:, numbering_profile_id:,
  numbering_audit_id:}}` o `{:error, motivo}`.
  """
  def next(opts) do
    meta_schema_header_id = Keyword.fetch!(opts, :meta_schema_header_id)
    empresa_id = Keyword.fetch!(opts, :empresa_id)
    branch_id = Keyword.get(opts, :branch_id)
    serie = Keyword.get(opts, :serie)
    idempotency_key = Keyword.get(opts, :idempotency_key)

    with {:ok, perfil} <- resolver_perfil(meta_schema_header_id, empresa_id, branch_id, serie) do
      case idempotency_key && buscar_por_idempotencia(perfil.id, idempotency_key) do
        %NumberingAudit{} = existente -> {:ok, resultado_de(existente, perfil)}
        _ -> asignar(perfil, opts, idempotency_key)
      end
    end
  end

  @doc "Marca un folio ya asignado como anulado (la transacción que lo usaba se invalidó). El folio NUNCA se reutiliza — ver moduledoc."
  def anular(numbering_audit_id) do
    case Repo.get(NumberingAudit, numbering_audit_id) do
      nil -> {:error, :no_encontrado}
      audit -> audit |> NumberingAudit.changeset_anular() |> Repo.update()
    end
  end

  @doc """
  Vista previa de SOLO LECTURA (`folio_actual`/`folio_siguiente`) -- no
  toca `ndt_number_ranges`, no consume ningún número, es apenas leer el
  contador del período vigente y formatear.
  """
  def previsualizar(%Perfil{} = perfil) do
    ahora = DateTime.utc_now()
    periodo = calcular_periodo(perfil.politica_reinicio, ahora)
    inicial = perfil.numero_inicial || 1

    numero_actual =
      case Repo.get_by(NumberRange, pty_ndt_configuracion_id: perfil.id, periodo: periodo) do
        nil -> inicial - 1
        range -> range.numero_actual
      end

    %{
      folio_actual: if(numero_actual >= inicial, do: formatear_folio(perfil, ahora, numero_actual)),
      folio_siguiente: formatear_folio(perfil, ahora, numero_actual + 1)
    }
  end

  defp resolver_perfil(header_id, empresa_id, branch_id, serie) do
    case buscar_perfiles(header_id, empresa_id, branch_id, serie) do
      [] when not is_nil(branch_id) -> header_id |> buscar_perfiles(empresa_id, nil, serie) |> uno_o_error()
      candidatos -> uno_o_error(candidatos)
    end
  end

  defp uno_o_error([perfil]), do: {:ok, perfil}
  defp uno_o_error([]), do: {:error, :perfil_no_encontrado}
  defp uno_o_error(_varios), do: {:error, :serie_ambigua}

  defp buscar_perfiles(header_id, empresa_id, branch_id, serie) do
    activo_id = estado_activo_id!()

    from(p in Perfil,
      where: p.documento == ^header_id and p.organizacion == ^empresa_id and p.estado_id == ^activo_id and is_nil(p.delete_guid)
    )
    |> filtrar_branch(branch_id)
    |> filtrar_serie(serie)
    |> Repo.all()
  end

  # "Activo" nunca cambia de id una vez sembrado -- una query chica más
  # por pedido de folio (no está en el camino caliente real, que es el
  # lock de ndt_number_ranges de abajo), sin cachear a propósito: mismo
  # criterio simple que el resto de NDT, nada de estado en memoria.
  defp estado_activo_id! do
    header = MetaSchemaContext.obtener_header_por_nombre("pty_ndt_configuracion")
    Repo.get_by!(Estado, meta_schema_header_id: header.id, nombre: "Activo").id
  end

  defp filtrar_branch(query, nil), do: where(query, [p], is_nil(p.unidad_operativa))
  defp filtrar_branch(query, branch_id), do: where(query, [p], p.unidad_operativa == ^branch_id)

  defp filtrar_serie(query, nil), do: query
  defp filtrar_serie(query, serie), do: where(query, [p], p.serie == ^serie)

  defp buscar_por_idempotencia(perfil_id, idempotency_key) do
    Repo.get_by(NumberingAudit, pty_ndt_configuracion_id: perfil_id, idempotency_key: idempotency_key)
  end

  defp asignar(perfil, opts, idempotency_key) do
    ahora = DateTime.utc_now()
    periodo = calcular_periodo(perfil.politica_reinicio, ahora)

    Repo.transaction(fn ->
      range = obtener_o_crear_range(perfil, periodo)
      secuencia = incrementar(range)
      folio = formatear_folio(perfil, ahora, secuencia)

      audit_attrs = %{
        pty_ndt_configuracion_id: perfil.id,
        ndt_number_range_id: range.id,
        meta_schema_header_id: perfil.documento,
        empresa_id: perfil.organizacion,
        branch_id: perfil.unidad_operativa,
        secuencia: secuencia,
        folio: folio,
        trn: Keyword.get(opts, :trn),
        entity_id: Keyword.get(opts, :entity_id),
        idempotency_key: idempotency_key,
        asignado_por_id: Keyword.get(opts, :asignado_por_id)
      }

      case %NumberingAudit{} |> NumberingAudit.changeset(audit_attrs) |> Repo.insert() do
        {:ok, audit} -> resultado_de(audit, perfil)
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # Upsert-then-lock: el insert best-effort puede perder la carrera (otro
  # proceso ya creó la fila de este período), por eso se ignora su
  # resultado — lo único que importa es el SELECT ... FOR UPDATE de abajo,
  # que sí ve la fila ya sea la que insertamos nosotros o la del otro
  # proceso, y la deja bloqueada para el resto de esta transacción.
  defp obtener_o_crear_range(perfil, periodo) do
    inicial = perfil.numero_inicial || 1

    %NumberRange{}
    |> NumberRange.changeset(%{pty_ndt_configuracion_id: perfil.id, periodo: periodo, numero_actual: inicial - 1})
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:pty_ndt_configuracion_id, :periodo])

    from(r in NumberRange, where: r.pty_ndt_configuracion_id == ^perfil.id and r.periodo == ^periodo, lock: "FOR UPDATE")
    |> Repo.one!()
  end

  defp incrementar(range) do
    {1, [secuencia]} =
      from(r in NumberRange, where: r.id == ^range.id, select: r.numero_actual)
      |> Repo.update_all(inc: [numero_actual: 1])

    secuencia
  end

  defp calcular_periodo("nunca", _ahora), do: ""
  defp calcular_periodo("anual", ahora), do: Calendar.strftime(ahora, "%Y")
  defp calcular_periodo("mensual", ahora), do: Calendar.strftime(ahora, "%Y%m")
  defp calcular_periodo("diario", ahora), do: Calendar.strftime(ahora, "%Y%m%d")
  defp calcular_periodo(nil, _ahora), do: ""

  # Concatenación literal, sin separadores implícitos entre prefijo/fecha/
  # número/sufijo -- prefijo/sufijo llevan su propio separador si lo
  # necesitan (ej. prefijo "PED-", no "PED"), tal como los ejemplos del
  # spec NDT los escriben ("PED-001025", "OC-MEX-2026-000001"). El único
  # separador que SÍ pone el motor es entre el bloque de fecha (calculado,
  # el admin no puede tipearlo) y el número.
  defp formatear_folio(perfil, ahora, secuencia) do
    padding = perfil.padding || 6
    numero = secuencia |> Integer.to_string() |> String.pad_leading(padding, "0")

    cuerpo =
      case segmento_fecha(perfil, ahora) do
        nil -> numero
        fecha -> fecha <> "-" <> numero
      end

    (perfil.prefijo || "") <> cuerpo <> (perfil.sufijo || "")
  end

  defp segmento_fecha(%{incluir_anio: true, incluir_mes: true, incluir_dia: true}, ahora), do: Calendar.strftime(ahora, "%Y%m%d")
  defp segmento_fecha(%{incluir_anio: true, incluir_mes: true}, ahora), do: Calendar.strftime(ahora, "%Y%m")
  defp segmento_fecha(%{incluir_anio: true}, ahora), do: Calendar.strftime(ahora, "%Y")
  defp segmento_fecha(_perfil, _ahora), do: nil

  defp resultado_de(%NumberingAudit{} = audit, %Perfil{} = perfil) do
    %{
      folio: audit.folio,
      secuencia: audit.secuencia,
      serie: perfil.serie,
      numbering_profile_id: perfil.id,
      numbering_audit_id: audit.id
    }
  end
end
