# Cambios

## 0.1.3 — 2026-10-31 (preparada localmente)

- Apertura de APK recibidos: MIME correcto, permiso especial explicado, reintento al volver y errores diferenciados.
- Respuesta a notificaciones desde Windows mediante RemoteInput, con capacidad opcional, ack, expiración y estados de envío.
- Reproducción del PC en Inicio Android: controles según capacidades, posición extrapolada y suscripción mientras se mira.
- Los mockups de dispositivos llevan a Dispositivos con foco y semántica de botón.
- Primer frame antes de inicializar el motor; intro sin espera artificial y setup omitible, persistente y reabrible desde Ajustes.
- Conteos reales y acotados de carpetas, incluido SAF; «—» para desconocidos y «999+» al alcanzar el límite.
- `.trash-storage` oculta y acceso directo denegado, sin borrar su contenido.
- Liberación de listados, miniaturas, timers, codecs e imágenes reemplazadas y bitmaps temporales. Medición documentada; sin reducción global de RAM demostrada.
- Imagen del teléfono en Inicio de Windows: nombre comercial y foto o render del modelo exacto (Wikimedia Commons, solo licencias libres, con autor y licencia a la vista). Sin imagen verificable se dibuja el teléfono genérico. Caché local con uso sin conexión; nada de esto interviene en la conexión.
- Windows muestra la potencia real de carga del teléfono en vatios (tensión × corriente de la batería, medida en el teléfono); se oculta si está en mantenimiento o no es medible.
- El teléfono envía además `brand`, `device`, `product` y `marketName` en `pb.x.info`, y `pb.x.power` (campos opcionales; las versiones anteriores los ignoran).
- Regresiones Flutter/Kotlin, compilaciones release y compatibilidad con 0.1.2 verificadas. Véase `packaging/VALIDATION-0.1.3.md` para cifras y pruebas manuales pendientes.

## 0.1.2 — 2026-10-30

- Dos dedos solo desplazan; se retira la barra de desplazamiento lateral.
- Doble toque con el segundo toque sostenido para arrastrar y seleccionar.
- Botones izquierdo/derecho seleccionados hasta volver a tocarlos, sin avisos de tooltip.
- Liberación del ratón al cancelar, salir o perder la conexión.
- Música: solo audio de más de 5 segundos; se excluyen tonos, alarmas y notificaciones.
- Explorador de todas las carpetas del almacenamiento compartido, con permiso Android explícito y límites de rutas.
- Bloqueo opcional de la app Android con huella o PIN del sistema.
- Se retira el panel «En el teléfono» de Ajustes.
- Modelo real, proporciones y fondos integrados del sistema en las miniaturas de dispositivos.
- Reproducción sincronizada periódicamente, posición corregida, controles según capacidades y actualización manual.
- Apertura de transferencias completadas con la app asociada en Windows y Android; persistencia de las URI Android.
- Compilaciones y verificaciones en GitHub Actions, paquetes Android ARM64 y Windows x64 con SHA-256.

Publicación preliminar: firma Android de desarrollo existente, instalador Windows sin Authenticode.
