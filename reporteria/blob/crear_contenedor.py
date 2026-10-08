"""
Crea el contenedor de Blob Storage donde Loki guarda los logs.

Loki necesita que el contenedor exista antes de arrancar. Este script se
ejecuta una vez al levantar el stack (servicio "blob-init") y funciona igual
con el emulador Azurite que con una cuenta real de Azure Storage.

Variables de entorno:
  AZURE_STORAGE_CONNECTION_STRING  cadena de conexión de la cuenta
  AZURE_CONTAINER                  nombre del contenedor (ej. loki-logs)

Solo usa la biblioteca estándar de Python (sin pip install).
"""
import base64
import hashlib
import hmac
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from email.utils import formatdate

API_VERSION = "2021-08-06"


def leer_cadena_conexion(cadena):
    partes = {}
    for trozo in cadena.strip().strip(";").split(";"):
        if "=" in trozo:
            clave, valor = trozo.split("=", 1)
            partes[clave.strip()] = valor.strip()
    for requerida in ("AccountName", "AccountKey"):
        if not partes.get(requerida):
            sys.exit(f"La cadena de conexión no tiene {requerida}.")
    if partes.get("BlobEndpoint"):
        endpoint = partes["BlobEndpoint"].rstrip("/")
    else:
        protocolo = partes.get("DefaultEndpointsProtocol", "https")
        sufijo = partes.get("EndpointSuffix", "core.windows.net")
        endpoint = f"{protocolo}://{partes['AccountName']}.blob.{sufijo}"
    return partes["AccountName"], partes["AccountKey"], endpoint


def crear_contenedor(cuenta, clave, endpoint, contenedor):
    url = f"{endpoint}/{contenedor}?restype=container"
    fecha = formatdate(usegmt=True)
    ruta = urllib.parse.urlparse(url).path  # /contenedor  o  /cuenta/contenedor (Azurite)

    # Firma "Shared Key" de Azure Storage. El Content-Type se fija a mano
    # porque Python añade uno por defecto en los PUT y debe ir en la firma.
    tipo = "application/octet-stream"
    cadena_a_firmar = "\n".join([
        "PUT",
        "", "", "", "",          # Content-Encoding, -Language, -Length (0 = vacío), -MD5
        tipo,                    # Content-Type
        "", "", "", "", "", "",  # Date, If-Modified-Since, If-Match, If-None-Match, If-Unmodified-Since, Range
        f"x-ms-date:{fecha}\nx-ms-version:{API_VERSION}",
        f"/{cuenta}{ruta}\nrestype:container",
    ])
    firma = base64.b64encode(
        hmac.new(base64.b64decode(clave), cadena_a_firmar.encode("utf-8"), hashlib.sha256).digest()
    ).decode()

    peticion = urllib.request.Request(url, method="PUT", data=b"", headers={
        "x-ms-date": fecha,
        "x-ms-version": API_VERSION,
        "Authorization": f"SharedKey {cuenta}:{firma}",
        "Content-Type": tipo,
    })
    # Sin proxy: la conexión es directa al Blob Storage
    abridor = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with abridor.open(peticion, timeout=10) as r:
            return r.status
    except urllib.error.HTTPError as e:
        if e.code == 409:  # ya existe
            return 409
        cuerpo = e.read().decode("utf-8", "replace")[:500]
        raise RuntimeError(f"HTTP {e.code}: {cuerpo}") from None


def main():
    cadena = os.environ.get("AZURE_STORAGE_CONNECTION_STRING", "")
    contenedor = os.environ.get("AZURE_CONTAINER", "loki-logs")
    if not cadena:
        sys.exit("Falta AZURE_STORAGE_CONNECTION_STRING.")

    cuenta, clave, endpoint = leer_cadena_conexion(cadena)
    print(f"Cuenta: {cuenta}  Endpoint: {endpoint}  Contenedor: {contenedor}", flush=True)

    # Azurite puede tardar unos segundos en arrancar: reintenta.
    ultimo_error = None
    for intento in range(1, 31):
        try:
            estado = crear_contenedor(cuenta, clave, endpoint, contenedor)
            if estado == 409:
                print("El contenedor ya existía. Listo.", flush=True)
            else:
                print("Contenedor creado. Listo.", flush=True)
            return
        except RuntimeError as e:
            sys.exit(f"Azure rechazó la petición: {e}")
        except (urllib.error.URLError, OSError) as e:
            ultimo_error = e
            print(f"Intento {intento}/30: sin conexión con {endpoint} ({e}). Reintentando...", flush=True)
            time.sleep(2)
    sys.exit(f"No se pudo conectar con el Blob Storage: {ultimo_error}")


if __name__ == "__main__":
    main()
