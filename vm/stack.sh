#!/usr/bin/env bash
# =============================================================================
#  Arranca / detiene los dos stacks en el orden correcto.
#
#  Uso:  bash vm/stack.sh up | down | restart | status | logs [servicio]
#
#  up:   primero la reportería (crea la red waf-logs), luego el WAF
#  down: primero el WAF, luego la reportería
# =============================================================================
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAF=(docker compose --project-directory "$DIR")
REP=(docker compose --project-directory "$DIR/reporteria")

for f in "$DIR/.env" "$DIR/reporteria/.env"; do
  [[ -f "$f" ]] || { echo "Falta $f  (ejecuta antes: sudo bash vm/instalar.sh)" >&2; exit 1; }
done

subir() {
  echo "==> Reportería (Loki + Grafana + Blob)"
  "${REP[@]}" up -d
  echo "==> WAF (BunkerWeb + Fluent Bit)"
  "${WAF[@]}" up -d
  estado
}

bajar() {
  echo "==> Deteniendo WAF"
  "${WAF[@]}" down
  echo "==> Deteniendo reportería"
  "${REP[@]}" down
}

estado() {
  echo
  echo "---- WAF ----"
  "${WAF[@]}" ps
  echo
  echo "---- Reportería ----"
  "${REP[@]}" ps -a
}

case "${1:-}" in
  up)      subir ;;
  down)    bajar ;;
  restart) bajar; subir ;;
  status)  estado ;;
  logs)
    shift
    if [[ $# -gt 0 ]] && "${REP[@]}" config --services | grep -qx "$1"; then
      "${REP[@]}" logs -f --tail 100 "$@"
    else
      "${WAF[@]}" logs -f --tail 100 "$@"
    fi
    ;;
  *)
    echo "Uso: bash vm/stack.sh up | down | restart | status | logs [servicio]" >&2
    exit 1
    ;;
esac
