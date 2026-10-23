# MeetTracker

App nativa para macOS que graba, desde cualquier aplicación:

- el audio que reproduce el Mac mediante ScreenCaptureKit;
- tu voz mediante el micrófono;
- una sesión local con sus archivos y metadatos;
- una transcripción automática en español con Faster Whisper local;
- una conversación cronológica con tiempos y hablantes;
- diarización local de participantes remotos con pyannote 3.1;
- progreso por etapa, porcentaje, tiempo estimado y cancelación.

No instala un driver de audio virtual y no graba video. La captura de pantalla se
solicita porque macOS protege el acceso al audio del sistema con ese permiso.

## Requisitos

- macOS 13 o posterior
- Xcode 15 o posterior
- el proyecto hermano `../transkriptor` con su `venv` instalado;
- `ffmpeg` en `/opt/homebrew/bin/ffmpeg` para preparar el audio de pyannote;
- acceso aceptado a `pyannote/speaker-diarization-3.1` en Hugging Face.

## Ejecutar

```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open .build/MeetTracker.app
```

En el primer uso, acepta los permisos de **Micrófono** y **Grabación de pantalla
y audio del sistema**. Si macOS lo solicita, cierra y vuelve a abrir MeetTracker
después de autorizar la captura.

## Datos

Cada reunión se guarda en:

```text
~/Library/Application Support/MeetTracker/Meetings/<UUID>/
├── session.json
├── system-audio.m4a
├── microphone.m4a
├── conversation.json
└── transcript.md
```

El diseño separa la grabación de la transcripción. La app descubre
`../transkriptor/venv/bin/python` y reutiliza sus instalaciones de
`faster-whisper`, `torch` y `pyannote.audio`. Si ese entorno no está disponible,
Apple Speech queda como respaldo.

Para eliminar una reunión, usa **Eliminar…** en su detalle o **Eliminar reunión…**
en el menú contextual de la lista. La confirmación muestra el nombre y la fecha,
requiere marcar una casilla y mantiene **Cancelar** como acción predeterminada.
La carpeta completa se mueve a la Papelera de macOS, donde se pueden recuperar
sus archivos hasta vaciarla. No se permite eliminar una reunión mientras se graba,
se transcribe o termina de cancelarse su procesamiento.

En **MeetTracker > Configuración > Transcripción** se puede elegir:

- **Whisper local** o **Apple Speech**;
- modelo Whisper Tiny, Base, Small, Medium o Large v3;
- idioma conocido o detección automática;
- **Transcribir en el idioma original** o **Traducir al inglés**.

Whisper solo ofrece traducción directa hacia inglés. El modelo Small está
instalado en el entorno local actual; los demás se descargan al primer uso.

## Línea de tiempo y participantes

MeetTracker combina las marcas de tiempo del micrófono (`Yo`) con el audio del
sistema. Pyannote separa las voces remotas como `SPEAKER_00`, `SPEAKER_01`, etc.,
y la interfaz permite renombrarlas.

Para separar participantes remotos:

1. Abre **MeetTracker > Configuración** (`⌘,`).
2. Acepta las condiciones del modelo `pyannote/speaker-diarization-3.1`.
3. Guarda un token de Hugging Face si el Mac todavía no está autenticado.
4. Activa **Separar participantes remotos**.
5. Graba una reunión o presiona **Reintentar** en una existente.

El token se guarda en el Keychain de macOS. El audio se procesa localmente y no
se envía a OpenAI ni a Hugging Face. Hugging Face solo distribuye los modelos.
Los audios originales no se modifican. `transcript.md` queda ordenado por tiempo
y `conversation.json` conserva la estructura completa.

## Consultar reuniones desde ChatGPT con MCP

El servidor local y de solo lectura está en `Tools/MeetTrackerMCP`. Expone
herramientas para listar reuniones, consultar participantes y tiempos, buscar
texto y leer una conversación paginada. No permite modificar datos ni acceder a
los audios.

Se activa desde **MeetTracker > Configuración > ChatGPT**. Allí se muestra su
estado, el endpoint local y el puerto configurable. La preferencia queda guardada
y el servidor se inicia automáticamente al volver a abrir la app.

Consulta `Tools/MeetTrackerMCP/README.md` para probarlo con MCP Inspector y
conectarlo a ChatGPT Pro mediante Secure MCP Tunnel.

Durante el procesamiento se muestran la etapa actual, el porcentaje real o
estimado, el tiempo transcurrido y el tiempo restante aproximado. Se puede
cancelar sin perder los audios. Si la app se cierra, al volver a abrirla recupera
el estado como interrumpido y permite reintentar.

Cuando se conoce la cantidad de personas, selecciónala en **Personas en total**
antes de transcribir. La cifra incluye `Yo`; por ejemplo, una conversación de
dos personas limita pyannote a una sola voz remota. Si una transcripción ya
terminada dividió erróneamente a esa voz, **Corregir a 2 personas** unifica los
participantes remotos al instante, sin volver a procesar el audio.

## Atajo

MeetTracker usa una sola ventana principal. Cada vez que presionas **Grabar
nueva reunión** se crea automáticamente una sesión nueva; no se usa “Nueva
ventana”. El menú **Archivo > Iniciar nueva reunión** y `⌘⇧R` hacen lo mismo.
Durante la grabación se muestra el micrófono de entrada elegido por macOS y un
medidor de nivel; comprueba que se mueva antes de comenzar la reunión,
especialmente al usar audífonos Bluetooth.

## Pruebas

```bash
swift test
```
