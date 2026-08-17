# Secretos y configuración de invitaciones

Este documento enumera únicamente los nombres y el propósito de la
configuración requerida por la Edge Function `organization-invitations`.
Los valores reales no deben guardarse en Git.

## Variables

| Nombre | Propósito |
| --- | --- |
| `SUPABASE_URL` | URL API del proyecto Supabase utilizada por los clientes de la Edge Function. |
| `SUPABASE_ANON_KEY` | Clave pública usada junto con el JWT recibido para validar al usuario mediante `auth.getUser()`. |
| `SUPABASE_SERVICE_ROLE_KEY` | Credencial exclusiva del servidor usada para invocar las RPC restringidas de invitaciones y leer los campos autorizados de la organización. Nunca debe exponerse al navegador. |
| `RESEND_API_KEY` | Credencial del proveedor Resend para enviar el correo de invitación. |
| `INVITATION_FROM_EMAIL` | Dirección remitente verificada usada en los correos de invitación. |
| `INVITATION_FROM_NAME` | Nombre visible del remitente. Si falta, la versión desplegada usa `MX Business Card`. |
| `INVITATION_REPLY_TO` | Dirección opcional de respuesta. Solo se incluye cuando tiene un formato válido. |

## Dominio canónico

`https://mxbusinesscard.com`

La versión desplegada genera los enlaces de invitación exclusivamente bajo
este dominio.

## CORS desplegado

Orígenes exactos permitidos:

- `http://127.0.0.1:4173`
- `http://localhost:4173`
- `https://digital-card-mvp-three.vercel.app`
- `https://digital-card-wine.vercel.app`
- `https://mxbusinesscard.com`

También se aceptan, exclusivamente por HTTPS y sin puerto explícito, los
hostnames de Preview que coinciden con:

`^digital-card(?:-[a-z0-9-]+)?-digital-01dd\.vercel\.app$`

No se permite `Access-Control-Allow-Origin: *`.

## Autenticación

La configuración desplegada de `organization-invitations` usa:

`verify_jwt = true`

La función obtiene la identidad del actor desde el JWT validado mediante
`auth.getUser()`. Los identificadores de actor enviados por el cliente no
son aceptados.
