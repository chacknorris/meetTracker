import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const endpoint = new URL(process.env.MEETTRACKER_MCP_URL || "http://127.0.0.1:3210/mcp");
const requestInit = process.env.MEETTRACKER_MCP_TOKEN
  ? { headers: { Authorization: `Bearer ${process.env.MEETTRACKER_MCP_TOKEN}` } }
  : undefined;
const transport = new StreamableHTTPClientTransport(endpoint, { requestInit });
const client = new Client({ name: "meettracker-check", version: "0.1.0" });

try {
  await client.connect(transport);
  const { tools } = await client.listTools();
  const response = await client.callTool({
    name: "list_meetings",
    arguments: { limit: 1 },
  });
  const meetings = Array.isArray(response.structuredContent?.meetings)
    ? response.structuredContent.meetings
    : [];

  console.log(JSON.stringify({
    status: "ok",
    endpoint: endpoint.href,
    tools: tools.map((tool) => tool.name),
    meetingReadSucceeded: !response.isError,
    meetingsReturned: meetings.length,
  }, null, 2));
} finally {
  await client.close();
}
