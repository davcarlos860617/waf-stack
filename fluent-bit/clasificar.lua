-- =============================================================================
-- Clasifica cada línea de log que llega desde Docker.
--
--   waf        -> eventos de ModSecurity (ataques detectados o bloqueados)
--   proteccion -> baneos y bloqueos de BunkerWeb (bad behavior, límites,
--                 listas negras, antibot)
--   acceso     -> log de acceso de NGINX (una línea por petición)
--   sistema    -> todo lo demás (arranque, scheduler, recargas...)
-- =============================================================================

local function contiene(texto, fragmento)
  return string.find(texto, fragmento, 1, true) ~= nil
end

-- Formato de acceso por defecto de BunkerWeb:
-- $host $remote_addr - $request_id $remote_user [$time_local] "$request" $status ...
local PATRON_ACCESO = '^%S+ %S+ %- %S+ %S+ %[[^%]]+%] "'

local MARCAS_PROTECCION = {
  "[badbehavior]", "[bad-behavior]", "[limit]", "[blacklist]",
  "[antibot]", "[dnsbl]", "[country]", "[bunkernet]", " is banned", "banned for",
}

function clasificar(tag, timestamp, record)
  local linea = record["log"]
  if type(linea) ~= "string" then
    return -1, timestamp, record            -- sin texto: se descarta
  end

  linea = string.gsub(linea, "[\r\n]+$", "")
  if linea == "" then
    return -1, timestamp, record            -- línea vacía: se descarta
  end

  local contenedor = record["container_name"] or "desconocido"
  contenedor = string.gsub(contenedor, "^/", "")

  local tipo = "sistema"
  local minusculas = string.lower(linea)

  if contiene(linea, "ModSecurity: ") then
    tipo = "waf"
  elseif string.find(linea, PATRON_ACCESO) then
    tipo = "acceso"
  else
    for _, marca in ipairs(MARCAS_PROTECCION) do
      if contiene(minusculas, marca) then
        tipo = "proteccion"
        break
      end
    end
  end

  -- 2 = registro modificado, se conserva la marca de tiempo original
  return 2, timestamp, { log = linea, contenedor = contenedor, tipo = tipo }
end
