defmodule MetadataAppWeb.Sysadmin.FieldDesignerComponents do
  @moduledoc """
  "Diseñador Inteligente de Campos" — reemplazo de `modal_campo/1` (el
  viejo formulario con un `<select>` de tipo técnico) por un asistente de
  2 pantallas: Paso 1 elige QUÉ información captura el campo (tarjetas,
  nunca "string"/"integer"), Paso 2 elige QUÉ sabe hacer ("capacidades")
  — el "Paso 3" del mockup de referencia (configurar la capacidad recién
  tildada) se muestra INLINE debajo de cada checkbox activo, no como una
  pantalla de navegación aparte.

  Alcance: solo CREAR un campo nuevo — editar las capacidades de uno ya
  existente sigue en los botones/modales de siempre ("Configurar" en
  Relaciones, "Cascada", "Formato" en Campos), sin tocar. Fusionarlos
  hubiera significado reescribir 3 flujos ya probados en la misma entrega
  — decisión tomada con el usuario antes de empezar a programar.

  Todas las "capacidades" reusan el motor que YA existe para el campo
  equivalente creado a mano: `formato_captura`
  (MetaSchemaContext.validar_formato_captura/2), `dependencias`
  (validar_dependencias_referencia/2), `formula` (Formula.evaluar/2 vía
  MetaSchemaContext.aplicar_campos_calculados/2), `transformacion`/
  `longitud_minima` (MetaCatalogoGenerico.aplicar_validaciones/2) — este
  módulo solo arma la metadata, cero motor de validación nuevo.
  """
  use Phoenix.Component
  alias MetadataApp.BusinessProcessBuilder.MetaSchemaContext
  alias Phoenix.LiveView.JS

  # =========================================================================
  # Estado
  # =========================================================================

  def estado_inicial do
    %{
      "paso" => 1,
      "tipo" => nil,
      "nombre" => "",
      "etiqueta" => "",
      "catalogo" => "",
      "capacidades" => %{},
      "formato_modo" => nil,
      "formato_patron" => "",
      "formato_decimales" => 2,
      "formato_separador_miles" => true,
      "formato_simbolo" => "$",
      "formato_simbolo_posicion" => "prefijo",
      "formato_permitir_negativos" => false,
      "transformacion_tipo" => "mayusculas",
      "placeholder_texto" => "",
      "valor_inicial" => "",
      "longitud_min_valor" => "",
      "longitud_max_valor" => "",
      "regex_modo" => "solo_numeros",
      "regex_valor" => "",
      "campos_acompanamiento" => [],
      "campos_relacion" => [],
      "dependencias" => [],
      "formula" => "",
      "valores_lista" => ["", ""],
      "error" => nil
    }
  end

  # Cambiar de tipo reinicia capacidades/config (no tienen sentido cruzadas
  # entre tipos — "longitud mínima" en un campo que pasó a ser Fecha, por
  # ejemplo) pero conserva nombre/etiqueta, que sí son independientes del
  # tipo.
  def elegir_tipo(form, tipo) do
    estado_inicial()
    |> Map.put("tipo", tipo)
    |> Map.put("paso", 2)
    |> Map.put("nombre", form["nombre"] || "")
    |> Map.put("etiqueta", form["etiqueta"] || "")
  end

  # phx-change único de toda la pantalla del Paso 2 — capacidades,
  # nombre/etiqueta/catálogo, y cualquier sub-campo de configuración que
  # esté visible en ese momento llegan todos juntos en `params` (mismo
  # criterio que formato_cambiar/2 en BcMotorLive: sin filas repetidas que
  # reordenar, no hace falta separar por evento).
  def aplicar_cambios(form, params, campos_existentes) do
    capacidades =
      form["tipo"]
      |> capacidades_para_tipo()
      |> Enum.flat_map(fn {_grupo, items} -> items end)
      |> Map.new(fn {clave, _etiqueta} -> {clave, params["cap_#{clave}"] == "true"} end)

    modo_formato = params["formato_modo"] || form["formato_modo"] || modo_por_defecto_formato(form["tipo"])

    form
    |> Map.put("nombre", Map.get(params, "nombre", form["nombre"]))
    |> Map.put("etiqueta", Map.get(params, "etiqueta", form["etiqueta"]))
    |> Map.put("catalogo", Map.get(params, "catalogo", form["catalogo"]))
    |> Map.put("capacidades", capacidades)
    |> Map.put("formato_modo", modo_formato)
    |> Map.put("formato_patron", patron_por_defecto_formato(modo_formato) || Map.get(params, "formato_patron", form["formato_patron"]))
    |> Map.put("formato_decimales", a_entero(params["formato_decimales"], form["formato_decimales"]))
    |> Map.put("formato_separador_miles", params["formato_separador_miles"] == "true")
    |> Map.put("formato_simbolo", Map.get(params, "formato_simbolo", form["formato_simbolo"]))
    |> Map.put("formato_simbolo_posicion", params["formato_simbolo_posicion"] || form["formato_simbolo_posicion"])
    |> Map.put("formato_permitir_negativos", params["formato_permitir_negativos"] == "true")
    |> Map.put("transformacion_tipo", params["transformacion_tipo"] || form["transformacion_tipo"])
    |> Map.put("placeholder_texto", Map.get(params, "placeholder_texto", form["placeholder_texto"]))
    |> Map.put("valor_inicial", Map.get(params, "valor_inicial", form["valor_inicial"]))
    |> Map.put("longitud_min_valor", Map.get(params, "longitud_min_valor", form["longitud_min_valor"]))
    |> Map.put("longitud_max_valor", Map.get(params, "longitud_max_valor", form["longitud_max_valor"]))
    |> Map.put("regex_modo", params["regex_modo"] || form["regex_modo"])
    |> Map.put("regex_valor", Map.get(params, "regex_valor", form["regex_valor"]))
    |> Map.put("campos_acompanamiento", params |> Map.get("campos_acompanamiento", form["campos_acompanamiento"]) |> List.wrap() |> Enum.reject(&(&1 == "")))
    |> Map.put("campos_relacion", params |> Map.get("campos_relacion", form["campos_relacion"]) |> List.wrap() |> Enum.reject(&(&1 == "")))
    |> Map.put("dependencias", dependencias_desde_params(params, form))
    |> Map.put("formula", Map.get(params, "formula", form["formula"]))
    |> Map.put("valores_lista", valores_lista_desde_params(params, form))
    |> Map.put("error", nil)
    |> validar_nombre_duplicado(campos_existentes)
  end

  defp dependencias_desde_params(%{"dependencias" => deps_params}, _form) do
    deps_params
    |> Enum.sort_by(fn {indice, _valores} -> String.to_integer(indice) end)
    |> Enum.map(fn {_indice, v} -> %{"campo_padre" => v["campo_padre"], "campo_remoto" => v["campo_remoto"], "obligatorio" => v["obligatorio"] == "true"} end)
  end

  defp dependencias_desde_params(_params, form), do: form["dependencias"]

  defp valores_lista_desde_params(%{"valores_lista" => vl}, _form) when is_map(vl) do
    vl |> Enum.sort_by(fn {i, _v} -> String.to_integer(i) end) |> Enum.map(fn {_i, v} -> v end)
  end

  defp valores_lista_desde_params(_params, form), do: form["valores_lista"]

  # No bloquea el avance (el error real, si el nombre choca de verdad,
  # sale recién al guardar contra `campos_existentes` fresco) — es solo
  # feedback temprano mientras se tipea.
  defp validar_nombre_duplicado(form, _campos_existentes), do: form

  defp a_entero(valor, default) when is_binary(valor) do
    case Integer.parse(valor) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp a_entero(_valor, default), do: default

  defp modo_por_defecto_formato("string"), do: "telefono"
  defp modo_por_defecto_formato(tipo) when tipo in ["integer", "decimal"], do: "numero"
  defp modo_por_defecto_formato(_tipo), do: nil

  defp patron_por_defecto_formato("telefono"), do: "(999) 999-9999"
  defp patron_por_defecto_formato("cp"), do: "99999"
  defp patron_por_defecto_formato("rfc"), do: "AAAA999999AA9"
  defp patron_por_defecto_formato("curp"), do: "AAAA999999AAAAAA*9"
  defp patron_por_defecto_formato("fecha"), do: "99/99/9999"
  defp patron_por_defecto_formato(_modo), do: nil

  # =========================================================================
  # Guardar: arma schema_context_properties a partir del estado acumulado
  # =========================================================================

  def construir_propiedades(%{"tipo" => "referencia"} = form, campos_existentes, catalogo_nombre) do
    catalogo = form["catalogo"] || ""
    destino = catalogo != "" && MetaSchemaContext.obtener_header_por_nombre(catalogo)

    cond do
      catalogo == "" ->
        {:error, "Elegí a qué catálogo apunta la referencia."}

      is_nil(destino) or destino == false ->
        {:error, "Ese catálogo destino ya no existe."}

      true ->
        nombre = "#{catalogo_nombre}_#{String.replace_prefix(catalogo, "pty_", "")}"
        cap = form["capacidades"] || %{}

        if Enum.any?(campos_existentes, &(&1.schema_context_field == nombre)) do
          {:error, "Ya existe un campo que referencia a #{destino.schema_context_label} en este catálogo."}
        else
          propiedades =
            %{
              "etiqueta" => destino.schema_context_label,
              "tipo" => "referencia",
              "orden" => length(campos_existentes) + 1,
              "visible" => cap["oculto"] != true,
              "editable" => cap["solo_lectura"] != true,
              "opcional" => false,
              "catalogo" => catalogo
            }
            |> agregar_relaciones(form, cap)

          {:ok, nombre, propiedades}
        end
    end
  end

  def construir_propiedades(form, campos_existentes, catalogo_nombre) do
    sufijo = String.trim(form["nombre"] || "")
    etiqueta = String.trim(form["etiqueta"] || "")
    tipo = form["tipo"]
    cap = form["capacidades"] || %{}
    obligatorio? = cap["obligatorio"] == true
    nombre = "#{catalogo_nombre}_#{sufijo}"
    valores_lista = (form["valores_lista"] || []) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    cond do
      not Regex.match?(~r/^[a-z][a-z0-9_]{0,49}$/, sufijo) ->
        {:error, "Nombre inválido — minúsculas, sin acentos ni espacios, debe empezar con una letra."}

      etiqueta == "" ->
        {:error, "La etiqueta no puede quedar vacía."}

      tipo == "enum" and valores_lista == [] ->
        {:error, "Una Lista necesita al menos una opción."}

      Enum.any?(campos_existentes, &(&1.schema_context_field == nombre)) ->
        {:error, "Ya existe un campo \"#{sufijo}\" en este catálogo."}

      true ->
        propiedades =
          %{
            "etiqueta" => etiqueta,
            "tipo" => tipo,
            "orden" => length(campos_existentes) + 1,
            "visible" => cap["oculto"] != true,
            "editable" => cap["solo_lectura"] != true,
            "opcional" => not obligatorio?
          }
          |> agregar_longitud(form, tipo, cap)
          |> agregar_formato_captura(form, cap)
          |> agregar_transformacion(form, cap)
          |> agregar_placeholder(form, cap)
          |> agregar_valor_inicial(form, cap)
          |> agregar_regex(form, cap)
          |> agregar_valores_lista(valores_lista, tipo)
          |> agregar_formula(form, cap)

        {:ok, nombre, propiedades}
    end
  end

  defp agregar_longitud(propiedades, form, tipo, cap) when tipo in ["string", "texto_largo"] do
    propiedades
    |> maybe_put_entero(cap["longitud_min"] == true, "longitud_minima", form["longitud_min_valor"])
    |> maybe_put_entero(tipo == "string" and cap["longitud_max"] == true, "longitud", form["longitud_max_valor"])
  end

  defp agregar_longitud(propiedades, _form, _tipo, _cap), do: propiedades

  defp maybe_put_entero(propiedades, false, _clave, _valor), do: propiedades

  defp maybe_put_entero(propiedades, true, clave, valor) do
    case Integer.parse(to_string(valor || "")) do
      {n, _} -> Map.put(propiedades, clave, n)
      :error -> propiedades
    end
  end

  defp agregar_formato_captura(propiedades, form, %{"formato" => true}) do
    modo = form["formato_modo"]

    formato =
      if modo in ["numero", "moneda"] do
        %{
          "habilitada" => true,
          "modo" => modo,
          "decimales" => form["formato_decimales"],
          "separador_miles" => form["formato_separador_miles"],
          "simbolo" => if(modo == "moneda", do: form["formato_simbolo"]),
          "simbolo_posicion" => form["formato_simbolo_posicion"],
          "permitir_negativos" => form["formato_permitir_negativos"],
          "estricto" => true,
          "permitir_incompleto" => false,
          "mensaje_invalido" => ""
        }
      else
        %{
          "habilitada" => true,
          "modo" => modo,
          "patron" => patron_por_defecto_formato(modo) || form["formato_patron"],
          "guardar_formato" => true,
          "estricto" => true,
          "permitir_incompleto" => false,
          "mensaje_invalido" => ""
        }
      end

    Map.put(propiedades, "formato_captura", formato)
  end

  defp agregar_formato_captura(propiedades, _form, _cap), do: propiedades

  defp agregar_transformacion(propiedades, form, %{"transformacion" => true}),
    do: Map.put(propiedades, "transformacion", form["transformacion_tipo"])

  defp agregar_transformacion(propiedades, _form, _cap), do: propiedades

  defp agregar_placeholder(propiedades, form, %{"placeholder" => true}) do
    case String.trim(form["placeholder_texto"] || "") do
      "" -> propiedades
      texto -> Map.put(propiedades, "placeholder", texto)
    end
  end

  defp agregar_placeholder(propiedades, _form, _cap), do: propiedades

  defp agregar_valor_inicial(propiedades, form, %{"valor_inicial" => true}) do
    case String.trim(form["valor_inicial"] || "") do
      "" -> propiedades
      valor -> Map.put(propiedades, "valor_default", valor)
    end
  end

  defp agregar_valor_inicial(propiedades, _form, _cap), do: propiedades

  defp agregar_regex(propiedades, form, %{"regex" => true}) do
    patron =
      case form["regex_modo"] do
        "solo_numeros" -> "^[0-9]*$"
        "solo_letras" -> "^[a-zA-ZÀ-ÿ\\s]*$"
        "sin_especiales" -> "^[a-zA-Z0-9À-ÿ\\s]*$"
        "personalizado" -> form["regex_valor"]
        _ -> nil
      end

    case patron do
      p when is_binary(p) and p != "" -> Map.put(propiedades, "formato", p)
      _ -> propiedades
    end
  end

  defp agregar_regex(propiedades, _form, _cap), do: propiedades

  defp agregar_valores_lista(propiedades, valores, "enum"), do: Map.put(propiedades, "valores", valores)
  defp agregar_valores_lista(propiedades, _valores, _tipo), do: propiedades

  defp agregar_formula(propiedades, form, %{"calculado" => true}) do
    case String.trim(form["formula"] || "") do
      "" -> propiedades
      formula -> Map.put(propiedades, "formula", formula)
    end
  end

  defp agregar_formula(propiedades, _form, _cap), do: propiedades

  defp agregar_relaciones(propiedades, form, cap) do
    propiedades
    |> agregar_campos_acompanamiento(form, cap)
    |> agregar_dependencias(form, cap)
  end

  defp agregar_campos_acompanamiento(propiedades, form, %{"mostrar_varios" => true}) do
    propiedades
    |> Map.put("campos_acompanamiento", form["campos_acompanamiento"] || [])
    |> Map.put("campos_relacion", form["campos_relacion"] || [])
  end

  defp agregar_campos_acompanamiento(propiedades, _form, _cap), do: propiedades

  defp agregar_dependencias(propiedades, form, %{"cascada" => true}) do
    deps = (form["dependencias"] || []) |> Enum.filter(&(&1["campo_padre"] not in [nil, ""] and &1["campo_remoto"] not in [nil, ""]))
    if deps == [], do: propiedades, else: Map.put(propiedades, "dependencias", deps)
  end

  defp agregar_dependencias(propiedades, _form, _cap), do: propiedades

  # =========================================================================
  # Tipos (Paso 1) y capacidades por tipo (Paso 2)
  # =========================================================================

  @tipos [
    {"string", "Texto", "short_text", "Juan Pérez"},
    {"texto_largo", "Texto largo", "notes", "Comentarios, descripciones…"},
    {"integer", "Número entero", "tag", "1250"},
    {"decimal", "Número con decimales", "tag", "1250.35"},
    {"date", "Fecha", "calendar_month", "15/08/2026"},
    {"hora", "Hora", "schedule", "08:30"},
    {"enum", "Lista", "list", "Activo, Inactivo…"},
    {"referencia", "Referencia", "link", "Cliente, Empresa, Producto…"},
    {"boolean", "Verdadero/Falso", "toggle_on", "Sí / No"}
  ]

  defp tipos, do: @tipos

  defp etiqueta_tipo(tipo), do: Enum.find_value(@tipos, tipo, fn {t, e, _i, _ej} -> t == tipo && e end)

  # {grupo, [{clave, etiqueta}]} — el orden de los grupos es el que se
  # renderiza. Referencia es el único tipo con grupo "Relaciones"; ningún
  # tipo ofrece una capacidad que no tenga motor real (ver mapeo completo
  # en el plan de esta entrega).
  defp capacidades_para_tipo("string") do
    [
      {"Captura", [{"formato", "Formato automático"}, {"transformacion", "Mayúsculas / minúsculas"}, {"placeholder", "Texto de ejemplo"}, {"valor_inicial", "Valor inicial"}]},
      {"Validación", [{"obligatorio", "Obligatorio"}, {"longitud_min", "Longitud mínima"}, {"longitud_max", "Longitud máxima"}, {"regex", "Restringir caracteres"}]},
      {"Automatización", [{"calculado", "Campo calculado"}]},
      {"Visual", [{"solo_lectura", "Solo lectura"}, {"oculto", "Oculto"}]}
    ]
  end

  defp capacidades_para_tipo("texto_largo") do
    [
      {"Captura", [{"transformacion", "Mayúsculas / minúsculas"}, {"placeholder", "Texto de ejemplo"}, {"valor_inicial", "Valor inicial"}]},
      {"Validación", [{"obligatorio", "Obligatorio"}, {"longitud_min", "Longitud mínima"}]},
      {"Automatización", [{"calculado", "Campo calculado"}]},
      {"Visual", [{"solo_lectura", "Solo lectura"}, {"oculto", "Oculto"}]}
    ]
  end

  defp capacidades_para_tipo(tipo) when tipo in ["integer", "decimal"] do
    [
      {"Captura", [{"formato", "Formato automático"}, {"placeholder", "Texto de ejemplo"}, {"valor_inicial", "Valor inicial"}]},
      {"Validación", [{"obligatorio", "Obligatorio"}]},
      {"Automatización", [{"calculado", "Campo calculado"}]},
      {"Visual", [{"solo_lectura", "Solo lectura"}, {"oculto", "Oculto"}]}
    ]
  end

  defp capacidades_para_tipo("enum") do
    [
      {"Captura", [{"valor_inicial", "Valor inicial"}]},
      {"Validación", [{"obligatorio", "Obligatorio"}]},
      {"Visual", [{"solo_lectura", "Solo lectura"}, {"oculto", "Oculto"}]}
    ]
  end

  defp capacidades_para_tipo("referencia") do
    [
      {"Relaciones", [{"mostrar_varios", "Mostrar varios campos"}, {"cascada", "Dependencia en cascada"}]},
      {"Visual", [{"solo_lectura", "Solo lectura"}, {"oculto", "Oculto"}]}
    ]
  end

  defp capacidades_para_tipo(tipo) when tipo in ["date", "hora", "boolean"] do
    [
      {"Captura", [{"valor_inicial", "Valor inicial"}]},
      {"Validación", [{"obligatorio", "Obligatorio"}]},
      {"Automatización", [{"calculado", "Campo calculado"}]},
      {"Visual", [{"solo_lectura", "Solo lectura"}, {"oculto", "Oculto"}]}
    ]
  end

  defp capacidades_para_tipo(_tipo), do: []

  defp presets_formato("string"), do: [{"telefono", "Teléfono"}, {"cp", "Código postal"}, {"rfc", "RFC"}, {"curp", "CURP"}, {"fecha", "Fecha libre"}, {"personalizada", "Personalizada"}]
  defp presets_formato(tipo) when tipo in ["integer", "decimal"], do: [{"numero", "Número"}, {"moneda", "Moneda"}]
  defp presets_formato(_tipo), do: []

  # =========================================================================
  # Inteligencia: sugerencias por nombre de campo
  # =========================================================================

  # {patrones_en_nombre, descripción, [capacidades_a_activar], config_directa}
  @sugerencias [
    {~w(correo email mail), "Validación email + minúsculas", ["transformacion"], %{"transformacion_tipo" => "minusculas"}},
    {~w(telefono tel celular), "Formato teléfono", ["formato"], %{"formato_modo" => "telefono"}},
    {~w(rfc), "RFC + mayúsculas", ["formato", "transformacion"], %{"formato_modo" => "rfc", "transformacion_tipo" => "mayusculas"}},
    {~w(curp), "CURP + mayúsculas", ["formato", "transformacion"], %{"formato_modo" => "curp", "transformacion_tipo" => "mayusculas"}},
    {~w(cp codigopostal codigo_postal), "Formato código postal", ["formato"], %{"formato_modo" => "cp"}},
    {~w(importe monto precio total costo), "Moneda + 2 decimales", ["formato"], %{"formato_modo" => "moneda", "formato_decimales" => 2}}
  ]

  # Se calcula sobre la ETIQUETA (lo que la persona tipea, ej. "Correo
  # electrónico") sin acentos/espacios — nunca se aplica sola, solo se
  # ofrece como chip.
  defp sugerencias_para(etiqueta, tipo) do
    normalizada = etiqueta |> String.downcase() |> quitar_espacios_y_guiones()

    @sugerencias
    |> Enum.filter(fn {patrones, _desc, capacidades, _config} ->
      Enum.any?(patrones, &String.contains?(normalizada, &1)) and capacidades_disponibles?(capacidades, tipo)
    end)
    |> Enum.map(fn {_patrones, desc, capacidades, config} -> {desc, capacidades, config} end)
  end

  defp capacidades_disponibles?(capacidades, tipo) do
    claves_disponibles = tipo |> capacidades_para_tipo() |> Enum.flat_map(fn {_g, items} -> items end) |> Enum.map(&elem(&1, 0))
    Enum.all?(capacidades, &(&1 in claves_disponibles))
  end

  defp quitar_espacios_y_guiones(texto), do: String.replace(texto, ~r/[\s_-]+/, "")

  def aplicar_sugerencia(form, capacidades, config) do
    form
    |> Map.update!("capacidades", fn cap -> Enum.reduce(capacidades, cap, &Map.put(&2, &1, true)) end)
    |> Map.merge(config)
  end

  # =========================================================================
  # Render
  # =========================================================================

  attr :form, :map, required: true
  attr :catalogos, :list, required: true
  attr :nombre_base, :string, required: true
  attr :campos, :list, required: true

  def asistente(assigns) do
    ~H"""
    <div class="fixed inset-0 bg-black/40 flex items-center justify-center z-50 p-4">
      <div class="bg-white rounded-xl shadow-lg max-w-3xl w-full text-xs max-h-[92vh] overflow-y-auto">
        <div class="px-4 pt-4 pb-3 border-b border-gray-100 flex items-start justify-between gap-3">
          <div class="flex items-start gap-2.5">
            <span class="material-symbols-outlined text-purple-600 mt-0.5" style="font-size:20px">auto_awesome</span>
            <div>
              <h2 class="text-sm font-bold text-gray-900">Agregar campo</h2>
              <p class="text-gray-500 mt-0.5">
                <%= if @form["paso"] == 1 do %>
                  ¿Qué información va a capturar este campo?
                <% else %>
                  Capacidades — qué sabe hacer <span class="font-semibold text-gray-700">{if @form["etiqueta"] not in [nil, ""], do: @form["etiqueta"], else: "este campo"}</span>
                <% end %>
              </p>
            </div>
          </div>
          <button type="button" phx-click="cerrar_form_campo" class="text-gray-400 hover:text-gray-700 flex-shrink-0">
            <span class="material-symbols-outlined" style="font-size:20px">close</span>
          </button>
        </div>

        <div :if={@form["error"]} class="mx-4 mt-3 bg-red-50 text-red-700 rounded-lg px-2.5 py-1.5">{@form["error"]}</div>

        <%= if @form["paso"] == 1 do %>
          {paso1_tipo(assigns)}
        <% else %>
          {paso2_capacidades(assigns)}
        <% end %>
      </div>
    </div>
    """
  end

  defp paso1_tipo(assigns) do
    assigns = assign(assigns, :tipos, tipos())

    ~H"""
    <div class="p-4">
      <div class="grid grid-cols-3 gap-2">
        <button :for={{tipo, etiqueta, icono, ejemplo} <- @tipos} type="button" phx-click="asistente_elegir_tipo" phx-value-tipo={tipo}
          class="flex flex-col items-start gap-1.5 border border-gray-200 rounded-lg p-3 text-left hover:border-purple-400 hover:bg-purple-50 transition-colors">
          <span class="material-symbols-outlined text-purple-600" style="font-size:22px">{icono}</span>
          <span class="font-bold text-gray-900">{etiqueta}</span>
          <span class="text-gray-400 font-mono text-[10.5px]">{ejemplo}</span>
        </button>
      </div>
    </div>
    """
  end

  defp paso2_capacidades(assigns) do
    assigns =
      assigns
      |> assign(:grupos, capacidades_para_tipo(assigns.form["tipo"]))
      |> assign(:sugerencias, sugerencias_para(assigns.form["etiqueta"] || "", assigns.form["tipo"]))
      |> assign(:campos_destino, campos_destino_referencia(assigns.form["catalogo"]))
      |> assign(:otros_referencia, Enum.filter(assigns.campos, &(&1.schema_context_properties["tipo"] == "referencia")))

    ~H"""
    <div class="grid grid-cols-[1fr_260px]">
      <form phx-change="asistente_cambiar" phx-submit="guardar_campo_asistente" class="p-4 flex flex-col gap-3">
        <div class="flex items-center gap-1.5 text-gray-500">
          <span class="material-symbols-outlined text-purple-500" style="font-size:15px">{Enum.find_value(tipos(), fn {t, _e, i, _ej} -> t == @form["tipo"] && i end)}</span>
          <span>{etiqueta_tipo(@form["tipo"])}</span>
          <button type="button" phx-click="asistente_cambiar_tipo" class="text-purple-600 hover:text-purple-800 font-semibold">Cambiar</button>
        </div>

        <%= if @form["tipo"] == "referencia" do %>
          <div>
            <label class="block text-gray-700 mb-0.5 font-semibold">Catálogo destino</label>
            <select name="catalogo" class="w-full border border-gray-300 rounded-lg px-2 py-1.5">
              <option value="">— Elegir —</option>
              <option :for={c <- @catalogos} value={c.nombre} selected={@form["catalogo"] == c.nombre}>{c.etiqueta}</option>
            </select>
            <p class="mt-0.5 text-gray-500">El nombre y la etiqueta del campo se toman del catálogo elegido — siempre obligatorio.</p>
          </div>
        <% else %>
          <div class="grid grid-cols-2 gap-2">
            <div>
              <label class="block text-gray-700 mb-0.5 font-semibold">Nombre técnico</label>
              <input type="text" name="nombre" value={@form["nombre"]} placeholder="color" pattern="[a-z][a-z0-9_]*" maxlength="50"
                class="w-full border border-gray-300 rounded-lg px-2 py-1.5" />
              <p class="mt-0.5 text-gray-500 font-mono text-[10.5px]">{@nombre_base}_{if @form["nombre"] in [nil, ""], do: "…", else: @form["nombre"]}</p>
            </div>
            <div>
              <label class="block text-gray-700 mb-0.5 font-semibold">Etiqueta</label>
              <input type="text" name="etiqueta" value={@form["etiqueta"]} maxlength="100"
                class="w-full border border-gray-300 rounded-lg px-2 py-1.5" />
            </div>
          </div>

          <div :if={@sugerencias != []} class="flex flex-wrap items-center gap-1.5">
            <span class="text-gray-400">Sugerido:</span>
            <button :for={{desc, capacidades, config} <- @sugerencias} type="button"
              phx-click={JS.push("asistente_aplicar_sugerencia", value: %{"capacidades" => capacidades, "config" => config})}
              class="inline-flex items-center gap-1 bg-purple-50 text-purple-700 border border-purple-200 rounded-full px-2 py-0.5 hover:bg-purple-100">
              <span class="material-symbols-outlined" style="font-size:12px">auto_awesome</span>{desc}
            </button>
          </div>
        <% end %>

        <div :for={{grupo, items} <- @grupos} class="border-t border-gray-100 pt-2.5">
          <p class="text-gray-400 font-semibold uppercase tracking-wide text-[10.5px] mb-1.5">{grupo}</p>
          <div class="flex flex-col gap-1.5">
            <div :for={{clave, etiqueta} <- items}>
              <label class="flex items-center gap-1.5">
                <input type="hidden" name={"cap_#{clave}"} value="false" />
                <input type="checkbox" name={"cap_#{clave}"} value="true" checked={@form["capacidades"][clave] == true} class="accent-purple-600" />
                {etiqueta}
              </label>
              <div :if={@form["capacidades"][clave] == true} class="ml-5 mt-1.5 mb-0.5 border-l-2 border-purple-100 pl-2.5">
                {config_capacidad(clave, assigns)}
              </div>
            </div>
          </div>
        </div>

        <div class="flex justify-end gap-2 pt-2 border-t border-gray-100">
          <button type="button" phx-click="cerrar_form_campo" class="px-3 py-1.5 rounded-lg border border-gray-300 text-gray-700 font-semibold hover:bg-gray-50">
            Cancelar
          </button>
          <button type="submit" class="px-3 py-1.5 rounded-lg bg-purple-600 text-white font-semibold hover:bg-purple-700">
            Crear campo
          </button>
        </div>
      </form>

      <div class="border-l border-gray-100 bg-gray-50 p-4">
        <p class="text-gray-400 font-semibold uppercase tracking-wide text-[10.5px] mb-2">Vista previa</p>
        {vista_previa(assigns)}
      </div>
    </div>
    """
  end

  # --- config inline por capacidad (el "Paso 3" del mockup) -------------------

  defp config_capacidad("formato", assigns) do
    assigns = assign(assigns, :presets, presets_formato(assigns.form["tipo"]))

    ~H"""
    <div class="flex flex-col gap-2">
      <div class="grid grid-cols-2 gap-1.5">
        <label :for={{valor, etiqueta} <- @presets} class={["flex items-center gap-1.5 border rounded-lg px-2 py-1 cursor-pointer", @form["formato_modo"] == valor && "border-purple-500 bg-purple-50" || "border-gray-200"]}>
          <input type="radio" name="formato_modo" value={valor} checked={@form["formato_modo"] == valor} class="accent-purple-600" />
          {etiqueta}
        </label>
      </div>

      <%= if @form["formato_modo"] == "personalizada" do %>
        <div>
          <label class="block text-gray-500 mb-0.5">Patrón</label>
          <input type="text" name="formato_patron" value={@form["formato_patron"]} placeholder="AAA-9999" spellcheck="false"
            class="w-full border border-gray-300 rounded-lg px-2 py-1 font-mono" />
          <p class="mt-0.5 text-gray-500"><b class="font-mono">A</b> letra · <b class="font-mono">9</b> número · <b class="font-mono">*</b> cualquiera.</p>
        </div>
      <% end %>

      <%= if @form["formato_modo"] in ["numero", "moneda"] do %>
        <div class="grid grid-cols-2 gap-2">
          <div>
            <label class="block text-gray-500 mb-0.5">Decimales</label>
            <input type="number" name="formato_decimales" value={@form["formato_decimales"]} min="0" max="6" class="w-full border border-gray-300 rounded-lg px-2 py-1" />
          </div>
          <div :if={@form["formato_modo"] == "moneda"}>
            <label class="block text-gray-500 mb-0.5">Símbolo</label>
            <input type="text" name="formato_simbolo" value={@form["formato_simbolo"]} maxlength="4" class="w-full border border-gray-300 rounded-lg px-2 py-1" />
          </div>
        </div>
        <label class="flex items-center gap-1.5">
          <input type="hidden" name="formato_separador_miles" value="false" />
          <input type="checkbox" name="formato_separador_miles" value="true" checked={@form["formato_separador_miles"]} class="accent-purple-600" />
          Separador de miles
        </label>
        <label class="flex items-center gap-1.5">
          <input type="hidden" name="formato_permitir_negativos" value="false" />
          <input type="checkbox" name="formato_permitir_negativos" value="true" checked={@form["formato_permitir_negativos"]} class="accent-purple-600" />
          Permitir negativos
        </label>
      <% end %>
    </div>
    """
  end

  defp config_capacidad("transformacion", assigns) do
    ~H"""
    <div class="flex gap-1.5">
      <label :for={{valor, etiqueta} <- [{"mayusculas", "MAYÚSCULAS"}, {"minusculas", "minúsculas"}, {"capitalizar", "Capitalizado"}]}
        class={["flex items-center gap-1 border rounded-lg px-2 py-1 cursor-pointer", @form["transformacion_tipo"] == valor && "border-purple-500 bg-purple-50" || "border-gray-200"]}>
        <input type="radio" name="transformacion_tipo" value={valor} checked={@form["transformacion_tipo"] == valor} class="accent-purple-600" />
        {etiqueta}
      </label>
    </div>
    """
  end

  defp config_capacidad("placeholder", assigns) do
    ~H"""
    <input type="text" name="placeholder_texto" value={@form["placeholder_texto"]} placeholder="Ej. Escribí tu nombre completo"
      class="w-full border border-gray-300 rounded-lg px-2 py-1" />
    """
  end

  defp config_capacidad("valor_inicial", assigns) do
    ~H"""
    <%= if @form["tipo"] == "enum" do %>
      <select name="valor_inicial" class="w-full border border-gray-300 rounded-lg px-2 py-1">
        <option value="">— Sin valor inicial —</option>
        <option :for={v <- (@form["valores_lista"] || []) |> Enum.reject(&(&1 in [nil, ""]))} value={v} selected={@form["valor_inicial"] == v}>{v}</option>
      </select>
    <% else %>
      <%= if @form["tipo"] == "boolean" do %>
        <select name="valor_inicial" class="w-full border border-gray-300 rounded-lg px-2 py-1">
          <option value="" selected={@form["valor_inicial"] in [nil, ""]}>— Sin valor inicial —</option>
          <option value="true" selected={@form["valor_inicial"] == "true"}>Verdadero</option>
          <option value="false" selected={@form["valor_inicial"] == "false"}>Falso</option>
        </select>
      <% else %>
        <input type={if @form["tipo"] in ["date"], do: "date", else: (if @form["tipo"] == "hora", do: "time", else: "text")}
          name="valor_inicial" value={@form["valor_inicial"]} class="w-full border border-gray-300 rounded-lg px-2 py-1" />
      <% end %>
    <% end %>
    """
  end

  defp config_capacidad("longitud_min", assigns) do
    ~H"""
    <input type="number" name="longitud_min_valor" value={@form["longitud_min_valor"]} min="1" placeholder="Ej. 5"
      class="w-28 border border-gray-300 rounded-lg px-2 py-1" />
    """
  end

  defp config_capacidad("longitud_max", assigns) do
    ~H"""
    <input type="number" name="longitud_max_valor" value={@form["longitud_max_valor"]} min="1" placeholder="Ej. 100"
      class="w-28 border border-gray-300 rounded-lg px-2 py-1" />
    """
  end

  defp config_capacidad("regex", assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label :for={{valor, etiqueta} <- [{"solo_numeros", "Solo números"}, {"solo_letras", "Solo letras"}, {"sin_especiales", "Sin caracteres especiales"}, {"personalizado", "Personalizado"}]}
        class="flex items-center gap-1.5">
        <input type="radio" name="regex_modo" value={valor} checked={@form["regex_modo"] == valor} class="accent-purple-600" />
        {etiqueta}
      </label>
      <input :if={@form["regex_modo"] == "personalizado"} type="text" name="regex_valor" value={@form["regex_valor"]} placeholder="^[A-Z]{3}$" spellcheck="false"
        class="w-full border border-gray-300 rounded-lg px-2 py-1 font-mono" />
    </div>
    """
  end

  defp config_capacidad("calculado", assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <textarea name="formula" rows="2" placeholder="{cantidad} * {precio_unitario}"
        class="w-full border border-gray-300 rounded-lg px-2 py-1 font-mono">{@form["formula"]}</textarea>
      <div class="flex flex-wrap gap-1">
        <button :for={c <- @campos} type="button" phx-click="asistente_formula_insertar" phx-value-campo={c.schema_context_field}
          class="bg-white border border-gray-200 rounded px-1.5 py-0.5 text-gray-600 hover:border-purple-400 font-mono text-[10.5px]">
          {c.schema_context_field}
        </button>
      </div>
      <p class="text-gray-500">Se recalcula solo — el campo queda deshabilitado, no se tipea a mano.</p>
    </div>
    """
  end

  defp config_capacidad("mostrar_varios", assigns) do
    ~H"""
    <div :if={@form["catalogo"] in [nil, ""]} class="text-gray-400">Elegí primero el catálogo destino.</div>
    <div :if={@form["catalogo"] not in [nil, ""]} class="flex flex-col gap-1">
      <p class="text-gray-500">Campos que trae de {etiqueta_catalogo(@catalogos, @form["catalogo"])}:</p>
      <label :for={c <- @campos_destino} class="flex items-center gap-1.5">
        <input type="checkbox" name="campos_acompanamiento[]" value={c.schema_context_field} checked={c.schema_context_field in (@form["campos_acompanamiento"] || [])} class="accent-purple-600" />
        {c.schema_context_properties["etiqueta"] || c.schema_context_field}
      </label>
    </div>
    """
  end

  defp config_capacidad("cascada", assigns) do
    ~H"""
    <div :if={@otros_referencia == []} class="text-gray-400">
      Este catálogo no tiene otro campo tipo referencia todavía del que pueda depender.
    </div>
    <div :if={@otros_referencia != []} class="flex flex-col gap-2">
      <div :for={{dep, i} <- Enum.with_index(@form["dependencias"])} class="border border-gray-200 rounded-lg p-2">
        <div class="grid grid-cols-2 gap-1.5">
          <select name={"dependencias[#{i}][campo_padre]"} class="w-full border border-gray-300 rounded-lg px-1.5 py-1">
            <option value="">— Depende de —</option>
            <option :for={c <- @otros_referencia} value={c.schema_context_field} selected={dep["campo_padre"] == c.schema_context_field}>{c.schema_context_properties["etiqueta"] || c.schema_context_field}</option>
          </select>
          <select name={"dependencias[#{i}][campo_remoto]"} class="w-full border border-gray-300 rounded-lg px-1.5 py-1">
            <option value="">— Filtrar por —</option>
            <option :for={c <- @campos_destino} value={c.schema_context_field} selected={dep["campo_remoto"] == c.schema_context_field}>{c.schema_context_properties["etiqueta"] || c.schema_context_field}</option>
          </select>
        </div>
        <button type="button" phx-click="asistente_dependencia_quitar" phx-value-indice={i} class="text-red-600 hover:text-red-800 font-semibold mt-1">Quitar</button>
      </div>
      <button type="button" phx-click="asistente_dependencia_agregar" class="text-purple-700 hover:text-purple-900 font-semibold text-left">+ Agregar dependencia</button>
    </div>
    """
  end

  defp config_capacidad(_clave, assigns), do: ~H""

  defp etiqueta_catalogo(catalogos, nombre), do: Enum.find_value(catalogos, nombre, fn c -> c.nombre == nombre && c.etiqueta end)

  defp campos_destino_referencia(nil), do: []
  defp campos_destino_referencia(""), do: []

  defp campos_destino_referencia(catalogo) do
    catalogo |> MetaSchemaContext.listar_detalles() |> Enum.filter(& &1.schema_context_properties["visible"])
  end

  # --- vista previa en vivo ----------------------------------------------------
  # Muestra el ejemplo estático de la tarjeta elegida en Paso 1 más un
  # resumen en texto de las capacidades activas — una previsualización
  # pixel-perfect con CampoInputComponents.campo_input/1 de verdad
  # necesitaría un `columna`/opciones completos que este asistente (sin
  # persistir nada todavía) no tiene armados; se prefiere un resumen
  # honesto antes que una preview que pueda mentir.
  defp vista_previa(assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-lg p-3">
      <p class="text-gray-500 mb-1">{if @form["etiqueta"] not in [nil, ""], do: @form["etiqueta"], else: "Sin etiqueta todavía"}</p>
      <div class="border border-gray-300 rounded px-2 py-1.5 text-gray-400 font-mono bg-gray-50">
        {ejemplo_para_tipo(@form)}
      </div>
    </div>
    <ul class="mt-3 flex flex-col gap-1 text-gray-600">
      <li :for={{clave, etiqueta} <- capacidades_activas(@form)} class="flex items-center gap-1.5">
        <span class="material-symbols-outlined text-purple-500" style="font-size:14px">check_circle</span>
        {etiqueta_capacidad_activa(clave, etiqueta, @form)}
      </li>
    </ul>
    """
  end

  defp ejemplo_para_tipo(%{"tipo" => tipo, "formato_modo" => modo} = form) when tipo in ["string", "integer", "decimal"] and not is_nil(modo) do
    case modo do
      "telefono" -> "(999) 999-9999"
      "cp" -> "99999"
      "rfc" -> "AAAA999999AA9"
      "curp" -> "AAAA999999AAAAAA*9"
      "fecha" -> "99/99/9999"
      "personalizada" -> form["formato_patron"] || "…"
      "numero" -> "1,250" <> if((form["formato_decimales"] || 0) > 0, do: ".35", else: "")
      "moneda" -> "#{form["formato_simbolo"] || "$"}1,250" <> if((form["formato_decimales"] || 0) > 0, do: ".35", else: "")
      _ -> "…"
    end
  end

  defp ejemplo_para_tipo(%{"tipo" => tipo}), do: Enum.find_value(tipos(), "…", fn {t, _e, _i, ej} -> t == tipo && ej end)

  defp capacidades_activas(form) do
    (form["capacidades"] || %{})
    |> Enum.filter(fn {_clave, activo} -> activo == true end)
    |> Enum.map(fn {clave, _activo} ->
      etiqueta = form["tipo"] |> capacidades_para_tipo() |> Enum.flat_map(fn {_g, items} -> items end) |> Enum.find_value(clave, fn {c, e} -> c == clave && e end)
      {clave, etiqueta}
    end)
  end

  defp etiqueta_capacidad_activa("obligatorio", etiqueta, _form), do: etiqueta
  defp etiqueta_capacidad_activa("formato", _etiqueta, form), do: "Formato: #{Enum.find_value(presets_formato(form["tipo"]), form["formato_modo"], fn {v, e} -> v == form["formato_modo"] && e end)}"
  defp etiqueta_capacidad_activa(_clave, etiqueta, _form), do: etiqueta
end
