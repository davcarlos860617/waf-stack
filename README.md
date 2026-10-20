# WAF con BunkerWeb + reportería en Grafana con logs en Azure Blob Storage

Prototipo de Web Application Firewall autoalojado, con la reportería separada en su propio stack y los logs guardados en Azure Blob Storage.

```
TRÁFICO   Internet ──► BunkerWeb :80/:443 ──► tu aplicación (red interna, sin puertos)
                       (NGINX + ModSecurity + OWASP CRS)

LOGS      BunkerWeb ──► Fluent Bit ══(red waf-logs)══► Loki ──► Azure Blob Storage
          └──────── stack WAF ───────┘                 │        (Azurite en local)
                                                       ▼
                                                    Grafana
                                     └────────── stack reportería ──────────┘
```

**Stack WAF** (carpeta raíz):

| Servicio | Qué hace | Puerto expuesto |
|---|---|---|
| `bunkerweb` | WAF y proxy inverso | 80, 443 (público) |
| `bw-scheduler` | Guarda la configuración de BunkerWeb y se la envía | ninguno |
| `bw-ui` | Interfaz web de BunkerWeb | 7000 (solo localhost) |
| `bw-db` | MariaDB: configuración de BunkerWeb y usuarios de la interfaz | ninguno |
| `app` | Aplicación de demostración (cámbiala por la tuya) | ninguno |
| `fluent-bit` | Recibe los logs de Docker, los clasifica y los envía a Loki | 24224 (solo localhost) |

**Stack de reportería** (carpeta `reporteria/`):

| Servicio | Qué hace | Puerto expuesto |
|---|---|---|
| `loki` | Base de datos de logs; guarda los datos en Blob Storage (30 días) | ninguno |
| `grafana` | Dashboard y búsquedas | 3000 (solo localhost) |
| `blob-init` | Crea el contenedor del Blob al arrancar y termina | ninguno |
| `azurite` | Emulador de Azure Blob Storage (solo en pruebas locales) | 10000 (solo localhost) |

## Requisitos

- Docker Engine con `docker compose` v2.20 o superior (o Docker Desktop actualizado).
- 3 GB de RAM como mínimo para los dos stacks.
- Puertos 80 y 443 libres.

## Puesta en marcha

**Importante: primero la reportería y después el WAF.** La reportería crea la red `waf-logs` por la que Fluent Bit envía los logs.

### Windows (PowerShell)

Requiere Docker Desktop abierto.

```powershell
Expand-Archive .\waf-bunkerweb-grafana.zip -DestinationPath .
cd .\waf-stack

# 1. Reportería
cd .\reporteria
Copy-Item .env.example .env
notepad .env                        # cambia GRAFANA_ADMIN_PASSWORD
docker compose up -d
docker compose ps                   # loki, grafana y azurite "running"; blob-init "exited (0)"
cd ..

# 2. WAF
Copy-Item .env.example .env
notepad .env                        # cambia BW_UI_ADMIN_PASSWORD y BW_DB_PASSWORD
docker compose up -d
docker compose ps                   # 6 servicios "running"
docker compose logs -f bw-scheduler # Ctrl+C cuando termine de configurarse
```

### Linux

```bash
cd waf-stack/reporteria && cp .env.example .env && nano .env && docker compose up -d && cd ..
cp .env.example .env && nano .env && chmod +x pruebas.sh && docker compose up -d
```

La primera vez BunkerWeb tarda uno o dos minutos en generar su configuración y el certificado.

## Dónde ver cada cosa

| Qué | Dirección | Credenciales |
|---|---|---|
| Tu app protegida | https://app.localhost | — (acepta el aviso del certificado autofirmado) |
| Interfaz de BunkerWeb | http://localhost:7000 | `BW_UI_ADMIN_USER` / `BW_UI_ADMIN_PASSWORD` del `.env` del WAF |
| Grafana | http://localhost:3000 | `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` de `reporteria/.env` |

