# Cambios

## 0.1.4 — 2026-10-31

- Emparejar por QR: el teléfono ahora muestra el mismo código que pide el PC (antes aceptaba en silencio y había que adivinarlo).
- Conectividad: el PC y el teléfono guardan la última dirección de cada equipo emparejado y la marcan al arrancar; un equipo emparejado recibe respuesta a cada anuncio (la única vía que atraviesa el firewall en redes «Públicas»); el servicio de Android mantiene el Wi-Fi activo y recibe difusiones con la pantalla apagada y espera 10 minutos a que vuelva el PC en lugar de 20 s; el instalador ofrece abrir el Firewall de Windows para Alero.
- Se mantiene todo lo de 0.1.3 (tapa trasera en el panel lateral, vatios/voltaje/estado de carga, túnel USB estable, relanzamiento del servicio del PC, reintentos cada ≤ 30 s).

## 0.1.3 — 2026-10-31

- Apertura de APK recibidos: MIME correcto, permiso especial explicado, reintento al volver y errores diferenciados.
- Respuesta a notificaciones desde Windows mediante RemoteInput, con capacidad opcional, ack, expiración y estados de envío.
- Reproducción del PC en Inicio Android: controles según capacidades, posición extrapolada y suscripción mientras se mira.
- Los mockups de dispositivos llevan a Dispositivos con foco y semántica de botón.
- Primer frame antes de inicializar el motor; intro sin espera artificial y setup omitible, persistente y reabrible desde Ajustes.
- Conteos reales y acotados de carpetas, incluido SAF; «—» para desconocidos y «999+» al alcanzar el límite.
- `.trash-storage` oculta y acceso directo denegado, sin borrar su contenido.
- Liberación de listados, miniaturas, timers, codecs e imágenes reemplazadas y bitmaps temporales. Medición documentada; sin reducción global de RAM demostrada.
- Windows: el panel lateral muestra el nombre comercial del teléfono y su tapa trasera exacta como icono (render PNG/SVG de Wikimedia Commons, solo licencias libres; autor y licencia en el tooltip). Sin render verificable queda el icono genérico. Caché local, también sin conexión. El cuadro de Inicio no cambia.
- Windows: «Estado» muestra la carga con vatios reales, voltaje de batería y un estado (Buena ≥ 10 W, Mala ≥ 5 W, Deficiente); «Batería mantenida» si el teléfono la retiene (p. ej. límite del 80 %).
- Conexión más estable: el túnel USB habla con el servidor adb que ya esté en marcha en vez de lanzar su propio `adb` (dos versiones se mataban el servidor) y se reabre solo si se pierde; el ordenador sigue marcando la última dirección del teléfono cada ≤ 30 s en lugar de rendirse a los 90 s; el tiempo de silencio tolerado sube de 30 a 60 s; la app vuelve a lanzar el servicio en segundo plano si se cierra por un fallo; el hilo COM del daemon se mantiene vivo.
- El teléfono envía además `brand`, `device`, `product`, `marketName` en `pb.x.info` y `pb.x.power` (campos opcionales; las versiones anteriores los ignoran).
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
