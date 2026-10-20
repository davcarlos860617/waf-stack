#!/usr/bin/env bash
# =============================================================================
#  Prepara una VM Linux (Ubuntu 22.04/24.04 o Debian 12) para el stack:
#    - instala Docker Engine + plugin Compose
#    - configura el firewall (22, 80, 443)
#    - crea swap si la VM tiene poca RAM
#    - crea los .env a partir de los .env.example
#
#  Uso (desde la carpeta del proyecto):   sudo bash vm/instalar.sh
# =============================================================================
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Ejecuta con sudo:  sudo bash vm/instalar.sh" >&2
  exit 1
fi

DIR_PROYECTO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USUARIO="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"

echo "==> Proyecto: $DIR_PROYECTO"
echo "==> Usuario:  $USUARIO"

# --- 1. Docker ---------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  echo "==> Docker ya está instalado: $(docker --version)"
else
  echo "==> Instalando Docker (script oficial get.docker.com)"
  apt-get update -y
  apt-get install -y ca-certificates curl
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi
systemctl enable --now docker

if [[ "$USUARIO" != "root" ]]; then
  usermod -aG docker "$USUARIO"
  echo "==> $USUARIO añadido al grupo docker (cierra y abre la sesión SSH)"
fi

# --- 2. Firewall --------------------------------------------------------------
# Nota: Docker publica puertos saltándose ufw. Por eso Grafana (3000), la
# interfaz de BunkerWeb (7000), Azurite (10000) y Fluent Bit (24224) están
# publicados solo en 127.0.0.1 en los docker-compose.yml.
if ! command -v ufw >/dev/null 2>&1; then
  apt-get install -y ufw
fi
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable
echo "==> Firewall: abiertos 22, 80, 443"

# --- 3. Swap (Loki + Grafana + MariaDB + BunkerWeb ≈ 2,5-3 GB) ----------------
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
if [[ $RAM_MB -lt 3500 ]] && ! swapon --show | grep -q .; then
  echo "==> RAM ${RAM_MB} MB: creando swap de 2 GB"
  fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# --- 4. Archivos .env ---------------------------------------------------------
for d in "$DIR_PROYECTO" "$DIR_PROYECTO/reporteria"; do
  if [[ ! -f "$d/.env" ]]; then
    cp "$d/.env.example" "$d/.env"
    echo "==> Creado $d/.env (edítalo antes de arrancar)"
  else
    echo "==> Ya existe $d/.env (no se toca)"
  fi
  chown "$USUARIO":"$USUARIO" "$d/.env" 2>/dev/null || true
  chmod 600 "$d/.env"
done
chmod +x "$DIR_PROYECTO/vm/stack.sh" "$DIR_PROYECTO/pruebas.sh" 2>/dev/null || true

IP_PUBLICA=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || echo "TU_IP_PUBLICA")

cat <<EOF

==============================================================================
 Listo. Siguientes pasos:

 1. Cierra la sesión SSH y vuelve a entrar (para usar docker sin sudo).

 2. Edita el WAF:          nano $DIR_PROYECTO/.env
      APP_DOMAIN           dominio que apunta a esta VM ($IP_PUBLICA)
      COMPOSE_PROFILES=    (vacío, para no arrancar la app de demo)
      APP_UPSTREAM         URL de tu aplicación
      APP_UPSTREAM_HOST / APP_UPSTREAM_SNI   (si es App Service u otro HTTPS)
      AUTO_LETS_ENCRYPT=yes, GENERATE_SELF_SIGNED_SSL=no, EMAIL_LETS_ENCRYPT
      Claves de la interfaz y de la base de datos

 3. Edita la reportería:   nano $DIR_PROYECTO/reporteria/.env
      Clave de Grafana y Azurite (emulador) o Azure Blob real

 4. Arranca:               bash $DIR_PROYECTO/vm/stack.sh up

 5. Grafana e interfaz de BunkerWeb, desde tu PC:
      ssh -L 3000:localhost:3000 -L 7000:localhost:7000 $USUARIO@$IP_PUBLICA
      y abre http://localhost:3000  y  http://localhost:7000
==============================================================================
EOF
