# Navidad en familia

Aplicación web en español para organizar un amigo secreto familiar: sorteo incremental al canjear códigos privados, listas de deseos compartidas y preguntas/respuestas anónimas. La interfaz se publica como sitio estático; Supabase proporciona autenticación anónima, base de datos, políticas de acceso y una Edge Function. No hace falta un servidor propio.

## Preparar Supabase

1. Crea un proyecto en Supabase y habilita **Anonymous Sign-Ins** en Authentication → Providers → Anonymous.
2. En SQL Editor, ejecuta las migraciones `supabase/migrations/202611230001_family_secret_santa.sql` y `supabase/migrations/202611230002_admin_invites.sql`, en ese orden.
3. Ejecuta `supabase/seed.sql` una sola vez. El resultado contiene el código privado inicial de Juanene, el único administrador. Guárdalo y abre la app con ese código para gestionar las demás invitaciones desde la pestaña **Invitaciones**. El seed ya configura estas exclusiones: Tata/Sebastian en ambos sentidos, Miguel no puede sacar a Juanene, Sofia ni Tomas, y Sofia/Federico no pueden sacarse entre sí. No vuelvas a ejecutar el seed: los códigos se generan una sola vez.
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
- Solo se guarda el hash del código. La página de administración puede crear o renovar enlaces, pero no muestra asignaciones. Renovar un enlace invalida el anterior y cierra el acceso vinculado a esa persona; su asignación secreta se conserva.
- Juanene también participa y solo ve a quién le toca a él. El rol de administrador permite gestionar accesos, no leer los resultados de otras personas.
- Cada enlace es privado y se vincula a la sesión anónima del navegador de la persona en su primer acceso. Si pierde el acceso o cambia de dispositivo, Juanene puede renovarlo; la nueva invitación invalida la sesión anterior, pero conserva la asignación.

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

- El primer canje vincula el código a una sesión anónima persistente del navegador y asigna una sola persona. Los siguientes accesos desde esa misma sesión conservan el resultado. Como no hay contraseña, cambiar de navegador o borrar sus datos locales pierde el acceso asociado; quien organiza tendrá que resolver manualmente un cambio de dispositivo.
- La asignación se elige con búsqueda aleatoria y retroceso, comprobando que las asignaciones pendientes todavía puedan completarse. Una transacción serializa canjes concurrentes, por lo que nadie recibe dos veces el mismo destinatario.
- Solo la Edge Function de Supabase puede canjear códigos o leer la asignación privada. Las listas son visibles para el grupo, pero las políticas RLS dejan que cada sesión autenticada edite únicamente las suyas.
- La vista pública de preguntas omite la identidad de quien pregunta. Solo la persona destinataria puede responder; todo el grupo puede leer preguntas y respuestas.
