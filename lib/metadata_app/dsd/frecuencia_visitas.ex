defmodule MetadataApp.Dsd.FrecuenciaVisitas do
  @moduledoc """
  Motor de recurrencia del módulo DSD de frecuencias de visita.

  Módulo de funciones puras: sin `Repo`, sin efectos, sin procesos. No se
  materializa ningún plan de visitas -- todo listado se deriva evaluando
  este motor sobre el historial de vigencias.

  Los parámetros `vigencia` y `frecuencia` no requieren ser los structs
  Ecto de `PtyDsdCsVigenciasFrec`/`PtyDsdCsFrecuencias`: alcanza con
  cualquier mapa o struct que exponga los mismos campos (acceso por
  punto funciona igual sobre mapas simples), lo que permite probar este
  módulo con datos de prueba livianos sin tocar la base de datos.

  Contrato de `selector_dias` (string CSV), según `frecuencia_base`:
    - "diaria" | "semanal" | "quincenal": días ISO-8601 permitidos en la
      semana (1=lunes .. 7=domingo), uno o más. "quincenal" es
      semánticamente "semanal" con intervalo 2.
    - "mensual": un único entero, el día del mes (1-31). No soporta
      posición ("primer lunes") -- fuera de alcance por ahora.
    - "anual": no se usa; el mes/día de recurrencia sale de la fecha
      ancla efectiva.
  """

  @type fecha :: Date.t()
  @type vigencia :: %{
          optional(atom()) => term(),
          pty_dsd_cs_vigencias_frec_vigente_desde: fecha(),
          pty_dsd_cs_vigencias_frec_vigente_hasta: fecha() | nil,
          pty_dsd_cs_vigencias_frec_fecha_ancla: fecha() | nil
        }
  @type frecuencia :: %{
          optional(atom()) => term(),
          pty_dsd_cs_frecuencias_frecuencia_base: String.t(),
          pty_dsd_cs_frecuencias_intervalo: pos_integer(),
          pty_dsd_cs_frecuencias_selector_dias: String.t() | nil,
          pty_dsd_cs_frecuencias_ancla_default: fecha() | nil
        }

  @doc """
  ¿La `fecha` está cubierta por el rango [`vigente_desde`, `vigente_hasta`]
  de esta vigencia? (`vigente_hasta` nil = indefinido hacia adelante).
  """
  @spec vigente_en?(vigencia(), fecha()) :: boolean()
  def vigente_en?(vigencia, fecha) do
    Date.compare(fecha, vigencia.pty_dsd_cs_vigencias_frec_vigente_desde) != :lt and
      (is_nil(vigencia.pty_dsd_cs_vigencias_frec_vigente_hasta) or
         Date.compare(fecha, vigencia.pty_dsd_cs_vigencias_frec_vigente_hasta) != :gt)
  end

  @doc """
  Predicado central: ¿esta vigencia, bajo esta frecuencia, programa una
  visita en `fecha`?
  """
  @spec aplica?(vigencia(), frecuencia(), fecha()) :: boolean()
  def aplica?(vigencia, frecuencia, fecha) do
    vigente_en?(vigencia, fecha) and coincide_con_patron?(vigencia, frecuencia, fecha)
  end

  @doc """
  De una lista de vigencias de UN cliente, la que rige en `fecha` (o
  `nil` si ninguna). Invariante #1 (no-solape) garantiza que hay a lo
  sumo una -- este motor no lo re-valida, confía en él.
  """
  @spec vigencia_vigente_en([vigencia()], fecha()) :: vigencia() | nil
  def vigencia_vigente_en(vigencias, fecha) do
    Enum.find(vigencias, &vigente_en?(&1, fecha))
  end

  @doc "Fechas programadas de un cliente dentro de [`desde`, `hasta`], resolviendo su historial de vigencias fecha a fecha."
  @spec fechas_programadas([vigencia()], %{term() => frecuencia()}, fecha(), fecha()) :: [fecha()]
  def fechas_programadas(vigencias, frecuencias_por_id, desde, hasta) do
    Date.range(desde, hasta)
    |> Enum.filter(&aplica_resolviendo_vigencia?(vigencias, frecuencias_por_id, &1))
  end

  @doc "Clientes con visita programada en `fecha`. `vigencias_por_cliente` mapea cliente_id => lista de sus vigencias."
  @spec clientes_programados_en_fecha(%{term() => [vigencia()]}, %{term() => frecuencia()}, fecha()) :: [term()]
  def clientes_programados_en_fecha(vigencias_por_cliente, frecuencias_por_id, fecha) do
    for {cliente_id, vigencias} <- vigencias_por_cliente,
        aplica_resolviendo_vigencia?(vigencias, frecuencias_por_id, fecha) do
      cliente_id
    end
  end

  @doc "Reporteo por período: clientes programados por cada fecha de [`desde`, `hasta`]."
  @spec clientes_programados_en_rango(%{term() => [vigencia()]}, %{term() => frecuencia()}, fecha(), fecha()) :: %{
          fecha() => [term()]
        }
  def clientes_programados_en_rango(vigencias_por_cliente, frecuencias_por_id, desde, hasta) do
    Map.new(Date.range(desde, hasta), fn fecha ->
      {fecha, clientes_programados_en_fecha(vigencias_por_cliente, frecuencias_por_id, fecha)}
    end)
  end

  @doc "Simulación de carga: conteo de clientes programados por cada fecha de [`desde`, `hasta`]."
  @spec carga_por_dia(%{term() => [vigencia()]}, %{term() => frecuencia()}, fecha(), fecha()) :: %{fecha() => non_neg_integer()}
  def carga_por_dia(vigencias_por_cliente, frecuencias_por_id, desde, hasta) do
    vigencias_por_cliente
    |> clientes_programados_en_rango(frecuencias_por_id, desde, hasta)
    |> Map.new(fn {fecha, clientes} -> {fecha, length(clientes)} end)
  end

  defp aplica_resolviendo_vigencia?(vigencias, frecuencias_por_id, fecha) do
    case vigencia_vigente_en(vigencias, fecha) do
      nil ->
        false

      vigencia ->
        frecuencia = Map.fetch!(frecuencias_por_id, vigencia.pty_dsd_cs_vigencias_frec_frecuencia)
        aplica?(vigencia, frecuencia, fecha)
    end
  end

  defp coincide_con_patron?(vigencia, frecuencia, fecha) do
    ancla = ancla_efectiva(vigencia, frecuencia)

    case frecuencia.pty_dsd_cs_frecuencias_frecuencia_base do
      base when base in ["diaria", "semanal", "quincenal"] ->
        dia_en_selector?(frecuencia, fecha) and
          semanas_desde_ancla_multiplo_de_intervalo?(ancla, frecuencia, fecha)

      "mensual" ->
        dia_del_mes_coincide?(frecuencia, fecha) and
          meses_desde_ancla_multiplo_de_intervalo?(ancla, frecuencia, fecha)

      "anual" ->
        fecha_anual_coincide?(ancla, fecha)
    end
  end

  # La vigencia hereda `ancla_default` del patrón si no trae la propia
  # (ver Post rule de altas de vigencia); si ninguna de las dos existe,
  # se ancla al inicio de la vigencia misma -- único punto de referencia
  # determinista que siempre existe.
  defp ancla_efectiva(vigencia, frecuencia) do
    vigencia.pty_dsd_cs_vigencias_frec_fecha_ancla ||
      frecuencia.pty_dsd_cs_frecuencias_ancla_default ||
      vigencia.pty_dsd_cs_vigencias_frec_vigente_desde
  end

  defp dias_permitidos(frecuencia) do
    (frecuencia.pty_dsd_cs_frecuencias_selector_dias || "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_integer/1)
  end

  defp dia_en_selector?(frecuencia, fecha) do
    Date.day_of_week(fecha) in dias_permitidos(frecuencia)
  end

  defp semanas_desde_ancla_multiplo_de_intervalo?(ancla, frecuencia, fecha) do
    intervalo = frecuencia.pty_dsd_cs_frecuencias_intervalo || 1
    inicio_semana_ancla = Date.beginning_of_week(ancla, :monday)
    inicio_semana_fecha = Date.beginning_of_week(fecha, :monday)
    semanas = div(Date.diff(inicio_semana_fecha, inicio_semana_ancla), 7)
    Integer.mod(semanas, intervalo) == 0
  end

  defp dia_del_mes_coincide?(frecuencia, fecha) do
    dia_objetivo = String.to_integer(frecuencia.pty_dsd_cs_frecuencias_selector_dias)
    fecha.day == dia_objetivo
  end

  defp meses_desde_ancla_multiplo_de_intervalo?(ancla, frecuencia, fecha) do
    intervalo = frecuencia.pty_dsd_cs_frecuencias_intervalo || 1
    meses = (fecha.year - ancla.year) * 12 + (fecha.month - ancla.month)
    Integer.mod(meses, intervalo) == 0
  end

  defp fecha_anual_coincide?(ancla, fecha) do
    fecha.month == ancla.month and fecha.day == ancla.day
  end
end
