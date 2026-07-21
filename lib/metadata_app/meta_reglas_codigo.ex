defmodule MetadataApp.MetaReglasCodigo do
  @moduledoc """
  Código PRE/POST por catálogo (rediseño 2026-07-21) — un catálogo tiene A
  LO SUMO un código pre y un código post, guardados como texto en
  `meta_schema_reglas_codigo`, con un `case` interno por acción de
  transición (ver `MetaStateEngine.Reglas` para el despacho en runtime).

  No es obligatorio: un catálogo puede no tener fila para pre/post, y eso
  es válido — `MetaStateEngine.Reglas` trata "no existe el módulo
  compilado" como "no hace nada".

  Ciclo completo: Validar sintaxis (`validar_sintaxis/1`, solo parseo) →
  Guardar (`guardar/4`, solo persiste texto) → Compilar (`compilar/2`,
  SOLO dev/test — mismo guard que `generar_catalogos_en_caliente`, nunca
  corre en un release de producción) → Publicar (`publicar/2`, `git
  add`+`git commit` LOCAL, nunca `git push` — checkpoint humano antes de
  tocar `origin/main` compartido, mismo criterio que `mix motor.publicar`).

  Sin candado de edición (retirado 2026-07-21 a pedido explícito): sin
  login real todavía, un candado autodeclarado por nombre no era más que
  teatro de seguridad — las reglas quedan siempre editables por cualquiera
  hasta que exista autenticación de verdad, momento en el que el control
  de edición se rediseña desde cero (no se restaura este mecanismo).
  """

  import Ecto.Query
  alias MetadataApp.Repo
  alias MetadataApp.MetaSchema.ReglaCodigo
  alias MetadataApp.MetaEstadosAdmin
  alias MetadataApp.MetaStateEngine.Reglas

  @tipos ~w(pre post)

  # Sentinel literal que el generador de stub escribe en cada case branch
  # nuevo — buscar este string es la única forma barata de distinguir
  # "código completo" de "stub sin tocar" sin ejecutar el módulo (mismo
  # criterio que ya usaba el mecanismo viejo, un stub por transición).
  @marcador_stub "# ESCRIBA SU CODIGO AQUÍ"

  def marcador_stub, do: @marcador_stub

  def obtener(header_id, tipo) when tipo in @tipos do
    Repo.one(
      from r in ReglaCodigo,
        where: r.meta_schema_header_id == ^header_id and r.tipo == ^tipo and is_nil(r.delete_guid)
    )
  end

  @doc """
  true si hay código guardado pero todavía tiene el marcador de stub sin
  completar en algún lado. Independiente de compilar/2: un stub sin tocar
  es Elixir válido y compila sin problema, así que compilar exitosamente
  NO baja este flag — es el único chequeo que exige terminar (o borrar el
  marcador de) cada rama, y es lo que mantiene completitud.completo? en
  false y por lo tanto bloquea Guardar BC en BcMotorLive
  (puede_guardar_bc?/3) aunque "Compila Todo" haya dado éxito.
  """
  def pendiente?(header_id, tipo) do
    case obtener(header_id, tipo) do
      nil -> false
      %ReglaCodigo{codigo_fuente: codigo} -> String.contains?(codigo, @marcador_stub)
    end
  end

  @doc """
  Trae el código ya guardado (`{:existente, %ReglaCodigo{}}`) o genera —
  SIN guardar todavía — el stub inicial a partir de las transiciones
  reales del catálogo (`{:nuevo, codigo_fuente}`).
  """
  def obtener_o_generar(header, tipo) when tipo in @tipos do
    case obtener(header.id, tipo) do
      nil -> {:nuevo, generar_stub(header, tipo)}
      regla_codigo -> {:existente, regla_codigo}
    end
  end

  @doc """
  Acciones de transiciones reales del catálogo para las que el código
  guardado NO tiene un `case` (heurística por texto: busca `"accion" ->`
  literal en el código — no parsea el AST). Advisory, no bloquea nada —
  ver `MetaEstadosAdmin.validar_motor/1`. Si el catálogo todavía no tiene
  código guardado para `tipo`, devuelve `[]` (nada que advertir todavía,
  reglas no son obligatorias).
  """
  def transiciones_sin_case(header_id, tipo, transiciones) when tipo in @tipos do
    case obtener(header_id, tipo) do
      nil ->
        []

      %ReglaCodigo{codigo_fuente: codigo} ->
        transiciones
        |> Enum.map(& &1.accion)
        |> Enum.uniq()
        |> Enum.reject(&String.contains?(codigo, "#{inspect(&1)} ->"))
    end
  end

  @doc "Genera (sin guardar) el stub inicial — un `case` por acción real del catálogo, cada branch con el marcador de stub."
  def generar_stub(header, "pre") do
    modulo = Reglas.modulo_pre(header.schema_context_name)

    """
    defmodule #{inspect(modulo)} do
      @behaviour MetadataApp.MetaStateEngine.ReglaPre

      @impl true
      def evaluar(accion, _registro, _contexto) do
        case accion do
    #{clausulas_pre(acciones_de(header))}
          _ -> :ok
        end
      end
    end
    """
  end

  def generar_stub(header, "post") do
    modulo = Reglas.modulo_post(header.schema_context_name)

    """
    defmodule #{inspect(modulo)} do
      @behaviour MetadataApp.MetaStateEngine.ReglaPost

      @impl true
      def ejecutar(accion, _registro, _contexto, _repo) do
        case accion do
    #{clausulas_post(acciones_de(header))}
          _ -> {:ok, :sin_cambios}
        end
      end
    end
    """
  end

  defp acciones_de(header) do
    header.id
    |> MetaEstadosAdmin.listar_transiciones()
    |> Enum.map(& &1.accion)
    |> Enum.uniq()
  end

  defp clausulas_pre(acciones) do
    Enum.map_join(acciones, "\n", fn accion ->
      "      #{inspect(accion)} ->\n        #{@marcador_stub}\n        :ok\n"
    end)
  end

  defp clausulas_post(acciones) do
    Enum.map_join(acciones, "\n", fn accion ->
      "      #{inspect(accion)} ->\n        #{@marcador_stub}\n        {:ok, :sin_cambios}\n"
    end)
  end

  @doc """
  Guarda `codigo_fuente` para `header`/`tipo` (insert si es la primera vez,
  update si ya existía) — solo persiste texto, no compila ni ejecuta nada.
  `editado_por` es opcional (hoy siempre `nil` desde la UI, sin login real
  todavía no hay nombre confiable que estampar).
  """
  def guardar(header, tipo, codigo_fuente, editado_por \\ nil) when tipo in @tipos do
    case obtener(header.id, tipo) do
      nil ->
        %ReglaCodigo{}
        |> ReglaCodigo.changeset(%{
          meta_schema_header_id: header.id,
          tipo: tipo,
          codigo_fuente: codigo_fuente,
          editado_por: editado_por
        })
        |> Ecto.Changeset.change(%{insert_guid: generar_guid()})
        |> Repo.insert()

      regla_codigo ->
        regla_codigo
        |> ReglaCodigo.changeset(%{codigo_fuente: codigo_fuente, editado_por: editado_por})
        |> Ecto.Changeset.change(%{update_guid: generar_guid()})
        |> Repo.update()
    end
  end

  @doc "Solo parsea (AST) — no ejecuta nada. Atrapa typos, no atrapa código peligroso."
  def validar_sintaxis(codigo_fuente) do
    case Code.string_to_quoted(codigo_fuente) do
      {:ok, _ast} -> :ok
      {:error, {linea, mensaje, token}} -> {:error, "línea #{inspect(linea)}: #{mensaje}#{token}"}
    end
  end

  @doc "Ruta del `.ex` real de `catalogo`/`tipo` — un archivo por catálogo (ya no uno por transición)."
  def ruta_disco(catalogo, tipo) when tipo in @tipos,
    do: Path.join(["lib", "metadata_app", "meta_business_process", "reglas", catalogo, "#{tipo}.ex"])

  # Guardar (persistir texto) y Compilar (dejarlo corriendo de verdad) son
  # pasos separados a propósito — eso significa que puede haber deriva: el
  # texto guardado en base ya no es igual al último `.ex` compilado a
  # disco, y el motor sigue despachando la versión vieja hasta que alguien
  # aprieta Compilar de nuevo. Sin código guardado todavía no hay nada que
  # esté "desincronizado" (las reglas no son obligatorias).
  def sincronizado?(header, tipo) when tipo in @tipos do
    case obtener(header.id, tipo) do
      nil ->
        true

      %ReglaCodigo{codigo_fuente: codigo} ->
        case File.read(ruta_disco(header.schema_context_name, tipo)) do
          {:ok, contenido} -> contenido == codigo
          {:error, _} -> false
        end
    end
  end

  @doc """
  true si PRE o POST tienen código guardado con error de sintaxis — sobre lo
  que está en base, no hace falta haber compilado. Usado para el candado de
  Guardar BC: no tiene sentido exportar un catálogo con código que ni
  siquiera parsea.
  """
  def con_error_sintaxis?(header) do
    Enum.any?(@tipos, fn tipo ->
      case obtener(header.id, tipo) do
        nil -> false
        %ReglaCodigo{codigo_fuente: codigo} -> match?({:error, _}, validar_sintaxis(codigo))
      end
    end)
  end

  @doc """
  true si PRE o POST tienen código guardado que todavía no se reflejó en lo
  compilado (ver sincronizado?/2) — solo importa en dev/test, donde existe
  "Compilar"; en producción no hay `.ex` en disco hasta el deploy, así que
  ahí esto siempre da false (nada que exigir).
  """
  def sin_compilar?(header) do
    compilar_disponible?() and Enum.any?(@tipos, &(not sincronizado?(header, &1)))
  end

  # --- Compilar (dev/test-only) / Publicar (git commit local, nunca push) ---

  def compilar_disponible?, do: Application.get_env(:metadata_app, :generar_catalogos_en_caliente, false)

  @doc """
  Compila el código YA GUARDADO de header/tipo — nunca el de un textarea
  sin guardar. Solo corre si `compilar_disponible?/0` (dev/test, mismo
  guard que `generar_catalogos_en_caliente` — un release de producción no
  tiene compilador). Escribe el `.ex` real a disco y lo carga en el BEAM
  que está corriendo ahora mismo — no hace `git commit` (ver `publicar/2`).

  Compilar solo valida que el código sea Elixir válido y cargable — NO
  valida que esté terminado. Un stub con el marcador de `pendiente?/2` sin
  tocar compila perfecto (`{:ok, modulo}`), así que un `compilar/2`
  exitoso no implica que el catálogo ya esté completo — ver
  `MetadataAppWeb.Sysadmin.BcMotorLive.puede_guardar_bc?/3`, que exige
  ambas cosas por separado.
  """
  def compilar(header, tipo) when tipo in @tipos do
    if compilar_disponible?() do
      case obtener(header.id, tipo) do
        nil -> {:error, "no hay código guardado para #{tipo} todavía"}
        %ReglaCodigo{codigo_fuente: codigo} -> compilar_codigo(header.schema_context_name, tipo, codigo)
      end
    else
      {:error, "compilar en caliente solo está disponible en dev/test — en producción se publica y se despliega como release"}
    end
  end

  defp compilar_codigo(catalogo, tipo, codigo) do
    with :ok <- validar_sintaxis(codigo) do
      ruta = ruta_disco(catalogo, tipo)
      File.mkdir_p!(Path.dirname(ruta))
      File.write!(ruta, codigo)

      try do
        [{modulo, _binario}] = Code.compile_file(ruta)
        verificar_behaviour(modulo, tipo)
      rescue
        e -> {:error, "error al compilar: #{Exception.message(e)}"}
      end
    end
  end

  defp verificar_behaviour(modulo, "pre") do
    if function_exported?(modulo, :evaluar, 3),
      do: {:ok, modulo},
      else: {:error, "#{inspect(modulo)} compiló pero no implementa evaluar/3"}
  end

  defp verificar_behaviour(modulo, "post") do
    if function_exported?(modulo, :ejecutar, 4),
      do: {:ok, modulo},
      else: {:error, "#{inspect(modulo)} compiló pero no implementa ejecutar/4"}
  end

  @doc """
  Compila (mismo chequeo que `compilar/2`) y, si sale bien, `git add` +
  `git commit` LOCAL del archivo — nunca `git push`. Mismo criterio que
  `mix motor.publicar`: publicar acá deja el commit listo, pero mandarlo a
  `origin` compartido sigue siendo una acción humana explícita.
  """
  def publicar(header, tipo) when tipo in @tipos do
    with {:ok, _modulo} <- compilar(header, tipo) do
      ruta = ruta_disco(header.schema_context_name, tipo)
      git_commit_archivo(ruta, "Reglas #{tipo} de #{header.schema_context_name}")
    end
  end

  defp git_commit_archivo(ruta, mensaje) do
    case System.cmd("git", ["add", ruta], cd: File.cwd!(), stderr_to_stdout: true) do
      {_saida, 0} ->
        case System.cmd("git", ["commit", "-m", mensaje, "--", ruta], cd: File.cwd!(), stderr_to_stdout: true) do
          {_saida, 0} ->
            :ok

          {saida, _status} ->
            if String.contains?(saida, "nothing to commit") do
              {:ok, :sin_cambios}
            else
              {:error, "git commit falló: #{saida}"}
            end
        end

      {saida, _status} ->
        {:error, "git add falló: #{saida}"}
    end
  end

  defp generar_guid do
    Ecto.UUID.generate() |> String.replace("-", "")
  end
end
