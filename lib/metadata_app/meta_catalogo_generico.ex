defmodule MetadataApp.MetaCatalogoGenerico do
  # campos: [{nombre, tipo, longitud_o_nil}, ...]
  # tipo: :string | :integer | :decimal
  # longitud solo aplica a :string (validate_length); en otros tipos va nil.
  defmacro __using__(opts) do
    tabla = Keyword.fetch!(opts, :tabla)
    campos_ast = Keyword.fetch!(opts, :campos)
    # campos_ast llega como AST (los 3-tuplas no son auto-quote); se evalúa
    # porque son literales puros (átomos, enteros, nil), sin efectos.
    {campos, _bindings} = Code.eval_quoted(campos_ast, [], __CALLER__)

    campo_nombres = Enum.map(campos, &elem(&1, 0))
    campos_meta = Macro.escape(campos)
    nombre_indice = "#{tabla}_" <> Enum.join(campo_nombres, "_") <> "_index"

    field_asts =
      for {nombre, tipo, _longitud} <- campos do
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
      end

      @campos unquote(campo_nombres)
      @campos_meta unquote(campos_meta)
      @nombre_indice unquote(nombre_indice)

      def changeset(struct, attrs) do
        struct
        |> cast(attrs, @campos)
        |> validate_required(@campos)
        |> aplicar_validaciones(@campos_meta)
        |> unique_constraint(@campos, name: @nombre_indice)
      end

      defp aplicar_validaciones(changeset, campos_meta) do
        Enum.reduce(campos_meta, changeset, fn
          {campo, :string, longitud}, cs when is_integer(longitud) ->
            validate_length(cs, campo, max: longitud)

          _campo_meta, cs ->
            cs
        end)
      end
    end
  end
end
