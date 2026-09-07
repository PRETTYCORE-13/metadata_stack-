defmodule MetadataApp.MotorAltaActualizacionTest do
  use ExUnit.Case, async: false

  alias MetadataApp.MotorAlta

  # imagen_actual/2 (y crear_base/aplicar_manifiestos, en motor_alta_test.exs)
  # necesitan un %Ambiente{} real con SSH a un servidor de verdad -- sin
  # cobertura automática acá, mismo criterio ya establecido para esos dos.

  # PATH vacío simula "gh" no instalado o no en el PATH del proceso -- mismo
  # escenario real que MetaPublicadorTest ya cubre para disparar_deploy/3.
  # async: false porque muta la variable de entorno PATH del proceso BEAM
  # entero, no solo de este test -- módulo aparte para no arrastrar esa
  # restricción a los demás tests (async: true) de motor_alta_test.exs.
  describe "disparar_actualizacion/2 cuando gh no está en el PATH" do
    setup do
      path_original = System.get_env("PATH")
      System.put_env("PATH", "")
      on_exit(fn -> System.put_env("PATH", path_original || "") end)
      :ok
    end

    test "devuelve error legible en vez de crashear" do
      assert {:error, mensaje} = MotorAlta.disparar_actualizacion("crm", "ghcr.io/x/metadata_stack:1")
      assert mensaje =~ ~s(No se pudo ejecutar "gh")
    end
  end
end