En los formularios de inicio de sesión se escribe el **valor** que va después del `=` en el `.env`, no el nombre de la variable.

## Probar el WAF

```powershell
powershell -ExecutionPolicy Bypass -File .\pruebas.ps1          # Windows
powershell -ExecutionPolicy Bypass -File .\pruebas.ps1 -Baneo   # además provoca un baneo
```

```bash
./pruebas.sh            # Linux / Mac
./pruebas.sh --baneo
```

Deberías ver `200` en las peticiones normales y `403` en los ataques. Con la opción de baneo, BunkerWeb bloquea la IP y **hasta las peticiones normales** reciben 403 durante `BAD_BEHAVIOR_BAN_TIME` segundos (5 minutos por defecto). Puedes quitar el baneo antes desde la interfaz de BunkerWeb, en **Bans**.

## Logs en Azure Blob Storage

Loki guarda los logs y su índice en un contenedor de Blob Storage (`WAF_BLOB_CONTAINER`, por defecto `loki-logs`). En el disco local de Loki solo queda lo temporal: los logs de los últimos minutos que aún no se han subido (protegidos por un registro de escritura, el WAL) y cachés.

- Un bloque de logs se sube al Blob tras **5 minutos sin líneas nuevas**, o como máximo cada hora.
- El índice se sube en ciclos de unos 15 minutos y siempre al detener Loki.
- Si borras el contenedor de Loki o su volumen después de que los datos se hayan subido, los logs siguen en el Blob y Grafana los vuelve a mostrar.

### Pruebas locales: emulador Azurite

Por defecto (`COMPOSE_PROFILES=emulador` en `reporteria/.env`) se usa **Azurite**, el emulador oficial de Microsoft. Para ver los blobs:

