# Configuración de autenticación

Este documento separa el estado esperado actual de recomendaciones futuras. No contiene credenciales.

## Estado esperado actual

Configura manualmente Supabase Dashboard → Authentication → URL Configuration:

- **Site URL:** `https://mxbusinesscard.com`
- **Redirect URL estable:** `https://mxbusinesscard.com/`
- **Redirect temporal conservado durante la transición:** `https://digital-card-mvp-three.vercel.app/`
- **Desarrollo local:** conserva únicamente los redirects locales realmente utilizados. No uses comodines amplios.

Configura Authentication → Providers:

- Registro por email: habilitado.
- Confirmación de email: habilitada.
- Login anónimo: deshabilitado.
- Proveedores externos: deshabilitados actualmente.

Estos valores deben verificarse manualmente en cada proyecto nuevo; no están declarados por `baseline.sql`.

## Inicio de sesión y registro

El frontend usa Supabase Auth con correo y contraseña. No debe revelar si una dirección está registrada. Los errores de autorización no deben sustituirse por consultas directas a `auth.users` desde el navegador.

Un usuario nuevo debe confirmar su correo antes de poder completar operaciones que exigen una identidad elegible.

## Recuperación de contraseña

1. “¿Olvidaste tu contraseña?” llama a `resetPasswordForEmail` con redirect estable `https://mxbusinesscard.com/`.
2. El mensaje al usuario es neutral, exista o no la cuenta.
3. El frontend detecta el evento `PASSWORD_RECOVERY`, elimina parámetros sensibles de la URL y muestra el formulario de nueva contraseña.
4. La nueva contraseña requiere al menos ocho caracteres y confirmación coincidente.
5. El cambio se realiza con `updateUser` dentro de una sesión de recuperación válida.
6. Si existe una invitación pendiente en almacenamiento temporal, el flujo regresa a ella; de lo contrario carga el panel normal.

## Invitaciones

1. Owner o admin solicita la invitación desde Equipo/Miembros.
2. `organization-invitations` obtiene el actor exclusivamente con `auth.getUser(jwt)`; ignora cualquier `actor_user_id` enviado por el navegador.
3. Se genera un token aleatorio de 32 bytes, codificado en base64url sin padding. Solo se guarda SHA-256 de su representación UTF-8.
4. Resend envía un enlace bajo `https://mxbusinesscard.com`.
5. El frontend retira el token de la URL y lo conserva temporalmente: copia primaria en `sessionStorage` y respaldo en `localStorage` por un máximo de 30 minutos.
6. El destinatario inicia sesión o crea y confirma una cuenta con el mismo correo.
7. `accept_organization_invitation` valida token, correo elegible, expiración, organización, rol, plan y `max_members` antes de crear/activar la membresía.
8. El token se elimina del almacenamiento al aceptar o cancelar.

Una invitación pendiente no reserva ni consume `max_members`; la aceptación vuelve a comprobar el límite bajo lock.

## Correo de Auth

El proveedor SMTP predeterminado puede servir para pruebas limitadas, pero su entrega y límites deben verificarse. **Recomendación futura:** configurar Custom SMTP con un remitente verificado, monitoreo de rebotes y políticas SPF/DKIM/DMARC compatibles con el resto del correo del dominio.

Custom SMTP no está automatizado por este repositorio. No copies claves, passwords SMTP, tokens, DKIM privados ni enlaces de un solo uso a Git, tickets o logs.

## Comprobaciones

- Registro nuevo y recepción de confirmación.
- Confirmación y login posterior.
- Recuperación de contraseña desde el dominio canónico.
- Redirect no permitido rechazado.
- Invitación de usuario existente y nuevo.
- Token inválido, usado, expirado o revocado rechazado con mensaje genérico.
- Logout invalida el estado visible del panel.
