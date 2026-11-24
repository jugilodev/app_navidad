# Navidad en familia

Aplicación web en español para organizar un amigo secreto familiar: sorteo incremental al canjear códigos privados, listas de deseos compartidas y preguntas/respuestas anónimas. La interfaz se publica como sitio estático; Supabase proporciona autenticación anónima, base de datos, políticas de acceso y una Edge Function. No hace falta un servidor propio.

## Preparar Supabase

1. Crea un proyecto en Supabase y habilita **Anonymous Sign-Ins** en Authentication → Providers → Anonymous.
2. En SQL Editor, ejecuta las migraciones `supabase/migrations/202611230001_family_secret_santa.sql`, `supabase/migrations/202611230002_admin_invites.sql`, `supabase/migrations/202611230003_multi_device_access.sql` y `supabase/migrations/202611230004_wishlist_only_member.sql`, en ese orden.
3. Ejecuta `supabase/seed.sql` una sola vez. El resultado contiene el código privado inicial de Juanene, el único administrador. Guárdalo y abre la app con ese código para gestionar las demás invitaciones desde la pestaña **Invitaciones**. Tomas tiene acceso y lista de deseos, pero no participa ni recibe asignación en el sorteo. Los participantes son Tata, Luisa, Miguel, Sofia, Federico, Sebastian y Juanene; se mantienen las restricciones Tata/Sebastian en ambos sentidos, Miguel no puede sacar a Juanene ni Sofia, y Sofia/Federico no pueden sacarse entre sí. No vuelvas a ejecutar el seed: los códigos se generan una sola vez.
4. Instala Supabase CLI, inicia sesión y enlaza el proyecto. Despliega las funciones:

   ```sh
   supabase link --project-ref TU_PROJECT_REF
   supabase functions deploy redeem
   supabase functions deploy admin-invites
   ```

   Las funciones validan la sesión anónima dentro de su código y usan la clave de servicio solo en el servidor de Supabase. Su configuración desactiva la verificación JWT del gateway para que la petición previa CORS (`OPTIONS`) pueda llegar a la función; cada petición real comprueba el JWT mediante `auth.getUser()`. No añadas `SUPABASE_SERVICE_ROLE_KEY` al frontend ni a las variables `VITE_*`.

## Invitaciones y anonimato

- Juanene inicia sesión con su código inicial y, en **Invitaciones**, crea una invitación privada para cada familiar. Puede copiar el enlace personalizado y enviárselo por WhatsApp, correo u otro medio.
- Al abrir el enlace, cada persona queda identificada y solo ve su propio resultado del sorteo. El código viaja en el fragmento privado del enlace (`#codigo=...`) y se elimina de la barra de direcciones al abrirse.
- El código no caduca por tiempo: permanece válido hasta que Juanene lo renueve. Tras canjearlo, la app lo guarda en el almacenamiento local privado de ese navegador y lo reutiliza para recuperar el acceso si la sesión anónima caduca o se invalida. En cada dispositivo hay que introducir el código al menos una vez; borrar los datos del navegador elimina la copia local.
- Solo se guarda el hash del código. La página de administración puede crear o renovar enlaces, pero no muestra asignaciones. Renovar un enlace invalida el anterior y cierra el acceso vinculado a esa persona; su asignación secreta se conserva.
- Juanene también participa y solo ve a quién le toca a él. El rol de administrador permite gestionar accesos, no leer los resultados de otras personas.
- El mismo código puede vincular sesiones anónimas en varios dispositivos de la misma persona al mismo tiempo. Cada dispositivo conserva y renueva su propia sesión; si Supabase invalida una sesión, la app intenta recuperarla con el código guardado. Si comparte el código con alguien más, esa persona también podrá entrar con esa identidad; los códigos deben mantenerse privados.
- Si pierde el acceso o hay que revocar el código, Juanene puede renovarlo; la nueva invitación invalida las sesiones anteriores, pero conserva la asignación.
- La migración `202611230004_wishlist_only_member.sql` convierte el perfil ya existente de Tomas en acceso solo para deseos. Si el sorteo anterior ya tiene resultados, conserva tantos como sea posible y reasigna únicamente las personas necesarias para retirar a Tomas; todo sucede en una transacción.

## Ejecutar localmente

```sh
npm install
Copy-Item .env.example .env.local
```

Completa `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` en `.env.local` con los datos del proyecto (Settings → API). La clave pública `anon`/`publishable` está pensada para el navegador; nunca uses la clave `service_role`.

```sh
npm run dev
```

## Publicar

Construye el sitio con `npm run build`; el resultado queda en `dist/`. Publícalo en cualquier hosting estático compatible con Vite (por ejemplo, Vercel o Netlify) y configura allí las mismas variables `VITE_SUPABASE_URL` y `VITE_SUPABASE_ANON_KEY` antes de construir. La función `redeem` y la base de datos se despliegan en Supabase independientemente del hosting.

## Privacidad y sorteo

- El primer canje de cada dispositivo vincula el código a una sesión anónima persistente y asigna una sola persona. La app conserva el código en el navegador para renovar una sesión caducada; borrar los datos locales requiere volver a introducirlo. El mismo código puede vincular más de un dispositivo.
- La asignación se elige con búsqueda aleatoria y retroceso, comprobando que las asignaciones pendientes todavía puedan completarse. Una transacción serializa canjes concurrentes, por lo que nadie recibe dos veces el mismo destinatario.
- Solo la Edge Function de Supabase puede canjear códigos o leer la asignación privada. Las listas son visibles para el grupo, pero las políticas RLS dejan que cada sesión autenticada edite únicamente las suyas.
- La vista pública de preguntas omite la identidad de quien pregunta. Solo la persona destinataria puede responder; todo el grupo puede leer preguntas y respuestas.
