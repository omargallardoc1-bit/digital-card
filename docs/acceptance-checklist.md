# Lista de aceptación para una instalación nueva

Registra proyecto, dominio, commit y versiones de Edge Functions antes de comenzar. Usa datos de prueba identificables y elimina únicamente aquellos cuya limpieza esté prevista. Para aislamiento, prepara dos organizaciones y usuarios independientes.

## Infraestructura y seguridad

- [ ] La baseline terminó con postflight correcto en un proyecto vacío que no es producción.
- [ ] El seed contiene exactamente los cuatro planes comerciales esperados.
- [ ] Las cuatro Edge Functions están `ACTIVE` y su `verify_jwt` coincide con `supabase/config.toml`.
- [ ] `digital-card-media` es privado, limita a 2 MiB y acepta JPEG/PNG/WebP.
- [ ] Un origen externo recibe rechazo CORS; `https://mxbusinesscard.com` recibe preflight `204` con `Access-Control-Allow-Origin` exacto.
- [ ] Ningún secreto aparece en HTML, bundles, repositorio, respuestas o logs.

## Auth

- [ ] Registro por correo funciona y exige confirmación.
- [ ] Login correcto y logout limpia el estado administrativo.
- [ ] Recuperación de contraseña envía mensaje neutral, vuelve al dominio canónico y permite establecer una contraseña válida.
- [ ] Redirect no autorizado es rechazado.
- [ ] Login anónimo y proveedores externos permanecen deshabilitados.

## Organización, miembros e invitaciones

- [ ] Se muestra la organización y su suscripción efectiva.
- [ ] Owner, admin, editor y viewer tienen únicamente las acciones previstas.
- [ ] `max_members` se aplica en servidor.
- [ ] No es posible dejar una organización sin owner activo.
- [ ] Owner puede crear una invitación permitida y admin no puede invitar owner.
- [ ] El correo de invitación llega sin exponer el token en logs.
- [ ] Reenviar invalida el token anterior y revocar bloquea aceptación.
- [ ] Un usuario nuevo puede confirmar su cuenta y aceptar con el mismo correo.
- [ ] La aceptación revalida capacidad; dos aceptaciones por el último lugar no superan el límite.

## Tarjetas y componentes

- [ ] Crear tarjeta dentro de capacidad asigna organización y owner desde servidor.
- [ ] `max_cards` bloquea una creación adicional.
- [ ] Editar tarjeta usa RPC y conserva identidad, organización y slug.
- [ ] Publicar, volver a borrador, archivar y reactivar respetan plan y capacidad.
- [ ] Botones se crean/editan/eliminan y aparecen públicamente solo cuando corresponde.
- [ ] Servicios se crean/editan/eliminan y aparecen públicamente solo cuando corresponde.
- [ ] Redes sociales se crean/editan/eliminan y respetan la autorización documentada.

## Media y QR

- [ ] Foto, logo y portada válidos se comprimen, suben y se referencian mediante RPC.
- [ ] Reemplazo elimina el objeto anterior mediante Storage API después de cambiar la referencia.
- [ ] Eliminación limpia la referencia y permite limpiar un objeto pendiente no referenciado.
- [ ] MIME inválido, archivo mayor de 2 MiB, upsert y acceso no autorizado son rechazados.
- [ ] Signed URLs anónimas de medios activos de tarjeta publicada funcionan.
- [ ] Objetos huérfanos y medios de tarjetas draft/archived no son públicos.
- [ ] QR conserva `/c/<slug>?source=qr`, respeta capacidades, contraste, descarga y bloqueo de draft/archived.

## Vista pública, prospectos y eventos

- [ ] `/c/:slug` carga una tarjeta publicada sin login y rechaza draft/archived.
- [ ] Captura pública requiere consentimiento y respeta `lead_capture_enabled`.
- [ ] Origen `public_card` y `qr` se conservan correctamente.
- [ ] Crear prospecto genera exactamente un evento `lead_created` sin PII en metadata.
- [ ] View se deduplica por tarjeta/fuente durante la sesión.
- [ ] Clics permitidos registran evento sin bloquear la navegación.
- [ ] `lead_created` enviado directamente a `track-card-event` es rechazado.

## Administración y exportación

- [ ] Dashboard muestra agregados reales para 7 días, 30 días y Total limitado por plan.
- [ ] Filtro por tarjeta funciona y conversión proviene del servidor.
- [ ] Prospectos paginados respetan tarjeta, orden, máximo por página y roles con PII.
- [ ] Exportación CSV autenticada respeta plan, máximo de filas y neutraliza fórmulas.
- [ ] No existe SELECT directo desde navegador a `prospects` o `card_events`.

## Aislamiento entre organizaciones

- [ ] Usuario de organización A no puede leer tarjetas administrativas de B.
- [ ] Usuario de A no puede mutar tarjetas, componentes, media, QR, miembros o invitaciones de B.
- [ ] Usuario de A no obtiene prospectos, CSV ni métricas de B.
- [ ] Público solo lee tarjetas publicadas y sus componentes/medios activos autorizados.
- [ ] Intentos directos REST de INSERT/UPDATE/DELETE sobre tablas endurecidas son rechazados.

## Cierre

- [ ] Consola del navegador sin errores ni warnings relevantes.
- [ ] Logs de Edge Functions sin tokens, secrets ni PII innecesaria.
- [ ] Conteos antes/después explican únicamente datos creados intencionalmente.
- [ ] Se documentaron pendientes manuales de Auth, DNS, Resend y Zoho.
- [ ] El candidato aprobado corresponde al commit que se promueve.
