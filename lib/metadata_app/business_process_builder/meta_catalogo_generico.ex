defmodule MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico do
  # campos: [{nombre, tipo, opciones}, ...]
  # tipo: :string | :integer | :decimal | :boolean | :date
  # opciones (mapa, todas las llaves opcionales):
  #   :longitud          — :string, validate_length
  #   :formato           — :string, regex (validate_format)
  #   :minimo / :maximo  — :integer | :decimal, validate_number
  #   :precision / :escala — :decimal, dígitos totales / decimales (numeric(p,s) en Postgres)
  #   :valores           — enum, validate_inclusion (tipo Ecto queda :string)
  #   :tabla_referenciada — FK a otro catálogo (tipo Ecto queda :integer)
  #   :unico_en          — {tabla_externa, campo_externo}, unicidad cross-tabla
  #   :opcional          — true: no entra a validate_required (default: todo campo es obligatorio)
  #   :valor_default     — solo con opcional != true: si el campo llega vacío,
  #                        se fuerza este valor en vez de rechazar el cambio
  #                        (ver forzar_defaults/2) — "obligatorio" blando, sin
  #                        tocar la columna física (esa sigue nullable).
  #                        Para :date/:time acepta los sentinelas "hoy"/
  #                        "ahora" -- se resuelven a Date.utc_today()/
  #                        Time.utc_now() EN CADA alta (ver
  #                        resolver_valor_default/2), no a la fecha en que
  #                        se configuró el campo.
  defmacro __using__(opts) do
    tabla = Keyword.fetch!(opts, :tabla)
    campos_ast = Keyword.fetch!(opts, :campos)
    # campos_ast llega como AST (los 3-tuplas no son auto-quote); se evalúa
    # porque son literales puros (átomos, enteros, strings, mapas, tuplas),
    # sin efectos.
    {campos, _bindings} = Code.eval_quoted(campos_ast, [], __CALLER__)

    transaccional? = Keyword.get(opts, :transaccional, false)
    codigo_trn = Keyword.get(opts, :codigo_trn)
    folio? = Keyword.get(opts, :folio, false)
    detalle_de = Keyword.get(opts, :detalle_de)
    alcance? = Keyword.get(opts, :alcance, false)

    campo_nombres = Enum.map(campos, &elem(&1, 0))

    campo_nombres_requeridos =
      for {nombre, _tipo, opciones} <- campos, opciones[:opcional] != true, do: nombre

    campos_meta = Macro.escape(campos)
    nombre_indice = MetadataApp.BusinessProcessBuilder.CatalogoGenerador.nombre_indice_unico(tabla)

    field_asts =
      for {nombre, tipo, _opciones} <- campos do
        quote do
          field unquote(nombre), unquote(tipo)
        end
      end

    trn_field_asts = trn_field_asts(transaccional?)
    trn_behaviour_ast = trn_behaviour_ast(transaccional?, codigo_trn)
    folio_field_asts = folio_field_asts(folio?)
    detalle_field_asts = detalle_field_asts(detalle_de)
    alcance_field_asts = alcance_field_asts(alcance?)

    quote do
      use Ecto.Schema
      import Ecto.Changeset

      schema unquote(tabla) do
        unquote_splicing(field_asts)
        field :insert_guid, :string
        field :update_guid, :string
        field :delete_guid, :string

        # Campo de sistema del Motor de Estados. Deliberadamente fuera de
        # @campos: nunca se castea acá — el único camino para cambiarlo es
        # MetadataApp.MetaStateEngine.ejecutar_transicion/3.
        field :estado_id, :integer

        # Fecha de alta (2026-08-06) — deliberadamente fuera de @campos,
        # mismo criterio que estado_id/TRN: el único camino para
        # asignarla es CatalogoGenerico.crear/2 (y el equivalente en
        # MetaStateEngine para catálogos con transición "alta"), nunca un
        # cast directo — así nadie la pisa por PATCH. Existe en TODA
        # tabla generada (no depende de ninguna opción del catálogo),
        # a diferencia de TRN/maestro-detalle de arriba.
        field :fecha_registro, :utc_datetime

        # PrettyCore TRN (Fase 1, 2026-07-21) — deliberadamente fuera de
        # @campos, mismo criterio que estado_id: el único camino para
        # asignarlos es MetadataApp.IdentificadoresTransaccionales.asignar/4,
        # nunca un PATCH. Solo existen si `transaccional: true`.
        unquote_splicing(trn_field_asts)

        # SPEC-SYS-0109202601 (Administrador de Folios, design.md §3.3) —
        # deliberadamente fuera de @campos, mismo criterio que trn/ulid
        # arriba: el único camino para asignarlos es
        # MetadataApp.IdentificadoresTransaccionales.asignar/4. Solo
        # existen si `folio: true` (que a su vez exige `transaccional:
        # true`, ver Header.validar_requiere_folio/1).
        unquote_splicing(folio_field_asts)

        # Catálogo Maestro-Detalle (Fase 1) — deliberadamente fuera de
        # @campos: el único camino para asignarlos es
        # MetadataApp.Renglones.preparar/3 (llamado desde
        # CatalogoGenerico.crear/2), nunca un cast directo. Solo existen
        # si `detalle_de` está seteado.
        unquote_splicing(detalle_field_asts)

        # Dimensiones del modelo de Alcance de Datos (Fase 9, 2026-08-11)
        # — deliberadamente fuera de @campos, mismo criterio que
        # estado_id/trn/renglones arriba: el único camino para escribirlas
        # es CatalogoGenerico.preparar_attrs_con_alcance/3 (branch_id/
        # sales_unit_id/inventory_id, validados contra el scope) y
        # estampar_creado_por_en_attrs/3 (creado_por_id, siempre
        # automático), nunca un cast directo del formulario de negocio.
        # Solo existen si `alcance: true` -- ver
        # CatalogoGenerador.asegurar_columnas_alcance/1, que agrega las
        # columnas físicas Y regenera este archivo cuando un catálogo
        # activa `alcance_habilitado`.
        unquote_splicing(alcance_field_asts)
      end

      unquote(trn_behaviour_ast)

      @campos unquote(campo_nombres)
      @campos_requeridos unquote(campo_nombres_requeridos)
      @campos_meta unquote(campos_meta)
      @nombre_indice unquote(nombre_indice)

      def changeset(struct, attrs) do
        struct
        |> cast(MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico.forzar_defaults(struct, attrs, @campos_meta), @campos)
        |> MetadataApp.BusinessProcessBuilder.MetaSchemaContext.aplicar_campos_calculados(unquote(tabla))
        |> validate_required(@campos_requeridos, message: "no puede quedar vacío")
        |> MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico.aplicar_validaciones(@campos_meta)
        |> MetadataApp.BusinessProcessBuilder.MetaSchemaContext.validar_dependencias_referencia(unquote(tabla))
        |> MetadataApp.BusinessProcessBuilder.MetaSchemaContext.validar_formato_captura(unquote(tabla))
        # "folio: true" (2026-09-11, bug real en pty_dsd_pedidos): un
        # catálogo con folio es por diseño una serie de DOCUMENTOS
        # repetibles (pedidos, movimientos) -- el folio/TRN ya es su
        # identidad real, así que exigir además que TODOS sus campos de
        # negocio combinados sean únicos rechazaba pedidos legítimos
        # (mismo cliente/sucursal/fecha, un caso normal). El índice
        # compuesto sigue existiendo para cualquier catálogo SIN folio
        # (ahí sí previene filas duplicadas de verdad, ej. Clientes/Marca).
        |> unquote(
          if folio? do
            quote(do: Function.identity())
          else
            quote(do: unique_constraint(@campos, name: @nombre_indice, message: "ya existe un registro con estos valores"))
          end
        )
      end
    end
  end

  defp trn_field_asts(false), do: []

  defp trn_field_asts(true) do
    [
      quote(do: field(:trn, :string)),
      quote(do: field(:ulid, :string))
    ]
  end

  defp folio_field_asts(false), do: []

  defp folio_field_asts(true) do
    [
      quote(do: field(:folio_serie, :string)),
      quote(do: field(:folio_numero, :integer))
    ]
  end

  defp trn_behaviour_ast(false, _codigo), do: quote(do: nil)

  defp trn_behaviour_ast(true, codigo) do
    quote do
      @behaviour MetadataApp.Transaction
      @impl true
      def transaction_code, do: unquote(codigo)
    end
  end

  defp detalle_field_asts(nil), do: []

  defp detalle_field_asts(_tabla_maestro) do
    [
      quote(do: field(:encabezado_id, :id)),
      quote(do: field(:renglon_id, :integer))
    ]
  end

  defp alcance_field_asts(false), do: []

  defp alcance_field_asts(true) do
    [
      quote(do: field(:branch_id, :integer)),
      quote(do: field(:sales_unit_id, :integer)),
      quote(do: field(:inventory_id, :integer)),
      quote(do: field(:creado_por_id, :integer))
    ]
  end

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  # "Obligatorio + valor default forzoso" (2026-08-05, a pedido explícito)
  # — regla de negocio a nivel changeset, aparte de la restricción física de
  # la columna (esa la alinea CatalogoGenerador.sincronizar_nulabilidad_
  # campo/2 cuando se cambia "obligatorio" desde BcMotorLive, agregado
  # 2026-08-17). Opera sobre `attrs`
  # ANTES de cast/2 a propósito, no con put_change/3 después: así el valor
  # default (guardado como texto plano en la metadata) pasa por el mismo
  # casteo de tipo que cualquier valor que llegara de un formulario real
  # (string -> integer/decimal/date/etc.), en vez de tener que reimplementar
  # ese casteo acá a mano. Un campo opcional que llega vacío se queda
  # vacío -- es una elección legítima de quien carga el dato, no un hueco
  # que forzar a rellenar.
  #
  # SPEC-SYS-1109202601 R45-R47 (2026-10-08): solo en un alta (el struct
  # todavía no está en la base). Al editar, un cambio que no trae el campo
  # lo reemplazaba por el default. Un opcional toma el default solo si la
  # llave no viene; si viene vacía, se respeta.
  def forzar_defaults(%Ecto.Changeset{data: struct}, attrs, campos_meta), do: forzar_defaults(struct, attrs, campos_meta)

  def forzar_defaults(struct, attrs, campos_meta) do
    if Ecto.get_meta(struct, :state) == :loaded do
      attrs
    else
      Enum.reduce(campos_meta, attrs, fn {campo, tipo, opciones}, acc ->
        aplicar_default(acc, campo, tipo, opciones)
      end)
    end
  end

  defp aplicar_default(attrs, campo, tipo, %{valor_default: valor_default} = opciones)
       when valor_default not in [nil, ""] do
    aplicar? =
      if opciones[:opcional] == true,
        do: not llave_presente?(attrs, campo),
        else: valor_en_blanco?(attrs, campo)

    with true <- aplicar?,
         {:ok, valor} <- valor_default_vigente(tipo, valor_default, opciones) do
      poner(attrs, campo, valor)
    else
      _ -> attrs
    end
  end

  defp aplicar_default(attrs, _campo, _tipo, _opciones), do: attrs

  # R47: el registro default de una referencia se usa solo si sigue existiendo.
  defp valor_default_vigente(:integer, valor, %{tabla_referenciada: tabla}) when is_binary(tabla) do
    with {id, ""} <- Integer.parse(to_string(valor)),
         true <- MetadataApp.Repo.exists?(from(t in tabla, where: field(t, :id) == ^id)) do
      {:ok, id}
    else
      _ -> :sin_default
    end
  end

  defp valor_default_vigente(tipo, valor, _opciones), do: {:ok, resolver_valor_default(tipo, valor)}

  @doc """
  Resuelve las variables de un valor default (R42, R48): `hoy`, `hoy+N`,
  `hoy-N` (fecha local) y `ahora` (hora local). Cualquier otro valor se
  regresa tal cual, para que lo castee el changeset.
  """
  def resolver_valor_default(:date, "hoy"), do: MetadataApp.Hoy.fecha()

  def resolver_valor_default(:date, "hoy" <> desfase = valor) do
    case Integer.parse(desfase) do
      {dias, ""} -> Date.add(MetadataApp.Hoy.fecha(), dias)
      _ -> valor
    end
  end

  def resolver_valor_default(:time, "ahora"), do: MetadataApp.Hoy.hora()
  def resolver_valor_default(_tipo, valor), do: valor

  @doc """
  Valida un valor default contra el tipo del campo (R43), con las
  propiedades del campo de `schema_context_properties`. `:ok` o
  `{:error, motivo}`.
  """
  def validar_valor_default(_props, valor) when valor in [nil, ""], do: :ok

  def validar_valor_default(%{"tipo" => "date"}, valor) do
    cond do
      valor == "hoy" -> :ok
      Regex.match?(~r/^hoy[+-](\d{1,4})$/, valor) and dias_validos?(valor) -> :ok
      match?({:ok, _}, Date.from_iso8601(valor)) -> :ok
      true -> {:error, "usa AAAA-MM-DD, hoy, hoy+N u hoy-N (N de 1 a 3650)"}
    end
  end

  def validar_valor_default(%{"tipo" => "hora"}, valor) do
    if valor == "ahora" or match?({:ok, _}, Time.from_iso8601(valor <> if(String.length(valor) == 5, do: ":00", else: ""))),
      do: :ok,
      else: {:error, "usa HH:MM o ahora"}
  end

  def validar_valor_default(%{"tipo" => "integer"}, valor),
    do: if(Regex.match?(~r/^-?\d+$/, valor), do: :ok, else: {:error, "debe ser un número entero"})

  def validar_valor_default(%{"tipo" => "decimal"}, valor),
    do: if(Regex.match?(~r/^-?\d+(\.\d+)?$/, valor), do: :ok, else: {:error, "debe ser un número"})

  def validar_valor_default(%{"tipo" => "boolean"}, valor),
    do: if(valor in ["true", "false"], do: :ok, else: {:error, "debe ser true o false"})

  def validar_valor_default(%{"tipo" => "enum", "valores" => valores}, valor) when is_list(valores) do
    permitidos = Enum.map(valores, fn %{"valor" => v} -> v; v -> v end)
    if valor in permitidos, do: :ok, else: {:error, "debe ser una de las opciones de la lista"}
  end

  def validar_valor_default(%{"tipo" => "referencia"}, valor),
    do: if(Regex.match?(~r/^\d+$/, valor), do: :ok, else: {:error, "elige un registro de la lista"})

  def validar_valor_default(%{"longitud" => longitud}, valor) when is_integer(longitud) do
    if String.length(valor) <= longitud, do: :ok, else: {:error, "excede la longitud del campo (#{longitud})"}
  end

  def validar_valor_default(_props, _valor), do: :ok

  defp dias_validos?("hoy" <> desfase) do
    {dias, ""} = Integer.parse(desfase)
    abs(dias) in 1..3650
  end

  defp llave_presente?(attrs, campo), do: Map.has_key?(attrs, campo) or Map.has_key?(attrs, Atom.to_string(campo))

  # Mismo tipo de llave que el resto de attrs (cast/2 no acepta mezcladas).
  defp poner(attrs, campo, valor) do
    attrs = attrs |> Map.delete(campo) |> Map.delete(Atom.to_string(campo))

    if Enum.any?(Map.keys(attrs), &is_atom/1),
      do: Map.put(attrs, campo, valor),
      else: Map.put(attrs, Atom.to_string(campo), valor)
  end

  defp valor_en_blanco?(attrs, campo) do
    valor = Map.get(attrs, campo, Map.get(attrs, Atom.to_string(campo)))
    valor in [nil, ""]
  end

  def aplicar_validaciones(changeset, campos_meta) do
    Enum.reduce(campos_meta, changeset, fn {campo, _tipo, opciones}, cs ->
      cs
      |> aplicar_transformacion(campo, opciones)
      |> aplicar_longitud(campo, opciones)
      |> aplicar_formato(campo, opciones)
      |> aplicar_rango(campo, opciones)
      |> aplicar_escala(campo, opciones)
      |> aplicar_valores(campo, opciones)
      |> aplicar_referencia(campo, opciones)
      |> aplicar_unico_en(campo, opciones)
    end)
  end

  # Corre ANTES que el resto (longitud/formato validan el valor YA
  # transformado — ej. una "Mayúsculas" + un regex que exige mayúsculas
  # tienen que ver lo mismo). update_change/3 no hace nada si el campo no
  # tiene cambio, así que es seguro para cualquier campo sin tocar.
  defp aplicar_transformacion(cs, campo, %{transformacion: transformacion})
       when transformacion in ["mayusculas", "minusculas", "capitalizar"] do
    update_change(cs, campo, &transformar_texto(&1, transformacion))
  end

  defp aplicar_transformacion(cs, _campo, _opciones), do: cs

  defp transformar_texto(valor, "mayusculas") when is_binary(valor), do: String.upcase(valor)
  defp transformar_texto(valor, "minusculas") when is_binary(valor), do: String.downcase(valor)

  defp transformar_texto(valor, "capitalizar") when is_binary(valor) do
    valor |> String.downcase() |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp transformar_texto(valor, _transformacion), do: valor

  defp aplicar_longitud(cs, campo, opciones) do
    cs
    |> aplicar_longitud_maxima(campo, opciones[:longitud])
    |> aplicar_longitud_minima(campo, opciones[:longitud_minima])
  end

  defp aplicar_longitud_maxima(cs, campo, longitud) when is_integer(longitud),
    do: validate_length(cs, campo, max: longitud, message: "no puede tener más de %{count} caracteres")

  defp aplicar_longitud_maxima(cs, _campo, _longitud), do: cs

  defp aplicar_longitud_minima(cs, campo, longitud) when is_integer(longitud),
    do: validate_length(cs, campo, min: longitud, message: "tiene que tener al menos %{count} caracteres")

  defp aplicar_longitud_minima(cs, _campo, _longitud), do: cs

  defp aplicar_formato(cs, campo, %{formato: formato}) when is_binary(formato),
    do: validate_format(cs, campo, Regex.compile!(formato), message: "no tiene el formato correcto")

  defp aplicar_formato(cs, _campo, _opciones), do: cs

  defp aplicar_rango(cs, campo, opciones) do
    cs
    |> aplicar_minimo(campo, opciones[:minimo])
    |> aplicar_maximo(campo, opciones[:maximo])
  end

  defp aplicar_minimo(cs, _campo, nil), do: cs

  defp aplicar_minimo(cs, campo, minimo),
    do: validate_number(cs, campo, greater_than_or_equal_to: minimo, message: "debe ser mayor o igual a %{number}")

  defp aplicar_maximo(cs, _campo, nil), do: cs

  defp aplicar_maximo(cs, campo, maximo),
    do: validate_number(cs, campo, less_than_or_equal_to: maximo, message: "debe ser menor o igual a %{number}")

  defp aplicar_escala(cs, campo, %{escala: escala}) when is_integer(escala) do
    validate_change(cs, campo, fn _campo, valor ->
      case valor do
        %Decimal{} = d ->
          # Decimales reales: "10.500000" cabe en una columna de 2.
          if Decimal.scale(Decimal.normalize(d)) > escala,
            do: [{campo, "no puede tener más de #{escala} decimales"}],
            else: []

        _ ->
          []
      end
    end)
  end

  defp aplicar_escala(cs, _campo, _opciones), do: cs

  defp aplicar_valores(cs, campo, %{valores: valores}) when is_list(valores),
    do: validate_inclusion(cs, campo, valores, message: "no es un valor permitido")

  defp aplicar_valores(cs, _campo, _opciones), do: cs

  # SPEC-SYS-0810202601 (R9, D5): el generador nombra la llave
  # "<campo>_fkey"; el nombre por omisión de Ecto ("<tabla>_<campo>_fkey")
  # queda para tablas viejas. Sin el nombre real, Ecto no traduce el error y
  # la operación truena en lugar de regresar el campo.
  defp aplicar_referencia(cs, campo, %{tabla_referenciada: tabla}) when is_binary(tabla) do
    cs
    |> foreign_key_constraint(campo, message: "no existe un registro con este valor")
    |> foreign_key_constraint(campo, name: "#{campo}_fkey", message: "no existe un registro con este valor")
  end

  defp aplicar_referencia(cs, _campo, _opciones), do: cs

  defp aplicar_unico_en(cs, campo, %{unico_en: {tabla, campo_externo}}),
    do: MetadataApp.BusinessProcessBuilder.CatalogoGenerico.validar_unico_en(cs, campo, tabla, campo_externo)

  defp aplicar_unico_en(cs, _campo, _opciones), do: cs
end
