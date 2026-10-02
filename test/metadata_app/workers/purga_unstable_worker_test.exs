defmodule MetadataApp.Workers.PurgaUnstableWorkerTest do
  use ExUnit.Case, async: true

  alias MetadataApp.Workers.PurgaUnstableWorker, as: W

  @args %{"maestro" => "pty_a", "usuario_email" => "dev@x.mx", "filas_confirmadas" => 3}

  defp prep(extra \\ %{}) do
    Map.merge(%{impacto: %{"imagen_incluye" => false, "filas" => 3}, bloqueo: nil}, extra)
  end

  # Dependencias falsas: cada llamada se avisa al proceso de la prueba.
  defp deps(opts) do
    yo = self()

    %{
      primer_intento: Keyword.get(opts, :primer_intento, true),
      segundos: Keyword.get(opts, :segundos, 0),
      retirar: fn m, _email ->
        send(yo, {:retirar, m}) && Keyword.get(opts, :retirar, {:ok, %{resultado: "ok"}})
      end,
      disparar_ci: fn -> send(yo, :ci) && Keyword.get(opts, :ci, :ok) end,
      preparar: fn _m -> Keyword.get(opts, :preparar, {:ok, prep()}) end,
      purgar: fn m, _email, conf ->
        send(yo, {:purgar, m, conf}) && Keyword.get(opts, :purgar, {:ok, %{"resultado" => "ok"}})
      end,
      avisar: fn m, estado, mensaje -> send(yo, {:aviso, m, estado, mensaje}) end
    }
  end

  defp imagen_vieja,
    do: {:ok, prep(%{impacto: %{"imagen_incluye" => true}, bloqueo: "todavía incluye"})}

  test "primer_intento?/1 se basa en meta[\"snoozed\"], no en attempt (snooze le resta 1)" do
    assert W.primer_intento?(%Oban.Job{attempt: 1, meta: %{}})
    refute W.primer_intento?(%Oban.Job{attempt: 1, meta: %{"snoozed" => 1}})
  end

  test "primer intento con la imagen vieja: retira, dispara CI y espera" do
    assert {:snooze, 120} = W.paso(@args, deps(preparar: imagen_vieja()))

    assert_received {:retirar, "pty_a"}
    assert_received :ci
    assert_received {:aviso, "pty_a", :esperando_imagen, _}
    refute_received {:purgar, _, _}
  end

  test "intentos siguientes: no vuelve a retirar ni a disparar CI" do
    assert {:snooze, 120} = W.paso(@args, deps(preparar: imagen_vieja(), primer_intento: false))

    refute_received {:retirar, _}
    refute_received :ci
  end

  test "cuando la imagen ya no lo trae, purga con lo confirmado" do
    assert :ok = W.paso(@args, deps(primer_intento: false))

    assert_received {:purgar, "pty_a", %{nombre: "pty_a", filas: 3}}
    assert_received {:aviso, "pty_a", :purgado, _}
  end

  test "si la imagen ya estaba limpia desde el inicio, purga sin reconstruir" do
    assert :ok = W.paso(@args, deps([]))

    refute_received :ci
    assert_received {:aviso, "pty_a", :purgado, _}
  end

  test "si la purga falla (ej. más registros que los confirmados), termina y avisa" do
    assert :ok =
             W.paso(
               @args,
               deps(
                 primer_intento: false,
                 purgar: {:error, "tiene 5 registro(s): hay que confirmarlos"}
               )
             )

    assert_received {:aviso, "pty_a", :fallido, "tiene 5" <> _}
  end

  test "después de 45 minutos con la imagen vieja, se rinde" do
    assert :ok =
             W.paso(
               @args,
               deps(preparar: imagen_vieja(), primer_intento: false, segundos: 46 * 60)
             )

    assert_received {:aviso, "pty_a", :fallido, "Pasaron 45 minutos" <> _}
  end

  test "un bloqueo que no es la imagen (dependencias) termina sin purgar" do
    assert :ok = W.paso(@args, deps(preparar: {:ok, prep(%{bloqueo: "Hay dependencias: x"})}))
    assert_received {:aviso, "pty_a", :fallido, "Hay dependencias: x"}
    refute_received {:purgar, _, _}
  end

  test "si el retiro falla, no sigue" do
    assert :ok = W.paso(@args, deps(retirar: {:error, "No se puede retirar: pty_q"}))
    assert_received {:aviso, "pty_a", :fallido, "No se puede retirar: pty_q"}
    refute_received :ci
  end

  test "si no se puede disparar CI, avisa" do
    assert :ok = W.paso(@args, deps(preparar: imagen_vieja(), ci: {:error, "sin permisos"}))
    assert_received {:aviso, "pty_a", :fallido, "Retirado, pero no se pudo reconstruir" <> _}
  end
end
