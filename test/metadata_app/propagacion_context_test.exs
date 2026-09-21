defmodule MetadataApp.PropagacionContextTest do
  use ExUnit.Case, async: true

  alias MetadataApp.PropagacionContext

  # linea_de_tiempo/2 usa git/gh/SSH reales -- sin mock en este proyecto
  # (mismo criterio ya establecido para todo lo que depende de esos 3),
  # verificado real por separado. Acá solo la lógica pura -- "nunca
  # saltar Testing" (Grupo F) y navegación de la línea de tiempo ya
  # cargada, sin tocar red.

  describe "destino_ofrecible?/2" do
    test "testing solo si unstable ya está en ese commit" do
      assert PropagacionContext.destino_ofrecible?(%{posiciones: ["unstable"]}, "testing")
      refute PropagacionContext.destino_ofrecible?(%{posiciones: ["stable"]}, "testing")
      refute PropagacionContext.destino_ofrecible?(%{posiciones: []}, "testing")
    end

    test "stable solo si testing ya está en ese commit -- nunca salto directo desde unstable" do
      assert PropagacionContext.destino_ofrecible?(%{posiciones: ["testing"]}, "stable")
      refute PropagacionContext.destino_ofrecible?(%{posiciones: ["unstable"]}, "stable")
    end

    test "un cliente solo si stable ya está en ese commit" do
      assert PropagacionContext.destino_ofrecible?(%{posiciones: ["stable"]}, "ennova")
      refute PropagacionContext.destino_ofrecible?(%{posiciones: ["testing"]}, "ennova")
    end
  end

  describe "destinos_ofrecibles/2" do
    test "combina canales candidatos + clientes según la regla de predecesor" do
      commit = %{posiciones: ["unstable"]}
      assert PropagacionContext.destinos_ofrecibles(commit, ["ennova"]) == ["testing"]
    end

    test "un commit ya en stable ofrece stable-adyacentes: todos los clientes" do
      commit = %{posiciones: ["testing", "stable"]}
      assert PropagacionContext.destinos_ofrecibles(commit, ["ennova", "direem"]) == ["stable", "ennova", "direem"]
    end

    test "un commit sin ninguna posición no ofrece nada" do
      assert PropagacionContext.destinos_ofrecibles(%{posiciones: []}, ["ennova"]) == []
    end
  end

  describe "commit_anterior/2" do
    test "devuelve el siguiente elemento de la lista (más viejo)" do
      commits = [%{hash: "a"}, %{hash: "b"}, %{hash: "c"}]
      assert PropagacionContext.commit_anterior(commits, "a") == %{hash: "b"}
      assert PropagacionContext.commit_anterior(commits, "b") == %{hash: "c"}
    end

    test "nil si es el más viejo cargado, o si el hash no está en la lista" do
      commits = [%{hash: "a"}, %{hash: "b"}]
      assert PropagacionContext.commit_anterior(commits, "b") == nil
      assert PropagacionContext.commit_anterior(commits, "no-existe") == nil
    end
  end

  # migraciones_entre/2 corre git de verdad contra ESTE repo -- sin mock
  # (mismo criterio ya establecido). Casos estructurales, robustos sin
  # importar cómo siga creciendo la historia real (nunca hardcodeamos un
  # rango de commits real acá -- fragilizaría el test contra el futuro).
  describe "migraciones_entre/2" do
    test "el mismo commit dos veces -- rango vacío, sin migraciones" do
      assert PropagacionContext.migraciones_entre("HEAD", "HEAD") == []
    end

    test "una referencia inválida no crashea -- devuelve []" do
      assert PropagacionContext.migraciones_entre("no-existe-esta-ref", "HEAD") == []
    end
  end
end
