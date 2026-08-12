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
  #                        tocar la columna física (esa sigue nullable)
  defmacro __using__(opts) do
    tabla = Keyword.fetch!(opts, :tabla)
    campos_ast = Keyword.fetch!(opts, :campos)
    # campos_ast llega como AST (los 3-tuplas no son auto-quote); se evalúa
    # porque son literales puros (átomos, enteros, strings, mapas, tuplas),
    # sin efectos.
    {campos, _bindings} = Code.eval_quoted(campos_ast, [], __CALLER__)

    transaccional? = Keyword.get(opts, :transaccional, false)
    codigo_trn = Keyword.get(opts, :codigo_trn)
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

        # PrettyCore TRN (Fase 1, 2026-07-21) — deliberadamente fuera de
        # @campos, mismo criterio que estado_id: el único camino para
        # asignarlos es MetadataApp.TRN.asignar_si_transaccional/1, nunca
        # un PATCH. Solo existen si `transaccional: true`.
        unquote_splicing(trn_field_asts)

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
        |> cast(MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico.forzar_defaults(attrs, @campos_meta), @campos)
        |> MetadataApp.BusinessProcessBuilder.MetaSchemaContext.aplicar_campos_calculados(unquote(tabla))
        |> validate_required(@campos_requeridos, message: "no puede quedar vacío")
        |> MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico.aplicar_validaciones(@campos_meta)
        |> MetadataApp.BusinessProcessBuilder.MetaSchemaContext.validar_dependencias_referencia(unquote(tabla))
        |> MetadataApp.BusinessProcessBuilder.MetaSchemaContext.validar_formato_captura(unquote(tabla))
        |> unique_constraint(@campos, name: @nombre_indice, message: "ya existe un registro con estos valores")
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

  # "Obligatorio + valor default forzoso" (2026-08-05, a pedido explícito)
  # — regla de negocio BLANDA, no de integridad de datos: la columna
  # física se queda nullable siempre (sin ALTER COLUMN, sin verificar
  # NULLs existentes en producción antes de nada). Opera sobre `attrs`
  # ANTES de cast/2 a propósito, no con put_change/3 después: así el valor
  # default (guardado como texto plano en la metadata) pasa por el mismo
  # casteo de tipo que cualquier valor que llegara de un formulario real
  # (string -> integer/decimal/date/etc.), en vez de tener que reimplementar
  # ese casteo acá a mano. Un campo opcional que llega vacío se queda
  # vacío -- es una elección legítima de quien carga el dato, no un hueco
  # que forzar a rellenar.
  def forzar_defaults(attrs, campos_meta) do
    Enum.reduce(campos_meta, attrs, fn {campo, _tipo, opciones}, acc ->
      aplicar_default_forzoso(acc, campo, opciones)
    end)
  end

  defp aplicar_default_forzoso(attrs, campo, %{opcional: opcional, valor_default: valor_default})
       when opcional != true and valor_default not in [nil, ""] do
    if valor_en_blanco?(attrs, campo) do
      attrs |> Map.delete(campo) |> Map.put(Atom.to_string(campo), valor_default)
    else
      attrs
    end
  end

  defp aplicar_default_forzoso(attrs, _campo, _opciones), do: attrs

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
          if Decimal.scale(d) > escala,
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

  defp aplicar_referencia(cs, campo, %{tabla_referenciada: tabla}) when is_binary(tabla),
    do: foreign_key_constraint(cs, campo, message: "no existe un registro con este valor")

  defp aplicar_referencia(cs, _campo, _opciones), do: cs

  defp aplicar_unico_en(cs, campo, %{unico_en: {tabla, campo_externo}}),
    do: MetadataApp.BusinessProcessBuilder.CatalogoGenerico.validar_unico_en(cs, campo, tabla, campo_externo)

  defp aplicar_unico_en(cs, _campo, _opciones), do: cs
end
