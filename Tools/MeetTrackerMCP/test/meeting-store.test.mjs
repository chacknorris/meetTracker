import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { MeetingStore } from "../src/meeting-store.mjs";

const ID = "123e4567-e89b-42d3-a456-426614174000";

test("lista reuniones y calcula la duración", async () => {
  const store = await fixtureStore();
  const meetings = await store.list();

  assert.equal(meetings.length, 1);
  assert.equal(meetings[0].id, ID);
  assert.equal(meetings[0].title, "Planificación Ástor");
  assert.equal(meetings[0].durationSeconds, 300);
});

test("busca sin distinguir mayúsculas ni tildes", async () => {
  const store = await fixtureStore();
  const results = await store.search("proxima reunion");

  assert.equal(results.length, 1);
  assert.equal(results[0].segment.speaker, "Pablo");
  assert.equal(results[0].segment.timestamp, "01:05");
});

test("pagina la conversación y conserva los hablantes", async () => {
  const store = await fixtureStore();
  const page = await store.conversation(ID, { offset: 1, limit: 1 });

  assert.equal(page.total, 2);
  assert.equal(page.returned, 1);
  assert.equal(page.hasMore, false);
  assert.equal(page.segments[0].speaker, "Pablo");
});

test("rechaza identificadores que podrían escapar del directorio", async () => {
  const store = await fixtureStore();
  await assert.rejects(() => store.get("../../etc"), /UUID válido/);
});

async function fixtureStore() {
  const root = await mkdtemp(join(tmpdir(), "meettracker-mcp-"));
  const directory = join(root, ID);
  await mkdir(directory);
  await writeFile(
    join(directory, "session.json"),
    JSON.stringify({
      id: ID,
      title: "Planificación Ástor",
      startedAt: "2026-08-04T10:00:00Z",
      endedAt: "2026-08-04T10:05:00Z",
      conversationFilename: "conversation.json",
      transcriptFilename: "transcript.md",
      transcriptionState: "completed",
      transcriptionProvider: "Whisper local + pyannote",
    }),
  );
  await writeFile(
    join(directory, "conversation.json"),
    JSON.stringify({
      provider: "Whisper local + pyannote",
      speakerNames: { me: "Yo", "remote-SPEAKER_00": "Pablo" },
      segments: [
        {
          id: "one",
          speakerID: "me",
          startTime: 10,
          endTime: 12,
          text: "Revisemos el presupuesto.",
          source: "microphone",
        },
        {
          id: "two",
          speakerID: "remote-SPEAKER_00",
          startTime: 65,
          endTime: 70,
          text: "Lo vemos en la próxima reunión.",
          source: "systemAudio",
        },
      ],
    }),
  );
  return new MeetingStore(root);
}
