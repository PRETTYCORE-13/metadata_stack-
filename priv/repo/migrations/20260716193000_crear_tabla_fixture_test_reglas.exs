defmodule MetadataApp.Repo.Migrations.CrearTablaFixtureTestReglas do
  use Ecto.Migration

  # Fixture pura para test/metadata_app/meta_state_engine/reglas_test.exs —
  # Pre.sin_relacionados/Post.mutar_relacionados necesitan "alguna otra
  # tabla" con una columna que apunte de vuelta al registro bajo prueba.
  # Deliberadamente fuera del namespace pty_/meta_business_process: no es un
  # catálogo del Business Process Builder (sin Header, no aparece en BC
  # List) — es infraestructura de test, para no volver a acoplar un test de
  # mecánica genérica a un catálogo de negocio real que puede borrarse (ya
  # pasó una vez con pty_canal).
  def change do
    create table(:test_fixture_relacionado) do
      add :nombre, :string
      add :orden, :integer
    end
  end
end
