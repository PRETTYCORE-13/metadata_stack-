# Guardarraíl SDD (ver AGENTS.md, "SDD obligatorio"): hook PreToolUse de
# Claude Code que bloquea Edit/Write sobre código si no hay una SPEC
# aprobada declarada en .claude/spec-activa.
#
# .claude/spec-activa (una sola línea, ignorado por git, por desarrollador):
#   docs/specs/SPEC-SYS-2909202601-algo  -> la SPEC debe existir y tener 03.tasks.md
#   hotfix                               -> excepción explícita autorizada por el usuario
#
# Exit 2 = bloquea la herramienta y le devuelve el mensaje de stderr a Claude.
# En Elixir y no en bash/PowerShell para correr igual en Windows nativo y
# en el devcontainer (Linux) sin depender de jq.

defmodule RequiereSpec do
  @protegidas ["lib/", "priv/repo/migrations/", "assets/", "test/"]

  def main do
    with {:ok, entrada} <- leer_entrada(),
         ruta when is_binary(ruta) <- get_in(entrada, ["tool_input", "file_path"]),
         raiz when is_binary(raiz) <- System.get_env("CLAUDE_PROJECT_DIR") || entrada["cwd"],
         {:ok, relativa} <- ruta_relativa(ruta, raiz),
         true <- protegida?(relativa) do
      verificar_spec(raiz, relativa)
    else
      _ -> System.halt(0)
    end
  end

  defp leer_entrada do
    case IO.read(:stdio, :eof) do
      datos when is_binary(datos) -> datos |> String.trim_leading("﻿") |> JSON.decode()
      _ -> :error
    end
  end

  defp ruta_relativa(ruta, raiz) do
    raiz = normalizar(raiz)
    completa = normalizar(ruta)

    if String.starts_with?(completa, raiz <> "/") do
      {:ok, String.replace_prefix(completa, raiz <> "/", "")}
    else
      :fuera_del_proyecto
    end
  end

  # Windows: barras invertidas y mayúsculas/minúsculas en la unidad
  # ("c:\\" vs "C:\\") no deben cambiar el resultado.
  defp normalizar(ruta) do
    ruta
    |> String.replace("\\", "/")
    |> Path.expand()
    |> String.trim_trailing("/")
    |> then(fn r -> if match?({:win32, _}, :os.type()), do: String.downcase(r), else: r end)
  end

  defp protegida?(relativa), do: Enum.any?(@protegidas, &String.starts_with?(relativa, &1))

  defp verificar_spec(raiz, relativa) do
    marca = Path.join(raiz, ".claude/spec-activa")

    case File.read(marca) do
      {:error, _} ->
        bloquear(
          "no se puede editar '#{relativa}' sin una SPEC aprobada. Documenta primero con la " <>
            "skill 'spec' y, ya aprobada por el usuario, declara la ruta de la SPEC en " <>
            ".claude/spec-activa (o 'hotfix' si el usuario lo autoriza explícitamente)."
        )

      {:ok, contenido} ->
        valor = contenido |> String.split(["\r\n", "\n"]) |> hd() |> String.trim() |> String.trim_trailing("/")

        cond do
          valor == "hotfix" ->
            System.halt(0)

          String.starts_with?(valor, "docs/specs/SPEC-") ->
            if File.exists?(Path.join([raiz, valor, "03.tasks.md"])) do
              System.halt(0)
            else
              bloquear(
                ".claude/spec-activa apunta a '#{valor}', pero no existe o no tiene 03.tasks.md. " <>
                  "Termina y haz aprobar la SPEC antes de programar."
              )
            end

          true ->
            bloquear(
              ".claude/spec-activa tiene un valor inválido ('#{valor}'). Debe ser la ruta " <>
                "docs/specs/SPEC-... o 'hotfix'."
            )
        end
    end
  end

  defp bloquear(motivo) do
    IO.puts(:stderr, "BLOQUEADO (SDD): " <> motivo)
    System.halt(2)
  end
end

RequiereSpec.main()
