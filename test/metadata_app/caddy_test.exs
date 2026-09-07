defmodule MetadataApp.CaddyTest do
  use ExUnit.Case, async: true

  alias MetadataApp.Caddy

  # exponer/3, leer/1 y host_expuesto?/2 necesitan SSH real -- sin
  # cobertura automática acá, mismo criterio ya establecido para
  # MotorAlta.crear_base/2 y similares. contenido_con_bloque/3 es la
  # parte pura (arma el texto nuevo del archivo), sí testeable directo.
  describe "contenido_con_bloque/3" do
    test "agrega un bloque nuevo al final cuando el host no existe todavía" do
      actual = "chat.ennovacore.com.mx {\n    reverse_proxy 172.17.0.1:30300\n}\n"

      nuevo = Caddy.contenido_con_bloque(actual, "acme.ventaenruta.com.mx", 31234)

      assert nuevo =~ "chat.ennovacore.com.mx {"
      assert nuevo =~ "acme.ventaenruta.com.mx {\n    reverse_proxy 172.17.0.1:31234\n}"
    end

    test "reemplaza el bloque previo del MISMO host en vez de duplicarlo" do
      actual = """
      metadata.ventaenruta.com.mx {
          reverse_proxy 172.17.0.1:30400
      }

      crm.ventaenruta.com.mx {
          reverse_proxy 172.17.0.1:30970
      }
      """

      nuevo = Caddy.contenido_con_bloque(actual, "metadata.ventaenruta.com.mx", 30999)

      # un solo bloque para metadata, con el nodeport nuevo -- nunca dos
      assert length(String.split(nuevo, "metadata.ventaenruta.com.mx {")) == 2
      assert nuevo =~ "reverse_proxy 172.17.0.1:30999"
      refute nuevo =~ "172.17.0.1:30400"
      # el bloque de otro host no se toca
      assert nuevo =~ "crm.ventaenruta.com.mx {\n    reverse_proxy 172.17.0.1:30970\n}"
    end

    test "un host que es prefijo de otro no se confunde (unstable vs unstable-2)" do
      actual = "unstable-2.ventaenruta.com.mx {\n    reverse_proxy 172.17.0.1:30111\n}\n"

      nuevo = Caddy.contenido_con_bloque(actual, "unstable.ventaenruta.com.mx", 30222)

      assert nuevo =~ "unstable-2.ventaenruta.com.mx {\n    reverse_proxy 172.17.0.1:30111\n}"
      assert nuevo =~ "unstable.ventaenruta.com.mx {\n    reverse_proxy 172.17.0.1:30222\n}"
    end

    # Bug real (Grupo F, 2026-09-07): "stable.ventaenruta.com.mx" es
    # substring literal de "unstable.ventaenruta.com.mx" -- sin anclar a
    # inicio de línea, agregar "stable" cortaba a mitad el bloque de
    # "unstable" ya existente y dejaba un "un" huérfano colgando.
    test "un host que es SUFIJO de otro no se confunde (stable vs unstable)" do
      actual = "unstable.ventaenruta.com.mx {\n    reverse_proxy 172.17.0.1:30314\n}\n"

      nuevo = Caddy.contenido_con_bloque(actual, "stable.ventaenruta.com.mx", 30500)

      refute nuevo =~ ~r/^un\s*$/m
      assert nuevo =~ "unstable.ventaenruta.com.mx {\n    reverse_proxy 172.17.0.1:30314\n}"
      assert nuevo =~ "stable.ventaenruta.com.mx {\n    reverse_proxy 172.17.0.1:30500\n}"
    end
  end
end
