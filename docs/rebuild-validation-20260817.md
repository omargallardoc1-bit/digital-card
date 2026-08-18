# Validación de reconstrucción — 2026-08-17

## Alcance

- Proyecto temporal: `digital-card-rebuild-test-20260817`
- Project ref temporal: `sgrcyjiyeaqfyvhdpgjg`
- Región: `ca-central-1`
- Proyecto de producción excluido de todas las pruebas destructivas: `loovwrnifdimlwpfgjza`
- Commit final probado: `3fd19177c08cd9e7148af54069160f44612ad28e`
- Veredicto: **FINAL ACCEPTANCE PASS**
- Fecha autorizada de destrucción del laboratorio: **2026-08-17**. La eliminación se realiza únicamente después del push de este documento.

El laboratorio se creó como proyecto Supabase nuevo y desechable. No fue branch, clon, restore ni copia de producción. Solo contiene usuarios `example.test`, organizaciones y tarjetas identificadas como `REBUILD TEST`, y datos sintéticos generados durante las pruebas.

## Hashes de los artefactos probados

| Artefacto | SHA-256 |
|---|---|
| `supabase/bootstrap/baseline.sql` | `6453ed6791b95b8c54af5186af72bdc8afe3b98c48a0fe1a58832d65e044a3c9` |
| `supabase/bootstrap/seed_plans.sql` | `194d11685a157bec76bdd63eccc934dfc45ef95d5378e59edc960c5d1c92ee23` |
| `supabase/config.toml` | `72adde9227e923e0533fd95945cb253bb9c1cbb4e978e57b2877c834e029bf14` |
| `supabase/functions/create-prospect/index.ts` | `5062d4b27dd7f36339348951daa8d972251138dddb7fac4f28d3ca8e296b4168` |
| `supabase/functions/track-card-event/index.ts` | `c2e43c9ff4cf3b4ad428437c1181d0d7d79ffdd3bf886671c649cfa71ced23a0` |
| `supabase/functions/export-prospects-csv/index.ts` | `411fa3c1d4ab4fcfba0521539ab3d8e5977ffa88afa0cffd5236af23ff6ab45e` |
| `supabase/functions/organization-invitations/index.ts` | `3601296974f3b5d80966cdd8cbc4a12a59debfaa7847af8431a2d9a9068f6e8d` |

## Fases validadas

- Baseline en proyecto Supabase vacío: **PASS**.
- Seed idempotente con exactamente cuatro planes comerciales: **PASS**.
- Auth temporal y cuatro Edge Functions con `verify_jwt` esperado: **PASS**.
- Fixtures sintéticos y aislamiento RLS inicial entre dos organizaciones: **PASS**.
- Tarjetas, componentes, media, Storage y autorización cruzada: **PASS**.
- Prospectos, eventos, métricas y CSV: **PASS**.
- Miembros, roles, límites y protección del último owner: **PASS**.
- Invitaciones, reenvío, revocación, expiración, aceptación y concurrencia por el último espacio: **PASS**.
- CORS: dominio canónico y localhost permitidos; origen externo rechazado en las cuatro Edge Functions: **PASS**.
- Checklist integral de `docs/acceptance-checklist.md`: **FINAL ACCEPTANCE PASS**.

## Incidencias encontradas y correcciones

1. El preflight asumía que `supabase_migrations.schema_migrations` existía en todo proyecto nuevo. Se hizo opcional cuando el historial todavía no existe (`f7f516b`).
2. `private.get_effective_qr_plan` se creaba antes de su dependencia `private.qr_capability_enabled`. Se corrigió el orden sin cambiar lógica (`60ae9ce`).
3. `card_buttons` y `card_services` tenían grants insuficientes y autorización administrativa legacy. Se añadieron grants mínimos y policies organizacionales; la corrección fue validada en laboratorio y promovida a producción (`267a67c`).
4. Las RPC mutantes de miembros no rechazaban `caller_role = NULL`. Se hicieron fail-closed en alta, actualización y eliminación.
5. `add_organization_member_by_email` usaba el agregado inexistente `min(uuid)`. Se reemplazó por selección determinista mediante `array_agg(uuid order by uuid)[1]`, conservando la exigencia `count(*) = 1`. Ambas correcciones de miembros fueron validadas en laboratorio y promovidas a producción (`3fd1917`).
6. Los orígenes CORS canónicos se incorporaron a las Edge Functions versionadas y desplegadas sin abrir `Access-Control-Allow-Origin: *`.

## Pruebas no ejecutadas

No constituyeron fallos críticos porque requieren infraestructura externa o un frontend aislado no configurado para el laboratorio:

- Envío real de registro, confirmación y recuperación de contraseña: no se configuró SMTP.
- Entrega real de invitaciones: no se utilizó Resend productivo.
- Logout visual, consola del navegador y navegación posterior a clic: no se desplegó un frontend conectado al laboratorio.
- Renderizado y descarga visual de QR: se validaron RPC, persistencia y capacidades, no el renderizado en navegador.
- Vista visual `/c/:slug`: se validaron RLS, lectura pública, medios y signed URLs, no una instancia web del laboratorio.
- Integraciones DNS, Zoho y Vercel: no se configuraron para el proyecto temporal.

## Estado antes de destrucción

- El proyecto temporal está separado de producción y no aparece en el código del frontend.
- `index.html` apunta al project ref de producción, no al laboratorio.
- `mxbusinesscard.com` utiliza DNS administrado por Vercel y no apunta al project ref temporal.
- El laboratorio conserva únicamente fixtures sintéticos; no contiene usuarios, correos, organizaciones, tarjetas ni medios reales.
- No se configuraron secretos productivos de Resend, Vercel, Zoho o DNS.
- Producción no es objetivo de la destrucción.

## Resultado

La reconstrucción desde los artefactos versionados quedó validada. El laboratorio `sgrcyjiyeaqfyvhdpgjg` puede destruirse de forma controlada después de confirmar el push de este documento.
