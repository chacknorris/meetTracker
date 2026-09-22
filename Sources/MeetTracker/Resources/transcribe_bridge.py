#!/usr/bin/env python3
"""Local Faster Whisper + pyannote bridge for MeetTracker.

Progress events are emitted as one JSON object per stdout line. The final
transcription is written to --output so library logging cannot corrupt it.
"""

import argparse
import json
import os
import queue
import subprocess
import threading
import time
from pathlib import Path


def emit(fraction, stage, detail):
    print(
        json.dumps(
            {
                "kind": "progress",
                "fraction": max(0.0, min(1.0, float(fraction))),
                "stage": stage,
                "detail": detail,
            },
            ensure_ascii=False,
        ),
        flush=True,
    )


def timestamp(seconds):
    total = max(0, int(seconds))
    return f"{total // 60:02d}:{total % 60:02d}"


def duration_of(path):
    import av

    with av.open(str(path)) as container:
        if container.duration is not None:
            return float(container.duration) / 1_000_000.0
        durations = [
            float(stream.duration * stream.time_base)
            for stream in container.streams.audio
            if stream.duration is not None and stream.time_base is not None
        ]
        return max(durations, default=0.0)


def wav_copy(audio_path, output_path):
    if audio_path.suffix.lower() == ".wav":
        return audio_path
    ffmpeg = os.environ.get("FFMPEG_PATH", "/opt/homebrew/bin/ffmpeg")
    if not Path(ffmpeg).exists():
        ffmpeg = "ffmpeg"
    subprocess.run(
        [
            ffmpeg,
            "-nostdin",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(audio_path),
            "-ar",
            "16000",
            "-ac",
            "1",
            str(output_path),
        ],
        check=True,
    )
    return output_path


def run_with_estimated_progress(operation, duration, start, end, stage, detail):
    finished = threading.Event()
    result = {}
    failure = {}

    def worker():
        try:
            result["value"] = operation()
        except BaseException as error:
            failure["error"] = error
        finally:
            finished.set()

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    started = time.monotonic()
    # pyannote does not expose granular progress. Keep the UI alive with a
    # conservative, explicitly estimated advance capped below the stage end.
    estimate_seconds = max(45.0, duration * 0.55)
    while not finished.wait(1.0):
        elapsed = time.monotonic() - started
        ratio = min(0.94, elapsed / estimate_seconds)
        emit(start + (end - start) * ratio, stage, f"{detail} · avance estimado")
    thread.join()
    if "error" in failure:
        raise failure["error"]
    return result.get("value")


def segments_with_heartbeat(iterator, duration):
    """Yield Whisper segments while proving the native decoder is still alive."""
    messages = queue.Queue()
    completed = object()

    def worker():
        try:
            for segment in iterator:
                messages.put(("segment", segment))
        except BaseException as error:
            messages.put(("error", error))
        finally:
            messages.put(("completed", completed))

    thread = threading.Thread(target=worker, daemon=True)
    thread.start()
    last_audio_second = 0.0
    block_started = time.monotonic()

    while True:
        try:
            kind, value = messages.get(timeout=3.0)
        except queue.Empty:
            elapsed = time.monotonic() - block_started
            ratio = (last_audio_second / duration) if duration > 0 else 0
            emit(
                min(0.96, 0.49 + 0.47 * ratio),
                "Transcribiendo audio",
                (
                    "Whisper sigue calculando · "
                    f"{timestamp(last_audio_second)} de {timestamp(duration)} "
                    f"confirmados · {timestamp(elapsed)} en el bloque actual"
                ),
            )
            continue

        if kind == "error":
            raise value
        if kind == "completed":
            return

        last_audio_second = float(value.end)
        block_started = time.monotonic()
        yield value


def diarize(audio_path, wav_path, duration, num_speakers=None):
    cache_root = Path.home() / ".cache" / "torch" / "pyannote"
    required_cached_models = [
        "models--pyannote--speaker-diarization-3.1",
        "models--pyannote--segmentation-3.0",
        "models--pyannote--wespeaker-voxceleb-resnet34-LM",
    ]
    if all((cache_root / model / "refs" / "main").exists() for model in required_cached_models):
        # Avoid network probes and retry delays once every required model is local.
        os.environ.setdefault("HF_HUB_OFFLINE", "1")

    import torch
    from huggingface_hub import HfFolder
    from pyannote.audio import Pipeline

    token = os.environ.get("HF_TOKEN") or HfFolder.get_token()
    if not token:
        raise RuntimeError(
            "Falta autorizar Hugging Face para descargar/usar el modelo de diarización."
        )

    emit(0.07, "Preparando diarización", "Cargando pyannote 3.1")

    def load_pipeline():
        return Pipeline.from_pretrained(
            "pyannote/speaker-diarization-3.1",
            use_auth_token=token,
        )

    pipeline = run_with_estimated_progress(
        load_pipeline,
        duration,
        0.07,
        0.12,
        "Preparando diarización",
        "Cargando modelos locales",
    )
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))

    def identify():
        if num_speakers is not None:
            return pipeline(str(wav_path), num_speakers=num_speakers)
        return pipeline(str(wav_path))

    return run_with_estimated_progress(
        identify,
        duration,
        0.12,
        0.42,
        "Separando participantes",
        "Analizando las voces de la reunión",
    )


