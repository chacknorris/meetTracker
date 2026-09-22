import { readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";

const DEFAULT_ROOT = join(
  homedir(),
  "Library",
  "Application Support",
  "MeetTracker",
  "Meetings",
);

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export class MeetingStore {
  constructor(rootDirectory = process.env.MEETTRACKER_MEETINGS_DIR || DEFAULT_ROOT) {
    this.rootDirectory = resolve(rootDirectory);
  }

  async list({ query, from, to, limit = 25 } = {}) {
    const meetings = await this.#loadAll();
    const normalizedQuery = normalize(query);
    const fromDate = parseBoundary(from, "from");
    const toDate = parseBoundary(to, "to");

    return meetings
      .filter((meeting) => {
        const startedAt = new Date(meeting.startedAt);
        if (fromDate && startedAt < fromDate) return false;
        if (toDate && startedAt > toDate) return false;
        if (!normalizedQuery) return true;
        return normalize(meeting.title).includes(normalizedQuery);
      })
      .slice(0, clamp(limit, 1, 100))
      .map(summary);
  }

  async get(id) {
    const meeting = await this.#loadSession(id);
    const conversation = await this.#loadConversation(meeting);
    return {
      ...summary(meeting),
      transcriptionState: meeting.transcriptionState ?? "notStarted",
      transcriptionProvider: meeting.transcriptionProvider ?? null,
      expectedParticipantCount: meeting.expectedParticipantCount ?? null,
      speakers: conversation ? speakerList(conversation) : [],
      segmentCount: conversation?.segments?.length ?? 0,
      hasTranscript: Boolean(meeting.transcriptFilename),
    };
  }

  async conversation(id, { offset = 0, limit = 100 } = {}) {
    const meeting = await this.#loadSession(id);
    const conversation = await this.#loadConversation(meeting);
    if (!conversation) {
      return {
        meeting: summary(meeting),
        provider: meeting.transcriptionProvider ?? null,
        speakers: [],
        segments: [],
        offset: 0,
        returned: 0,
        total: 0,
        hasMore: false,
      };
    }

    const safeOffset = clamp(offset, 0, Number.MAX_SAFE_INTEGER);
    const safeLimit = clamp(limit, 1, 200);
    const allSegments = Array.isArray(conversation.segments) ? conversation.segments : [];
    const segments = allSegments
      .slice(safeOffset, safeOffset + safeLimit)
      .map((segment) => publicSegment(segment, conversation));

    return {
      meeting: summary(meeting),
      provider: conversation.provider ?? meeting.transcriptionProvider ?? null,
      speakers: speakerList(conversation),
      segments,
      offset: safeOffset,
      returned: segments.length,
      total: allSegments.length,
      hasMore: safeOffset + segments.length < allSegments.length,
    };
  }

  async search(query, { meetingId, limit = 20 } = {}) {
    const normalizedQuery = normalize(query);
    if (!normalizedQuery) throw new Error("La búsqueda no puede estar vacía.");

    const meetings = meetingId
      ? [await this.#loadSession(meetingId)]
      : await this.#loadAll();
    const results = [];

    for (const meeting of meetings) {
      const conversation = await this.#loadConversation(meeting);
      if (!conversation) continue;

      for (const segment of conversation.segments ?? []) {
        const speakerName = displayName(segment.speakerID, conversation.speakerNames);
        const textMatches = normalize(segment.text).includes(normalizedQuery);
        const speakerMatches = normalize(speakerName).includes(normalizedQuery);
        if (!textMatches && !speakerMatches) continue;

        results.push({
          meeting: summary(meeting),
          segment: publicSegment(segment, conversation),
          snippet: snippetAround(segment.text, query),
        });
        if (results.length >= clamp(limit, 1, 100)) return results;
      }
    }

    return results;
  }

  async #loadAll() {
    let entries;
    try {
      entries = await readdir(this.rootDirectory, { withFileTypes: true });
    } catch (error) {
      if (error?.code === "ENOENT") return [];
      throw error;
    }

    const meetings = await Promise.all(
      entries
        .filter((entry) => entry.isDirectory() && UUID_PATTERN.test(entry.name))
        .map(async (entry) => {
          try {
            return await this.#readJSON(join(this.rootDirectory, entry.name, "session.json"));
          } catch {
            return null;
          }
        }),
    );

    return meetings
      .filter(Boolean)
      .filter((meeting) => UUID_PATTERN.test(meeting.id ?? ""))
      .sort((left, right) => Date.parse(right.startedAt) - Date.parse(left.startedAt));
  }

  async #loadSession(id) {
    validateMeetingId(id);
    try {
      const meeting = await this.#readJSON(join(this.rootDirectory, id, "session.json"));
      if (meeting.id?.toLowerCase() !== id.toLowerCase()) {
        throw new Error("El identificador de la carpeta no coincide con la reunión.");
      }
      return meeting;
    } catch (error) {
      if (error?.code === "ENOENT") throw new Error(`No existe la reunión ${id}.`);
      throw error;
    }
  }

  async #loadConversation(meeting) {
    if (!meeting.conversationFilename) return null;
    const allowedFilename = "conversation.json";
    if (meeting.conversationFilename !== allowedFilename) {
      throw new Error("La reunión contiene un nombre de conversación no permitido.");
    }
    try {
      return await this.#readJSON(join(this.rootDirectory, meeting.id, allowedFilename));
    } catch (error) {
      if (error?.code === "ENOENT") return null;
      throw error;
    }
  }

  async #readJSON(path) {
    return JSON.parse(await readFile(path, "utf8"));
  }
}

