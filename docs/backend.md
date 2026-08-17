# Arquitectura del backend

## Vista general

Digital Card es una aplicación de una sola página cuyo frontend está contenido principalmente en `index.html`. GitHub (`omargallardoc1-bit/digital-card`) es la fuente de verdad del código. La rama `main` alimenta el proyecto Vercel principal `digital-card-mvp`; el dominio canónico es `https://mxbusinesscard.com`.

Supabase proporciona Auth, PostgreSQL, RLS, RPC, Storage y Edge Functions. Resend envía invitaciones. Zoho participa en la operación de correo del dominio; su configuración exacta requiere revisión manual.

## Componentes

### Frontend

- `index.html`: UI administrativa, vista pública `/c/:slug`, autenticación, llamadas RPC, Storage, QR y módulos organizacionales.
- `vercel.json`: rewrite de rutas sin extensión a `index.html`.
- `PUBLIC_SITE_ORIGIN`: `https://mxbusinesscard.com`; se utiliza para URL pública, QR, invitaciones y recuperación de contraseña donde corresponde.
- El navegador usa una clave pública/publishable. Nunca debe contener `service_role` ni secretos de Resend.

### Datos y autorización

- PostgreSQL conserva organizaciones, miembros, suscripciones, planes, tarjetas, componentes, prospectos, eventos e invitaciones.
- RLS limita acceso directo por fila.
- Las operaciones comerciales sensibles pasan por RPC que verifican identidad, membresía, rol, plan y límites bajo locks.
- Los helpers del esquema `private` no son API para el navegador.
- Los permisos de plan provienen de `organization_subscriptions → plans`, no del nombre comercial ni de botones ocultos.

### Modelo organizacional

Relación principal:

`organization → organization_members → digital_cards`

Cada tarjeta organizacional referencia `digital_cards.organization_id`. Los permisos administrativos se derivan de una membresía activa y del rol `owner`, `admin`, `editor` o `viewer`. La creación, edición general y cambio de estado usan `create_organization_card`, `update_organization_card` y `set_card_status`.

Las invitaciones se almacenan separadamente en `organization_invitations`; el token se entrega al destinatario, pero solo su hash SHA-256 se guarda. La aceptación revalida usuario, organización, plan y límite de miembros.

### Compatibilidad histórica de `owner_id`

`digital_cards.owner_id` sigue siendo `NOT NULL` como compatibilidad transitoria e identifica al usuario histórico que creó/poseyó la tarjeta. No debe cambiarse desde el navegador. Las tarjetas nuevas reciben `owner_id = auth.uid()` y `organization_id` desde RPC de servidor.

Autorización organizacional actual:

- Lectura de tarjetas de la organización mediante `organization_id` y membresía activa.
- Creación, edición y estado mediante RPC organizacionales.
- Prospectos, métricas, QR y referencias de media validan organización, membresía y plan.
- Miembros e invitaciones se administran en el contexto de una organización.
- `card_socials` combina autorización organizacional con compatibilidad por `owner_id`.

Compatibilidad legacy que permanece:

- Policy de lectura del propietario histórico en `digital_cards`.
- `card_buttons` y `card_services` conservan policies de administración basadas en `digital_cards.owner_id`.
- `card_socials` permite rutas organizacionales, pero conserva alternativas basadas en `owner_id`.
- Los paths de Storage continúan con la forma `owner_id/card_id/{profile|logo|cover}/uuid.ext`; las policies modernas comprueban además organización, rol, plan y referencia activa.

Por ello, `owner_id` no puede eliminarse ni reinterpretarse sin una migración específica de componentes y paths. La fuente comercial y multiusuario para nuevas operaciones es `organization_id`.

### Storage

El bucket `digital-card-media` es privado, limita objetos a 2 MiB y admite JPEG, PNG y WebP. Los paths son controlados. No hay upsert ni policy `UPDATE` para navegador. Las referencias se cambian exclusivamente mediante `set_card_media_reference`; la lectura pública solo firma el objeto activo de una tarjeta publicada.

### Edge Functions

| Función | Acceso | Uso principal |
| --- | --- | --- |
| `create-prospect` | Pública, `verify_jwt=false` | Valida formato y delega la decisión comercial a `create_public_prospect`. |
| `track-card-event` | Pública, `verify_jwt=false` | Acepta eventos y fuentes permitidos sin PII innecesaria. |
| `export-prospects-csv` | Autenticada, `verify_jwt=true` | Lista por RPC y genera CSV autorizado en memoria. |
| `organization-invitations` | Autenticada, `verify_jwt=true` | Valida actor con Auth, usa RPC de servidor y envía invitaciones mediante Resend. |

Las funciones públicas siguen validando origen, método, tamaño, esquema de entrada y reglas del servidor. `service_role` solo existe dentro de funciones que lo necesitan y nunca se expone al cliente.

### Servicios externos

- GitHub: fuente de verdad y revisión de cambios.
- Vercel: hosting del frontend.
- Supabase: backend completo.
- Resend: correo transaccional de invitaciones.
- Zoho: correo operativo del dominio.
- DNS: enruta web y correo.

Consulta [external-services.md](external-services.md) para responsabilidades y respaldos.
