# Servicios externos

No guardes passwords, API keys, access tokens, secretos de webhook, claves privadas DKIM ni credenciales SMTP en Git.

## GitHub

- **Responsabilidad:** fuente de verdad del código y documentación.
- **Configuración necesaria:** repositorio `omargallardoc1-bit/digital-card`; rama productiva `main`; controles de acceso y protección de rama según la organización.
- **Dependencias:** Vercel obtiene el frontend desde este repositorio; los operadores despliegan Edge Functions desde el código versionado.
- **Respaldar:** repositorio completo, historial, tags/releases y reglas de rama documentadas.
- **Nunca en Git:** tokens personales, claves de despliegue privadas, secretos de Supabase/Resend/Vercel/Zoho.

## Vercel

- **Responsabilidad:** construir y servir el frontend estático y aplicar rewrites.
- **Proyecto principal:** `digital-card-mvp`.
- **Proyecto legado/duplicado:** `digital-card`.
- **Estado:** ambos están vinculados al mismo repositorio. No eliminar ninguno como parte de esta fase; cualquier consolidación requiere auditoría separada de dominios, historial y configuración.
- **Configuración necesaria:** repositorio oficial, rama `main`, `vercel.json`, dominio `mxbusinesscard.com`, TLS y despliegue desde commit aprobado.
- **Respaldar:** configuración del proyecto, dominios, variables por entorno si existieran y metadatos de deployments relevantes.
- **Nunca en Git:** tokens Vercel ni variables secretas. El frontend no debe recibir credenciales de servidor.

## Supabase

- **Responsabilidad:** Auth, PostgreSQL, RLS, RPC, Storage y Edge Functions.
- **Configuración necesaria:** baseline, seed, Auth manual, bucket/policies, secretos de funciones y `verify_jwt` según `supabase/config.toml`.
- **Dependencias:** todas las funciones dependen de URL/claves administradas; invitaciones dependen además de Resend.
- **Respaldar:** esquema versionado, configuración de Auth exportada/documentada, lista de secretos por nombre, versiones de funciones, datos mediante el mecanismo de backup apropiado y configuración del bucket.
- **Nunca en Git:** `service_role`, secret keys, JWT privados, passwords de base, tokens de usuarios ni dumps con PII.

El *project ref* de producción es `loovwrnifdimlwpfgjza`; se documenta únicamente para impedir que la baseline se ejecute allí.

## Resend

- **Responsabilidad:** envío transaccional de invitaciones de organización.
- **Configuración necesaria:** dominio/remitente verificado y los secretos enumerados en `secrets.md`.
- **Dependencias:** DNS para verificación y `organization-invitations` para generar contenido y llamar a la API.
- **Respaldar:** identidad del dominio verificado, configuración no secreta del remitente, plantillas operativas y procedimiento de rotación/revocación.
- **Nunca en Git:** `RESEND_API_KEY`, tokens, correos completos de clientes extraídos de logs ni material DKIM privado.

## Zoho

- **Responsabilidad:** correo operativo asociado al dominio. La topología exacta de buzones, alias y plan no está documentada en el repositorio.
- **Configuración necesaria:** debe verificarse manualmente en Zoho Admin; incluye cuentas y los registros de dominio que Zoho exija.
- **Dependencias:** DNS; debe coexistir sin conflicto con los registros requeridos por Resend.
- **Respaldar:** inventario de cuentas/alias sin passwords, configuración de dominio, políticas de retención y procedimiento de recuperación.
- **Nunca en Git:** passwords, app passwords, tokens OAuth, secretos SMTP ni claves DKIM privadas.

## DNS

- **Responsabilidad:** resolver `mxbusinesscard.com` hacia Vercel y autenticar/enrutar correo para Zoho y Resend.
- **Configuración necesaria:** registros web indicados por Vercel y registros MX/SPF/DKIM/DMARC confirmados por los proveedores de correo.
- **Dependencias:** Vercel, Resend y Zoho.
- **Respaldar:** exportación de zona o inventario fechado de registros, TTL y responsable del cambio.
- **Nunca en Git:** credenciales del registrador, tokens de API DNS o claves privadas DKIM.

Los valores exactos actuales de la zona DNS y la configuración Zoho no están versionados. Deben capturarse desde sus consolas antes de una reconstrucción o cambio de proveedor.
