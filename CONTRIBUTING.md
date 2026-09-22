# Como colaborar

Gracias por el interes en MeetTracker. El repositorio es publico y cualquiera
puede proponer cambios, pero la rama `main` esta protegida: nadie escribe en
ella directamente y todo entra por pull request revisado por el mantenedor.

## Flujo

1. Haz un fork del repositorio a tu cuenta.
2. Crea una rama descriptiva: `git checkout -b arregla-captura-de-audio`.
3. Haz tus commits y pruebalos localmente.
4. Abre un pull request contra `main` de este repositorio.
5. El mantenedor (@chacknorris) revisa, comenta y decide si se mergea.

No se aceptan pushes directos a `main` ni merges sin revision aprobada.

## Requisitos para que un PR sea revisable

- `swift build` y `swift test` pasan en macOS 13 o posterior.
- El PR hace una sola cosa; si mezcla varios temas, separalo.
- Si tocas la UI, adjunta una captura.
- No incluyas secretos, tokens ni grabaciones reales. Los tokens de Hugging
  Face viven en el Keychain, nunca en el codigo.
- No subas `.build/`, `node_modules/` ni archivos de sesiones grabadas.

## Antes de trabajar en algo grande

Abre primero un issue describiendo la idea. Asi evitamos que inviertas tiempo
en un cambio que no encaja con la direccion del proyecto.

## Reportar problemas

Abre un issue con: version de macOS, pasos para reproducir, lo que esperabas y
lo que paso. Si hay logs, pegalos recortados y sin datos personales.