def speaker_turns(diarization):
    if diarization is None:
        return []
    return [
        (float(turn.start), float(turn.end), str(speaker))
        for turn, _, speaker in diarization.itertracks(yield_label=True)
    ]


def speaker_for_segment(turns, start, end):
    best_speaker = None
    best_overlap = 0.0
    for turn_start, turn_end, speaker in turns:
        overlap = max(0.0, min(end, turn_end) - max(start, turn_start))
        if overlap > best_overlap:
            best_overlap = overlap
            best_speaker = speaker
    if best_speaker is not None:
        return best_speaker

    midpoint = (start + end) / 2.0
    nearest = min(
        turns,
        key=lambda turn: min(abs(midpoint - turn[0]), abs(midpoint - turn[1])),
        default=None,
    )
    if nearest is not None:
        distance = min(abs(midpoint - nearest[0]), abs(midpoint - nearest[1]))
        if distance <= 2.0:
            return nearest[2]
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("audio")
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", default="small")
    parser.add_argument("--language")
    parser.add_argument(
        "--task",
        choices=["transcribe", "translate"],
        default="transcribe",
    )
    parser.add_argument("--diarize", action="store_true")
    parser.add_argument("--num-speakers", type=int)
    args = parser.parse_args()

    audio_path = Path(args.audio).resolve()
    output_path = Path(args.output).resolve()
    wav_path = output_path.with_suffix(".diarization.wav")
    if not audio_path.exists():
        raise FileNotFoundError(f"No se encontró el audio: {audio_path}")

    emit(0.01, "Preparando audio", "Leyendo duración y formato")
    duration = duration_of(audio_path)
    diarization = None
    try:
        if args.diarize:
            emit(0.04, "Preparando audio", "Creando copia mono a 16 kHz")
            prepared = wav_copy(audio_path, wav_path)
            diarization = diarize(
                audio_path,
                prepared,
                duration,
                num_speakers=args.num_speakers,
            )

        emit(0.43, "Cargando transcriptor", f"Whisper local ({args.model})")
        from faster_whisper import WhisperModel

        model = run_with_estimated_progress(
            lambda: WhisperModel(args.model, device="cpu", compute_type="int8"),
            duration,
            0.43,
            0.48,
            "Cargando transcriptor",
            "Preparando Faster Whisper",
        )
        emit(0.49, "Transcribiendo audio", f"0:00 de {timestamp(duration)}")
        segments_iterator, info = model.transcribe(
            str(audio_path),
            language=args.language or None,
            task=args.task,
            beam_size=5,
            vad_filter=True,
        )

        turns = speaker_turns(diarization)
        segments = []
        text_parts = []
        last_progress = 0.49
        for segment in segments_with_heartbeat(segments_iterator, duration):
            start = float(segment.start)
            end = float(segment.end)
            text = segment.text.strip()
            if not text:
                continue
            speaker = speaker_for_segment(turns, start, end)
            segments.append(
                {
                    "speaker": speaker,
                    "start": start,
                    "end": end,
                    "text": text,
                }
            )
            text_parts.append(text)
            ratio = (end / duration) if duration > 0 else 0
            progress = min(0.96, 0.49 + 0.47 * ratio)
            if progress - last_progress >= 0.002 or end >= duration - 1:
                emit(
                    progress,
                    "Transcribiendo audio",
                    f"{timestamp(end)} de {timestamp(duration)} procesados",
                )
                last_progress = progress

        emit(0.98, "Guardando resultado", f"{len(segments)} segmentos detectados")
        payload = {
            "text": " ".join(text_parts),
            "language": info.language,
            "duration": duration,
            "segments": segments,
        }
        temporary = output_path.with_suffix(output_path.suffix + ".partial")
        temporary.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
        temporary.replace(output_path)
        emit(1.0, "Listo", "Transcripción local terminada")
    finally:
        if wav_path.exists():
            wav_path.unlink()


if __name__ == "__main__":
    try:
        main()
    except BaseException as error:
        print(
            json.dumps(
                {"kind": "error", "message": str(error)},
                ensure_ascii=False,
            ),
            flush=True,
        )
        raise