1. Instala [Azure Storage Explorer](https://azure.microsoft.com/products/storage/storage-explorer/) (gratis).
2. **Conectar → Emulador de almacenamiento local** (deja los valores por defecto).
3. Abre **Blob Containers → loki-logs**. Verás carpetas como `fake/` (bloques de logs) e `index/` (índice).

> La carpeta `fake/` es el nombre que Loki usa por defecto para el "inquilino" cuando no hay autenticación. Es normal.

### Pasar a Azure real

1. En el portal de Azure crea una **cuenta de almacenamiento** (Standard, LRS es suficiente).
2. En la cuenta: **Seguridad y redes → Claves de acceso → Mostrar → copia la Cadena de conexión**.
3. En `reporteria/.env`, comenta las dos líneas de la opción A y descomenta las de la opción B:
   ```
   COMPOSE_PROFILES=
   WAF_BLOB_CONNECTION_STRING=DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;EndpointSuffix=core.windows.net
   ```
4. Desde `reporteria/`:
   ```powershell
   docker compose down
   docker compose up -d
   docker compose logs blob-init       # debe decir "Contenedor creado" o "ya existía"
   ```

`blob-init` crea el contenedor en tu cuenta si no existe. Los logs que estaban en Azurite no se copian a Azure; el historial empieza de cero.

La cadena de conexión da acceso total a la cuenta: no la subas a GitHub ni la compartas. El `.env` debería estar en tu `.gitignore`.

## Grafana

El dashboard **WAF · BunkerWeb** se abre como página de inicio y muestra:

- Totales: peticiones, ataques bloqueados, detecciones del WAF y eventos de protección.
- Peticiones por código de respuesta y actividad del WAF en el tiempo.
- IPs con más bloqueos, reglas de OWASP CRS más activadas y rutas más atacadas.
- Listados de los últimos bloqueos, baneos y tráfico, con un campo **Buscar**.

Desde cualquier panel: **Inspect → Data → Download CSV** para exportar.

### Cómo se clasifican los logs

Fluent Bit (`fluent-bit/clasificar.lua`) añade la etiqueta `tipo` a cada línea:

| `tipo` | Contenido |
|---|---|
| `waf` | Mensajes de ModSecurity: `Access denied` (bloqueo) o `Warning` (regla activada) |
| `proteccion` | Baneos por mal comportamiento, límites de peticiones, listas negras |
| `acceso` | Log de acceso de NGINX, una línea por petición |
| `sistema` | Arranque, scheduler, recargas y el resto |

También añade `contenedor` (`waf-bunkerweb`, `waf-scheduler`, `waf-ui`).

### Consultas útiles (Grafana → Explore → Loki)

```logql
# Todos los bloqueos del WAF
{job="waf", tipo="waf"} |= "Access denied"

# Todo lo que hizo una IP concreta
{job="waf"} |= "203.0.113.25"

# Peticiones con error 5xx de tu aplicación
{job="waf", tipo="acceso"} | pattern `<_> <ip> - <_> <_> [<_>] "<method> <uri> <_>" <status> <_>` | status =~ "5.."

# Número de bloqueos por hora
sum(count_over_time({job="waf", tipo="waf"} |= "Access denied" [1h]))
```

## Interfaz web de BunkerWeb

En <http://localhost:7000> ves el estado de la instancia, el servicio protegido y sus ajustes, las IPs baneadas y los trabajos del scheduler.

- La página **Logs** de la interfaz aparece vacía: los logs se consultan en Grafana.
- Los ajustes definidos en `docker-compose.yml` mandan: si cambias uno desde la interfaz, vuelve al valor del compose al reiniciar el scheduler.

## Proteger tu propia aplicación

BunkerWeb puede reenviar el tráfico a una aplicación **en cualquier lugar**, no solo a un contenedor de este compose. Se configura en el `.env` del WAF:

| Dónde está tu aplicación | `COMPOSE_PROFILES` | `APP_UPSTREAM` | `APP_UPSTREAM_HOST` | `APP_UPSTREAM_SNI` |
|---|---|---|---|---|
| Demo whoami (por defecto) | `demo` | `http://app:80` | *(vacío)* | `no` |
| Contenedor tuyo en este compose | *(vacío)* | `http://miapp:3000` | *(vacío)* | `no` |
| Azure App Service | *(vacío)* | `https://miapp.azurewebsites.net` | `miapp.azurewebsites.net` | `yes` |
| Otro servidor / VM (IP privada o pública) | *(vacío)* | `http://10.0.0.5:8080` | *(vacío, o su dominio si lo exige)* | `no` |
| La misma máquina, fuera de Docker | *(vacío)* | `http://host.docker.internal:3000` | *(vacío)* | `no` |

- `APP_UPSTREAM_HOST` cambia la cabecera `Host` que llega a la aplicación. App Service (y casi cualquier hosting compartido) identifica la app por ese nombre; sin él responde 404.
- `APP_UPSTREAM_SNI=yes` es necesario cuando la aplicación es HTTPS en un servicio compartido.
- Para que nadie se salte el WAF, la aplicación debe **aceptar tráfico solo desde la IP del WAF** (App Service: *Networking → Access restrictions*; otra VM: su firewall/NSG).
- Para un contenedor propio en este compose: añádelo con `networks: [bw-services]` y **sin** `ports:`.

Después: `docker compose up -d`.

## Desplegar en una VM Linux (solo WAF + reportería)

La VM contiene BunkerWeb y toda la reportería (Fluent Bit, Loki, Grafana y Azurite o Azure Blob), todo en Docker. La aplicación vive en otro sitio.

```
Internet ──443──► VM Linux (Docker)                         ┌──► App Service / otra VM / ...
                  ├─ BunkerWeb ─────── tráfico limpio ──────┘
                  ├─ Fluent Bit ─► Loki ─► Blob (Azurite o Azure)
                  └─ Grafana / UI BunkerWeb (solo por túnel SSH)
```

**1. Crear la VM.** Ubuntu Server 24.04, mínimo 2 vCPU y 4 GB de RAM (en Azure, p. ej. `Standard_B2s`; con 2 GB funciona usando la swap que crea el instalador, pero lento). Abre en el NSG/firewall solo **22 (desde tu IP), 80 y 443**. Si vas a usar Let's Encrypt, apunta un dominio a la IP pública (en Azure sirve la etiqueta DNS gratuita: `miwaf.eastus.cloudapp.azure.com`).

**2. Copiar el proyecto e instalar.**
```bash
ssh usuario@IP_DE_LA_VM
git clone https://github.com/davcarlos860617/waf-stack.git
cd waf-stack
sudo bash vm/instalar.sh
exit            # vuelve a entrar para usar docker sin sudo
```
El instalador pone Docker, el firewall (ufw: 22, 80, 443), swap si hace falta y crea los `.env` si no existen.

**3. Configurar el WAF** (`nano .env`):
```ini
APP_DOMAIN=miwaf.eastus.cloudapp.azure.com
AUTO_LETS_ENCRYPT=yes
GENERATE_SELF_SIGNED_SSL=no
EMAIL_LETS_ENCRYPT=tu-correo@universidad.edu.co

COMPOSE_PROFILES=
APP_UPSTREAM=https://miapp.azurewebsites.net
APP_UPSTREAM_HOST=miapp.azurewebsites.net
APP_UPSTREAM_SNI=yes
```
Cambia también `BW_UI_ADMIN_PASSWORD` y `BW_DB_PASSWORD`. `LOKI_HOST`/`LOKI_PORT` se dejan igual (todo está en la misma VM).

**4. Configurar la reportería** (`nano reporteria/.env`): clave de Grafana y elige Azurite (opción A, logs en el disco de la VM) o Azure Blob real (opción B, los logs sobreviven aunque borres la VM).

**5. Arrancar.**
```bash
bash vm/stack.sh up          # reportería y luego WAF
bash vm/stack.sh status
bash vm/stack.sh logs bunkerweb
```

**6. Probar** desde tu PC: `.\pruebas.ps1 -Dominio miwaf.eastus.cloudapp.azure.com -IP IP_DE_LA_VM` (o `./pruebas.sh miwaf.eastus.cloudapp.azure.com IP_DE_LA_VM` en Linux).

**7. Ver Grafana y la interfaz de BunkerWeb** con un túnel SSH (no abras 3000 ni 7000):
```bash
ssh -L 3000:localhost:3000 -L 7000:localhost:7000 usuario@IP_DE_LA_VM
```
Y abre `http://localhost:3000` y `http://localhost:7000` en tu navegador.

**8. Cerrar la puerta trasera.** Restringe la aplicación para que solo acepte la IP pública de la VM. En App Service: *Networking → Access restrictions → Add rule → IPv4 `IP_DE_LA_VM/32`*. Comprueba que la URL directa de la app devuelve 403 y que por el dominio del WAF funciona.

Actualizar en la VM tras cambios en el repositorio: `git pull && bash vm/stack.sh up`.

## Pasar a un servidor con dominio

1. Apunta el dominio a la IP del servidor (en una VM de Azure sirve la etiqueta DNS gratuita de la IP pública, p. ej. `miwaf.eastus.cloudapp.azure.com`).
2. En el `.env` del WAF: `APP_DOMAIN=tu-dominio`, `AUTO_LETS_ENCRYPT=yes`, `GENERATE_SELF_SIGNED_SSL=no`, `EMAIL_LETS_ENCRYPT=tu-correo`.
3. Abre solo los puertos 80 y 443 (y 22 para SSH, solo desde tu IP). **No abras 3000, 7000, 10000 ni 24224.**
4. Grafana y la interfaz de BunkerWeb se ven con un túnel SSH:
   ```bash
   ssh -L 3000:localhost:3000 -L 7000:localhost:7000 usuario@IP_DEL_SERVIDOR
   ```

## Si la aplicación da falsos positivos

1. Pon `SECURITY_MODE=detect` en el `.env` del WAF y ejecuta `docker compose up -d`. BunkerWeb registra los ataques pero no los bloquea.
2. Usa la aplicación normalmente y revisa en Grafana el panel **Reglas más activadas**.
3. Desactiva las reglas que salten con tráfico legítimo para la ruta concreta (documentación de BunkerWeb, *ModSecurity → Custom configurations*).
4. Vuelve a `SECURITY_MODE=block`.

## Problemas comunes

| Síntoma | Causa probable y solución |
|---|---|
| Al levantar el WAF: `network waf-logs declared as external, but could not be found` | No has levantado la reportería. Ve a `reporteria/` y ejecuta `docker compose up -d` primero. |
| `blob-init` intenta conectarse a una cuenta que no es la del `.env` | Tienes en Windows una variable de entorno con el mismo nombre; las del sistema tienen prioridad sobre el `.env`. Por eso el proyecto usa nombres con prefijo `WAF_`. Comprueba con `docker compose config` qué valor está usando. |
| `blob-init` termina con error | Mira `docker compose logs blob-init` (en `reporteria/`). Con Azure real, revisa la cadena de conexión. |
| `loki` no arranca | `docker compose logs loki` en `reporteria/`. Si cambiaste `loki.yaml`, no escribas `${...}` ni siquiera en comentarios. |
| Grafana dice *No data* | Revisa `docker compose logs fluent-bit` (en la raíz) y `docker compose logs loki` (en `reporteria/`). |
| En Docker Desktop no llegan logs a Grafana | Cambia `fluentd-address` a `host.docker.internal:24224` en `docker-compose.yml` del WAF y ejecuta `docker compose up -d --force-recreate`. |
| `pruebas.ps1` devuelve `000` | BunkerWeb aún no arrancó o el puerto 443 está ocupado. `docker compose logs bunkerweb` |
| Todo devuelve `403`, incluso lo normal | Tu IP está baneada. Espera o desbanéala en la interfaz de BunkerWeb (**Bans**). |
| «port is already allocated» en 80 o 443 | Otro programa usa el puerto (IIS, XAMPP, otro WAF). Ciérralo o detén ese contenedor. |
| No puedo entrar a Grafana o BunkerWeb | Usa el valor del `.env`, no el nombre de la variable. Grafana: `docker compose exec grafana grafana cli admin reset-admin-password NuevaClave` (en `reporteria/`). |

## Comandos útiles

```bash
# Detener todo (primero el WAF, luego la reportería)
docker compose down
cd reporteria && docker compose down && cd ..

# Arrancar todo (primero la reportería, luego el WAF)
cd reporteria && docker compose up -d && cd ..
docker compose up -d
```

`docker compose down -v` borra también los volúmenes. En `reporteria/` con el emulador, eso **incluye los datos de Azurite**, es decir, todos los logs guardados. Con Azure real, los logs siguen en tu cuenta de almacenamiento.

## Estructura

```
waf-stack/
├── docker-compose.yml             # stack WAF
├── .env.example
├── pruebas.sh / pruebas.ps1       # pruebas de ataques (Linux / Windows)
├── vm/
│   ├── instalar.sh                # prepara una VM Linux (Docker, firewall, .env)
│   └── stack.sh                   # up/down/status/logs de los dos stacks en orden
├── fluent-bit/
│   ├── fluent-bit.conf            # entrada forward → filtro Lua → salida Loki
│   └── clasificar.lua             # etiquetas tipo y contenedor
└── reporteria/
    ├── docker-compose.yml         # stack de reportería
    ├── .env.example               # Grafana y conexión al Blob Storage
    ├── blob/crear_contenedor.py   # crea el contenedor del Blob al arrancar
    ├── loki/loki.yaml             # Loki con almacenamiento en Azure Blob
    └── grafana/
        ├── provisioning/          # conexión a Loki y carga del dashboard
        └── dashboards/waf-bunkerweb.json
```