function validateMeetingId(id) {
  if (!UUID_PATTERN.test(id ?? "")) {
    throw new Error("El identificador de reunión debe ser un UUID válido.");
  }
}

function summary(meeting) {
  const durationSeconds = meeting.endedAt
    ? Math.max(0, Math.round((Date.parse(meeting.endedAt) - Date.parse(meeting.startedAt)) / 1000))
    : null;
  return {
    id: meeting.id,
    title: meeting.title,
    startedAt: meeting.startedAt,
    endedAt: meeting.endedAt ?? null,
    durationSeconds,
  };
}

function publicSegment(segment, conversation) {
  return {
    id: segment.id,
    speakerId: segment.speakerID,
    speaker: displayName(segment.speakerID, conversation.speakerNames),
    startSeconds: segment.startTime,
    endSeconds: segment.endTime,
    timestamp: formatTimestamp(segment.startTime),
    text: segment.text,
    source: segment.source,
  };
}

function speakerList(conversation) {
  const ids = [...new Set((conversation.segments ?? []).map((segment) => segment.speakerID))];
  ids.sort((left, right) => {
    if (left === "me") return -1;
    if (right === "me") return 1;
    return left.localeCompare(right);
  });
  return ids.map((id) => ({ id, name: displayName(id, conversation.speakerNames) }));
}

function displayName(speakerId, names = {}) {
  const customName = names?.[speakerId]?.trim();
  if (customName) return customName;
  if (speakerId === "me") return "Yo";
  if (speakerId === "meeting") return "Reunión";
  if (speakerId?.startsWith("remote-")) return `Participante ${speakerId.slice(7)}`;
  return speakerId || "Participante";
}

function normalize(value) {
  return String(value ?? "")
    .normalize("NFD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLocaleLowerCase("es")
    .trim();
}

function parseBoundary(value, label) {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) throw new Error(`La fecha '${label}' no es válida.`);
  return date;
}

function clamp(value, minimum, maximum) {
  const number = Number.isFinite(Number(value)) ? Math.trunc(Number(value)) : minimum;
  return Math.min(maximum, Math.max(minimum, number));
}

function formatTimestamp(seconds) {
  const total = Math.max(0, Math.floor(seconds ?? 0));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const remainingSeconds = total % 60;
  const compact = `${String(minutes).padStart(2, "0")}:${String(remainingSeconds).padStart(2, "0")}`;
  return hours > 0 ? `${String(hours).padStart(2, "0")}:${compact}` : compact;
}

function snippetAround(text, query, radius = 100) {
  const source = String(text ?? "");
  const position = normalize(source).indexOf(normalize(query));
  if (position < 0 || source.length <= radius * 2) return source;
  const start = Math.max(0, position - radius);
  const end = Math.min(source.length, position + String(query).length + radius);
  return `${start > 0 ? "…" : ""}${source.slice(start, end)}${end < source.length ? "…" : ""}`;
}
