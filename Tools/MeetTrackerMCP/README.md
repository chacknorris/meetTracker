# MeetTracker MCP

Servidor MCP local, de solo lectura, que permite consultar desde clientes MCP las
reuniones y transcripciones guardadas por MeetTracker. No expone ni modifica los
archivos de audio.

## Requisitos

- Node.js 20 o posterior.
- MeetTracker con al menos una reunión guardada.

## Instalar y ejecutar

```bash
cd Tools/MeetTrackerMCP
npm install
./scripts/start-local.sh
```

El lanzador usa la instalación funcional de Node 22 disponible en este Mac y
evita el enlace roto del Node instalado por Homebrew.

El servidor escucha solamente en `127.0.0.1`:

```text
http://127.0.0.1:3210/mcp
```

La comprobación local está disponible en:

```bash
curl http://127.0.0.1:3210/health
```

Para comprobar además el protocolo MCP y descubrir las herramientas:

```bash
npm run check
```

Por defecto lee:

```text
~/Library/Application Support/MeetTracker/Meetings
```

Para pruebas se puede usar otro directorio y puerto:

```bash
MEETTRACKER_MEETINGS_DIR=/ruta/de/prueba \
MEETTRACKER_MCP_PORT=3211 \
npm start
```

Opcionalmente se puede exigir un token local:

```bash
MEETTRACKER_MCP_TOKEN='un-token-largo-y-aleatorio' npm start
```

## Herramientas

- `list_meetings`: lista reuniones por título o rango de fechas.
- `get_meeting`: obtiene metadatos y participantes.
- `search_transcripts`: busca texto en todas las conversaciones.
- `get_conversation`: devuelve la conversación paginada con tiempos y hablantes.

Todas están marcadas como `readOnlyHint: true`, no acceden a rutas arbitrarias y
no devuelven audio.

## Probar con MCP Inspector

Con el servidor iniciado:

```bash
npx @modelcontextprotocol/inspector
```

Selecciona **Streamable HTTP** y usa `http://127.0.0.1:3210/mcp`.

## Conectar con ChatGPT Pro

ChatGPT no se conecta directamente a `localhost`. Para una app privada en modo
desarrollador, crea un **Secure MCP Tunnel** en OpenAI Platform y ejecuta
`tunnel-client` en este Mac apuntando a `http://127.0.0.1:3210/mcp`.

La cuenta de OpenAI Platform, su API key y los permisos del túnel son distintos
de la suscripción ChatGPT Pro. Sigue la guía vigente:

https://developers.openai.com/api/docs/guides/secure-mcp-tunnels
