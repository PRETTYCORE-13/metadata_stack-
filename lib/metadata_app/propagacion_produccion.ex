defmodule MetadataApp.PropagacionProduccion do
  @moduledoc """
  Propagación a producción de clientes, por oleadas
  (SPEC-ARQ-3009202602). Envuelve el mecanismo de un solo cliente de
  `MotorAlta` (SPEC-ARQ-1809202603); nunca lo reimplementa.

  Todo trabaja con la imagen COMPLETA (`ghcr.io/…/metadata_stack:<etiqueta>`),
  que es lo que devuelve `MotorAlta.imagen_actual/2` (design §6).
  """

  alias MetadataApp.MotorAlta

  @dependencias_default {&MotorAlta.leer_sistemas/0, &MotorAlta.imagen_actual/2}

  # R11: junto a /home/elixir/backups y /home/elixir/metadata-purgas (el
  # usuario elixir no puede escribir en /var/lib ni tiene sudo sin
  # contraseña).
  @registro "/home/elixir/metadata-propagaciones/propagaciones.jsonl"

  ## Identidad (design §1)

  @doc """
  Usuario de GitHub con el que `gh` está autenticado en esta máquina (el
  mismo que GitHub registra como quien dispara el run, y contra el que
  aplica R10). Solo para mostrarlo y anotarlo en el registro.

  `{:ok, login}` | `{:error, mensaje}`. `fun_gh` solo cambia en tests.
  """
  def identidad_actual(fun_gh \\ &gh/1) do
    case fun_gh.(["api", "user", "--jq", ".login"]) do
      {salida, 0} ->
        case String.trim(salida) do
          "" -> {:error, "gh no devolvió ningún usuario"}
          login -> {:ok, login}
        end

      {salida, _status} ->
        {:error, "no se pudo resolver la identidad de gh: #{String.trim(salida)}"}
    end
  end

  defp gh(args) do
    System.cmd("gh", args, stderr_to_stdout: true)
  rescue
    e in ErlangError -> {"no se pudo ejecutar gh (#{Exception.message(e)})", 1}
  end

  ## Registro (design §4, R11-R12)

  @doc """
  Agrega una línea JSON a `#{@registro}` en el servidor de `ambiente`.
  Solo agrega (`>>`), nunca reescribe (R11). La línea viaja en base64
  (R11a): el motivo lo escribe el usuario y nunca debe interpretarse
  como shell.

  `:ok` | `{:error, mensaje}`. `fun_ssh` solo cambia en tests.
  """
  def registrar_intento(ambiente, linea_map, fun_ssh \\ &MetadataApp.Ssh.ejecutar/2) do
    b64 = Base.encode64(Jason.encode!(linea_map) <> "\n")
    comando = "mkdir -p #{Path.dirname(@registro)} && echo #{b64} | base64 -d >> #{@registro}"

    case fun_ssh.(ambiente, comando) do
      {:ok, 0, _salida} -> :ok
      {:ok, codigo, salida} -> {:error, "no se pudo escribir el registro (código #{codigo}): #{String.trim(salida)}"}
      {:error, _} = error -> error
    end
  end

  @doc """
  Historial de `#{@registro}`, el más reciente primero. Un archivo que
  todavía no existe es una lista vacía; una línea dañada se salta sin
  romper las demás.

  `{:ok, [mapa]}` | `{:error, mensaje}`. `fun_ssh` solo cambia en tests.
  """
  def listar_intentos(ambiente, fun_ssh \\ &MetadataApp.Ssh.ejecutar/2) do
    case fun_ssh.(ambiente, "cat #{@registro} 2>/dev/null || true") do
      {:ok, 0, salida} ->
        intentos =
          salida
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn linea ->
            case Jason.decode(linea) do
              {:ok, mapa} when is_map(mapa) -> [mapa]
              _ -> []
            end
          end)
          |> Enum.reverse()

        {:ok, intentos}

      {:ok, codigo, salida} ->
        {:error, "no se pudo leer el registro (código #{codigo}): #{String.trim(salida)}"}

      {:error, _} = error ->
        error
    end
  end

  ## Elegibilidad (design §6, R2-R4b)

  @doc """
  Imagen que corre en `stable`, solo si tiene etiqueta fija (R3a): con
  `:latest`, "misma etiqueta" no significa "misma imagen", así que no se
  puede saber qué cliente está al día ni qué se le instalaría.

  `{:ok, imagen}` | `{:error, mensaje}`.

  `dependencias` -- `{fun_leer_sistemas/0, fun_imagen_actual/2}`, con
  default a las funciones reales de `MotorAlta`; parametrizable solo para
  tests (mismo criterio que `MotorAlta.Estado.consultar_todo/2`).
  """
  def imagen_stable(ambiente, dependencias \\ @dependencias_default) do
    {_fun_leer_sistemas, fun_imagen_actual} = dependencias

    case fun_imagen_actual.(ambiente, "stable") do
      {:ok, imagen} ->
        if String.ends_with?(imagen, ":latest") do
          {:error,
           "stable corre #{imagen}, una etiqueta que cambia de contenido -- propaga antes a stable " <>
             "una imagen por hash (mix motor.propagar_extension <ambiente> testing stable --commit=<hash>)."}
        else
          {:ok, imagen}
        end

      {:error, motivo} ->
        {:error, "no se pudo consultar la imagen de stable: #{motivo}"}
    end
  end

  @doc """
  Estado de cada cliente de `priv/sistemas.json` frente a `stable`
  (R2, R2a, R4, R4b):

  - `{:elegible, imagen_actual, piloto?}`
  - `{:no_elegible, :al_dia, imagen}` -- ya tiene la imagen de stable
  - `{:no_elegible, :version_fijada, version}` -- nunca elegible (R4b)
  - `{:error, motivo}` -- no se pudo consultar; no afecta a los demás

  `{:ok, imagen_stable, [{cliente, estado}]}` (ordenado por nombre) |
  `{:error, mensaje}` si stable no tiene etiqueta fija (R3a): en ese caso
  no se consulta a ningún cliente.

  Los clientes se consultan en paralelo (mismo criterio que
  `MotorAlta.Estado`): con muchos clientes, en serie multiplicaría la
  espera por SSH.
  """
  def elegibles(ambiente, dependencias \\ @dependencias_default) do
    {fun_leer_sistemas, fun_imagen_actual} = dependencias

    with {:ok, imagen_stable} <- imagen_stable(ambiente, dependencias) do
      clientes =
        fun_leer_sistemas.()
        |> Enum.filter(fn {_nombre, datos} -> Map.get(datos, "activo", true) end)
        |> Enum.sort_by(&elem(&1, 0))

      lista =
        clientes
        |> Task.async_stream(
          fn {nombre, datos} -> {nombre, estado(ambiente, nombre, datos, imagen_stable, fun_imagen_actual)} end,
          timeout: 30_000,
          on_timeout: :kill_task
        )
        |> Enum.zip(clientes)
        |> Enum.map(fn
          {{:ok, resultado}, _} -> resultado
          {{:exit, _}, {nombre, _}} -> {nombre, {:error, "timeout consultando este cliente"}}
        end)

      {:ok, imagen_stable, lista}
    end
  end

  defp estado(ambiente, nombre, datos, imagen_stable, fun_imagen_actual) do
    case Map.get(datos, "version_fijada") do
      fijada when fijada not in [nil, ""] ->
        {:no_elegible, :version_fijada, fijada}

      _ ->
        case fun_imagen_actual.(ambiente, nombre) do
          {:ok, ^imagen_stable} -> {:no_elegible, :al_dia, imagen_stable}
          {:ok, otra} -> {:elegible, otra, Map.get(datos, "piloto", false) == true}
          {:error, motivo} -> {:error, motivo}
        end
    end
  rescue
    e -> {:error, "excepción consultando #{nombre}: #{Exception.message(e)}"}
  end
end
