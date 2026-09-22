import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { createMcpExpressApp } from "@modelcontextprotocol/sdk/server/express.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { MeetingStore } from "./meeting-store.mjs";

const host = process.env.MEETTRACKER_MCP_HOST || "127.0.0.1";
const port = parsePort(process.env.MEETTRACKER_MCP_PORT || "3210");
const store = new MeetingStore();
const app = createMcpExpressApp({ host });

app.get("/health", (_request, response) => {
  response.json({
    status: "ok",
    service: "meettracker-mcp",
    meetingsDirectory: store.rootDirectory,
  });
});

app.post("/mcp", async (request, response) => {
  if (!isAuthorized(request)) {
    response.setHeader("WWW-Authenticate", 'Bearer realm="meettracker-mcp"');
    response.status(401).json({ error: "No autorizado" });
    return;
  }

  const mcpServer = createMeetTrackerServer(store);
  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: undefined,
  });

  try {
    await mcpServer.connect(transport);
    await transport.handleRequest(request, response, request.body);
    response.on("close", async () => {
      await transport.close();
      await mcpServer.close();
    });
  } catch (error) {
    console.error("Error procesando una solicitud MCP:", error);
    if (!response.headersSent) {
      response.status(500).json({
        jsonrpc: "2.0",
        error: { code: -32603, message: "Error interno del servidor" },
        id: null,
      });
    }
  }
});

for (const method of ["get", "delete"]) {
  app[method]("/mcp", (_request, response) => {
    response.status(405).json({
      jsonrpc: "2.0",
      error: { code: -32000, message: "Método no permitido" },
      id: null,
    });
  });
}

const httpServer = app.listen(port, host, () => {
  console.error(`MeetTracker MCP escuchando en http://${host}:${port}/mcp`);
  console.error(`Datos: ${store.rootDirectory}`);
});

httpServer.on("error", (error) => {
  console.error("No fue posible iniciar MeetTracker MCP:", error);
  process.exitCode = 1;
});

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    httpServer.close(() => process.exit(0));
  });
}

function createMeetTrackerServer(meetingStore) {
  const server = new McpServer(
    { name: "meettracker", version: "0.1.0" },
    {
      instructions:
        "Servidor local y de solo lectura para reuniones de MeetTracker. Usa list_meetings para descubrir IDs, search_transcripts para localizar conversaciones y get_conversation para leer segmentos paginados. Nunca expone los archivos de audio.",
    },
  );

  const readOnlyAnnotations = {
    readOnlyHint: true,
    destructiveHint: false,
    openWorldHint: false,
  };

  server.registerTool(
    "list_meetings",
    {
      title: "Listar reuniones",
      description: "Lista las reuniones guardadas en MeetTracker, opcionalmente filtradas por título y fechas.",
      inputSchema: {
        query: z.string().trim().min(1).optional().describe("Texto incluido en el título."),
        from: z.string().datetime({ offset: true }).optional().describe("Fecha inicial ISO 8601."),
        to: z.string().datetime({ offset: true }).optional().describe("Fecha final ISO 8601."),
        limit: z.number().int().min(1).max(100).default(25),
      },
      annotations: readOnlyAnnotations,
    },
    async (input) => {
      const meetings = await meetingStore.list(input);
      return result({ meetings, count: meetings.length });
    },
  );

  server.registerTool(
    "get_meeting",
    {
      title: "Obtener reunión",
      description: "Obtiene los metadatos, participantes y estado de una reunión por su UUID.",
      inputSchema: {
        meetingId: z.string().uuid().describe("UUID entregado por list_meetings."),
      },
      annotations: readOnlyAnnotations,
    },
    async ({ meetingId }) => result(await meetingStore.get(meetingId)),
  );

  server.registerTool(
    "search_transcripts",
    {
      title: "Buscar en transcripciones",
      description: "Busca texto o nombres de participantes dentro de una reunión o en todas las reuniones.",
      inputSchema: {
        query: z.string().trim().min(1).describe("Texto que se desea encontrar."),
        meetingId: z.string().uuid().optional().describe("UUID opcional para limitar la búsqueda."),
        limit: z.number().int().min(1).max(100).default(20),
      },
      annotations: readOnlyAnnotations,
    },
    async ({ query, meetingId, limit }) => {
      const matches = await meetingStore.search(query, { meetingId, limit });
      return result({ query, matches, count: matches.length });
    },
  );

  server.registerTool(
    "get_conversation",
    {
      title: "Leer conversación",
      description: "Devuelve la conversación cronológica de una reunión, con tiempos y hablantes, en páginas de hasta 200 segmentos.",
      inputSchema: {
        meetingId: z.string().uuid().describe("UUID entregado por list_meetings."),
        offset: z.number().int().min(0).default(0).describe("Índice del primer segmento."),
        limit: z.number().int().min(1).max(200).default(100),
      },
      annotations: readOnlyAnnotations,
    },
    async ({ meetingId, offset, limit }) => result(
      await meetingStore.conversation(meetingId, { offset, limit }),
    ),
  );

  return server;
}

function result(structuredContent) {
  return {
    structuredContent,
    content: [{ type: "text", text: JSON.stringify(structuredContent, null, 2) }],
  };
}

function isAuthorized(request) {
  const expectedToken = process.env.MEETTRACKER_MCP_TOKEN;
  if (!expectedToken) return true;
  return request.headers.authorization === `Bearer ${expectedToken}`;
}

function parsePort(value) {
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65535) {
    throw new Error("MEETTRACKER_MCP_PORT debe ser un puerto válido.");
  }
  return parsed;
}
