#!/usr/bin/env bash
# Apunta un sistema YA existente en k3s (canal o cliente) a una imagen ya
# construida y corre sus migraciones (SPEC-ARQ-3009202602 §5).
#
# Uso: desplegar_sistema.sh <sistema> <imagen>
#
# Corre EN el servidor. Lo mandan ahí, en base64 a ~/metadata-scripts/,
# actualizar-sistema.yml (un sistema) y actualizar-lote.yml (un lote de
# clientes) en cada run -- así el servidor siempre corre la versión del
# commit del run, nunca una copia vieja que alguien dejó ahí.
#
# Mismo cuerpo exacto que antes vivía inline en actualizar-sistema.yml.
# Los gates (imagen de stable, nombres válidos) NO viven acá: cada
# workflow los aplica antes de llamar a este script.
set -e

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
  echo "Uso: $0 <sistema> <imagen>" >&2
  exit 2
fi

SISTEMA="$1"
IMAGEN="$2"

sudo k3s kubectl set image "deployment/metadata-$SISTEMA" "app=$IMAGEN" -n metadata-stack
sudo k3s kubectl rollout restart "deployment/metadata-$SISTEMA" -n metadata-stack

echo "Esperando a que el rollout converja..."
sudo k3s kubectl rollout status "deployment/metadata-$SISTEMA" -n metadata-stack --timeout=120s

# Mismo fix que bc-deploy.yml/ci.yml (2026-09-03): ordenar por
# creationTimestamp y tomar el último siempre da el pod recién
# creado por este rollout, nunca el viejo todavía Terminating.
POD=$(sudo k3s kubectl get pod -n metadata-stack -l "app=metadata-$SISTEMA" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[*].metadata.name}' | awk '{print $NF}')
if [ -z "$POD" ]; then
  echo "No se encontró el pod de metadata-$SISTEMA, no se pudo migrar"
  exit 1
fi
sudo k3s kubectl exec -n metadata-stack "$POD" -- /app/bin/setup
