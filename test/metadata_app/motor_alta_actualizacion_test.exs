defmodule MetadataApp.MotorAltaActualizacionTest do
  use ExUnit.Case, async: false

  alias MetadataApp.Ambientes.Ambiente
  alias MetadataApp.MotorAlta

  # imagen_actual/2 (y crear_base/aplicar_manifiestos, en motor_alta_test.exs)
  # necesitan un %Ambiente{} real con SSH a un servidor de verdad -- sin
  # cobertura automática acá, mismo criterio ya establecido para esos dos.
  # %Ambiente{} vacío (todos los campos nil) -- Ssh.ejecutar/2 cae en su
  # cláusula de fallback ("sin contraseña ni llave") de inmediato, SIN
  # intentar ninguna conexión SSH real -- imagen_actual/2 devuelve
  # {:error, _}, la guarda de idempotencia (R7) lo trata como "no está
  # actualizado" y sigue con el disparo normal (documentado en
  # disparar_actualizacion/3) -- lo que este test necesita para llegar a
  # ejercitar el path de "gh" sin crashear antes.
  @ambiente_vacio %Ambiente{}

  # PATH vacío simula "gh" no instalado o no en el PATH del proceso -- mismo
  # escenario real que MetaPublicadorTest ya cubre para disparar_deploy/3.
  # async: false porque muta la variable de entorno PATH del proceso BEAM
  # entero, no solo de este test -- módulo aparte para no arrastrar esa
  # restricción a los demás tests (async: true) de motor_alta_test.exs.
  describe "disparar_actualizacion/3 cuando gh no está en el PATH" do
    setup do
      path_original = System.get_env("PATH")
      System.put_env("PATH", "")
      on_exit(fn -> System.put_env("PATH", path_original || "") end)
      :ok
    end

    test "devuelve error legible en vez de crashear" do
      assert {:error, mensaje} = MotorAlta.disparar_actualizacion(@ambiente_vacio, "crm", "ghcr.io/x/metadata_stack:1")
      assert mensaje =~ ~s(No se pudo ejecutar "gh")
    end
  end

  # imagen_para_commit/1 (SPEC-ARQ-1809202603 R8) usa "gh api" contra el
  # registro real de contenedores -- sin mock (mismo criterio que el resto
  # de este archivo), verificado real por separado (Grupo D, tarea 19).
  # Acá solo cubrimos lo que no depende de red: "gh" ausente del PATH.
  describe "imagen_para_commit/1 cuando gh no está en el PATH" do
    setup do
      path_original = System.get_env("PATH")
      System.put_env("PATH", "")
      on_exit(fn -> System.put_env("PATH", path_original || "") end)
      :ok
    end

    test "devuelve error legible en vez de crashear" do
      assert {:error, mensaje} = MotorAlta.imagen_para_commit("35c43ae9d2a90269a110a64777d7e4e93b5bbe7c")
      assert mensaje =~ ~s(No se pudo ejecutar "gh")
    end
  end

  # Guarda de idempotencia (SPEC-ARQ-1809202603 R6-R7) -- fun_imagen_actual
  # inyectada para no depender de SSH real (mismo criterio que
  # MotorAlta.Estado, ver estado_test.exs).
  describe "disparar_actualizacion/4 -- guarda de idempotencia" do
    test "destino ya en la imagen pedida -- no llama a gh, devuelve :sin_cambios" do
      fun = fn _ambiente, "ennova" -> {:ok, "ghcr.io/x/metadata_stack:abc123"} end

      assert {:ok, :sin_cambios, mensaje} =
               MotorAlta.disparar_actualizacion(@ambiente_vacio, "ennova", "ghcr.io/x/metadata_stack:abc123", fun)

      assert mensaje =~ "ya está en"
    end

    test "destino en OTRA imagen -- sigue con el disparo normal (gh sin PATH acá, error esperado)" do
      path_original = System.get_env("PATH")
      System.put_env("PATH", "")

      try do
        fun = fn _ambiente, "ennova" -> {:ok, "ghcr.io/x/metadata_stack:viejo"} end

        assert {:error, mensaje} =
                 MotorAlta.disparar_actualizacion(@ambiente_vacio, "ennova", "ghcr.io/x/metadata_stack:nuevo", fun)

        assert mensaje =~ ~s(No se pudo ejecutar "gh")
      after
        System.put_env("PATH", path_original || "")
      end
    end

    test "la consulta de imagen actual falla -- sigue con el disparo normal, nunca bloquea" do
      path_original = System.get_env("PATH")
      System.put_env("PATH", "")

      try do
        fun = fn _ambiente, "ennova" -> {:error, "SSH caído"} end

        assert {:error, mensaje} = MotorAlta.disparar_actualizacion(@ambiente_vacio, "ennova", "ghcr.io/x/metadata_stack:x", fun)
        assert mensaje =~ ~s(No se pudo ejecutar "gh")
      after
        System.put_env("PATH", path_original || "")
      end
    end
  end
end
