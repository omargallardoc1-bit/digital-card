# Reconstrucción y despliegue

Este documento describe cómo reconstruir Digital Card en infraestructura nueva a partir del repositorio oficial. No es una guía para actualizar la base de producción existente.

## Prohibición crítica

**Nunca ejecutes `supabase/bootstrap/baseline.sql` sobre el proyecto de producción `loovwrnifdimlwpfgjza`.**

PostgreSQL no expone de forma confiable el *project ref* de Supabase. La baseline contiene preflight y postflight estructurales, pero el operador o la automatización externa debe bloquear explícitamente ese identificador antes de abrir una sesión SQL. No confíes únicamente en el preflight interno.

Tampoco ejecutes la baseline en un proyecto que ya contenga tablas, RPC, policies, bucket o historial de Digital Card. No uses las migraciones snapshot como una segunda vía de instalación después de la baseline.

## 1. Preparar un proyecto Supabase vacío

1. Crea un proyecto administrado de Supabase nuevo, con un *project ref* distinto de producción.
2. Confirma que Supabase haya inicializado los esquemas administrados `auth`, `storage`, `extensions` y `supabase_migrations`, además de los roles `anon`, `authenticated` y `service_role`.
3. Confirma que existen los helpers administrados de Storage que valida la baseline.
4. Conserva fuera de Git el *project ref*, las claves y cualquier credencial.
5. Registra por escrito que la instalación está vacía y que el *project ref* no es `loovwrnifdimlwpfgjza`.

No recrees manualmente las tablas de Auth ni Storage. Son componentes administrados por Supabase.

## 2. Instalar el esquema

1. Revisa el commit que se instalará y calcula una suma de verificación de `supabase/bootstrap/baseline.sql`.
2. Ejecuta el archivo completo en una única sesión controlada. El propio archivo abre una transacción, garantiza `pgcrypto` en `extensions`, crea el modelo, ACL, RLS, RPC, bucket y policies, ejecuta postflight y termina con `COMMIT`.
3. Si cualquier precondición o postcondición falla, conserva el error y detén la instalación. No ejecutes fragmentos aislados para “completar” el resultado.
4. Verifica que el bucket `digital-card-media` sea privado, tenga límite de 2 MiB y acepte únicamente JPEG, PNG y WebP; confirma además que no exista policy Storage `UPDATE` para navegador.

La baseline consolidada es el artefacto de instalación nueva. Los archivos de `supabase/migrations/` son snapshots históricos verificados y referencias de procedencia; no deben aplicarse encima de la baseline.

## 3. Instalar el catálogo de planes

1. Ejecuta `supabase/bootstrap/seed_plans.sql` únicamente después de que la baseline haya terminado correctamente.
2. El seed utiliza la clave estable `plans.code`, es idempotente y valida los UUID, campos y capacidades de los cuatro planes comerciales.
3. No agrega organizaciones, usuarios, suscripciones ni datos de clientes.

## 4. Configurar Supabase Auth

Configura manualmente Auth conforme a [auth.md](auth.md). Como mínimo:

- Site URL: `https://mxbusinesscard.com`.
- Redirect URL estable: `https://mxbusinesscard.com/`.
- Registro por correo y confirmación de correo habilitados.
- Login anónimo y proveedores externos deshabilitados mientras no exista una decisión explícita distinta.
- Plantillas y capacidad real de entrega de correos verificadas.

Los redirects locales deben limitarse a los entornos de desarrollo realmente utilizados. No agregues comodines amplios.

## 5. Configurar secretos de Edge Functions

Configura los nombres descritos en [secrets.md](secrets.md). Los valores se cargan mediante el mecanismo de secretos de Supabase y nunca se guardan en Git, documentación, logs ni variables públicas del navegador.

Variables administradas/usadas por las funciones:

