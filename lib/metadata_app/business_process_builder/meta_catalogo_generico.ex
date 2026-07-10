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
  defmacro __using__(opts) do
    tabla = Keyword.fetch!(opts, :tabla)
    campos_ast = Keyword.fetch!(opts, :campos)
    # campos_ast llega como AST (los 3-tuplas no son auto-quote); se evalúa
    # porque son literales puros (átomos, enteros, strings, mapas, tuplas),
    # sin efectos.
    {campos, _bindings} = Code.eval_quoted(campos_ast, [], __CALLER__)

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
      end

      @campos unquote(campo_nombres)
      @campos_requeridos unquote(campo_nombres_requeridos)
      @campos_meta unquote(campos_meta)
      @nombre_indice unquote(nombre_indice)

      def changeset(struct, attrs) do
        struct
        |> cast(attrs, @campos)
        |> validate_required(@campos_requeridos)
        |> MetadataApp.BusinessProcessBuilder.MetaCatalogoGenerico.aplicar_validaciones(@campos_meta)
        |> unique_constraint(@campos, name: @nombre_indice)
      end
    end
  end

  import Ecto.Changeset

  def aplicar_validaciones(changeset, campos_meta) do
    Enum.reduce(campos_meta, changeset, fn {campo, _tipo, opciones}, cs ->
      cs
      |> aplicar_longitud(campo, opciones)
      |> aplicar_formato(campo, opciones)
      |> aplicar_rango(campo, opciones)
      |> aplicar_escala(campo, opciones)
      |> aplicar_valores(campo, opciones)
      |> aplicar_referencia(campo, opciones)
      |> aplicar_unico_en(campo, opciones)
    end)
  end

  defp aplicar_longitud(cs, campo, %{longitud: longitud}) when is_integer(longitud),
    do: validate_length(cs, campo, max: longitud)

  defp aplicar_longitud(cs, _campo, _opciones), do: cs

  defp aplicar_formato(cs, campo, %{formato: formato}) when is_binary(formato),
    do: validate_format(cs, campo, Regex.compile!(formato))

  defp aplicar_formato(cs, _campo, _opciones), do: cs

  defp aplicar_rango(cs, campo, opciones) do
    cs
    |> aplicar_minimo(campo, opciones[:minimo])
    |> aplicar_maximo(campo, opciones[:maximo])
  end

  defp aplicar_minimo(cs, _campo, nil), do: cs

  defp aplicar_minimo(cs, campo, minimo),
    do: validate_number(cs, campo, greater_than_or_equal_to: minimo)

  defp aplicar_maximo(cs, _campo, nil), do: cs

  defp aplicar_maximo(cs, campo, maximo),
    do: validate_number(cs, campo, less_than_or_equal_to: maximo)

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
    do: validate_inclusion(cs, campo, valores)

  defp aplicar_valores(cs, _campo, _opciones), do: cs

  defp aplicar_referencia(cs, campo, %{tabla_referenciada: tabla}) when is_binary(tabla),
    do: foreign_key_constraint(cs, campo)

  defp aplicar_referencia(cs, _campo, _opciones), do: cs

  defp aplicar_unico_en(cs, campo, %{unico_en: {tabla, campo_externo}}),
    do: MetadataApp.BusinessProcessBuilder.CatalogoGenerico.validar_unico_en(cs, campo, tabla, campo_externo)

  defp aplicar_unico_en(cs, _campo, _opciones), do: cs
end