- `SUPABASE_URL`
- `SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `RESEND_API_KEY`
- `INVITATION_FROM_EMAIL`
- `INVITATION_FROM_NAME`
- `INVITATION_REPLY_TO` (opcional)

Antes de desplegar invitaciones, el remitente de Resend debe estar verificado.

## 6. Desplegar Edge Functions

Despliega desde `supabase/functions/` y conserva exactamente `supabase/config.toml`:

| Función | `verify_jwt` | Responsabilidad |
| --- | --- | --- |
| `create-prospect` | `false` | Captura pública validada por RPC de servidor. |
| `track-card-event` | `false` | Registro público de eventos permitidos. |
| `export-prospects-csv` | `true` | Exportación autenticada y autorizada de prospectos. |
| `organization-invitations` | `true` | Crear, reenviar y revocar invitaciones y enviar correo. |

Despliega cada función individualmente y verifica estado `ACTIVE`, valor efectivo de `verify_jwt`, código desplegado y CORS. No uses `*`. El dominio canónico debe recibir preflight `204`, y un origen externo debe ser rechazado.

## 7. Crear el primer tenant

La baseline y el seed no crean datos de clientes. Este paso requiere intervención administrativa controlada:

1. Crea y confirma el primer usuario por el flujo seguro de Supabase Auth.
2. En una única transacción administrativa revisada, crea la organización inicial, su membresía `owner` activa y una suscripción al plan elegido del catálogo.
3. Toma el UUID del usuario exclusivamente de `auth.users`; no inventes identidades ni expongas `service_role` al navegador.
4. Verifica que la organización tenga al menos un owner activo, que la suscripción sea válida y que las RPC organizacionales funcionen con el usuario.

El repositorio todavía no contiene una utilidad automatizada para este bootstrap de tenant. Hasta incorporarla, el SQL concreto debe prepararse y revisarse para cada instalación, sin copiar IDs de producción.

## 8. Configurar Vercel

1. Conecta el repositorio GitHub `omargallardoc1-bit/digital-card`, rama `main`.
2. Usa `digital-card-mvp` como proyecto principal.
3. Conserva `vercel.json`; su rewrite dirige rutas sin extensión, incluida `/c/:slug`, a `index.html`.
4. Verifica que el artefacto servido corresponda al commit aprobado y que `PUBLIC_SITE_ORIGIN` siga siendo `https://mxbusinesscard.com`.
5. No copies secretos de servidor a Vercel ni al frontend. La clave publicada en el navegador debe ser únicamente una clave pública/publishable de Supabase.

Existe también el proyecto Vercel legado/duplicado `digital-card`. No lo elimines como parte de una reconstrucción sin una decisión separada.

## 9. Configurar dominio y DNS

1. Asocia `mxbusinesscard.com` al proyecto Vercel `digital-card-mvp`.
2. Aplica en el proveedor DNS únicamente los registros que Vercel indique para ese dominio y verifica emisión TLS y respuesta HTTPS.
3. No copies registros históricos sin validarlos. Los valores exactos de DNS no están versionados y requieren intervención manual.
4. Después de cualquier cambio DNS, comprueba también la entrega de correo del dominio antes de modificar registros MX, SPF, DKIM o DMARC.

## 10. Configurar Resend

1. Verifica el dominio o remitente usado por `INVITATION_FROM_EMAIL` dentro de Resend.
2. Publica únicamente los registros DNS que Resend entregue para ese dominio.
3. Carga la API key y datos del remitente como secretos de Edge Functions.
4. Envía una invitación controlada y confirma aceptación, reenvío, revocación y ausencia de tokens o PII en logs.

## 11. Configurar Zoho

Zoho forma parte de la operación de correo del dominio, pero la configuración exacta de cuentas, MX, SPF, DKIM, DMARC y alias no está versionada. Debe revisarse manualmente en la cuenta de Zoho y en DNS. No sustituyas registros existentes sin comparar las instrucciones vigentes de Zoho y Resend y resolver posibles conflictos de SPF/DKIM.

## 12. Pruebas de aceptación

Ejecuta completamente [acceptance-checklist.md](acceptance-checklist.md) con al menos dos organizaciones y usuarios distintos. Registra commit, proyecto Supabase, despliegues de funciones y despliegue Vercel probados. No promociones la instalación hasta que las pruebas de aislamiento RLS, CORS, Auth, Storage e invitaciones estén aprobadas.
