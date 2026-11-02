# Cambios

## 0.1.10 — 2026-11-01

- Windows: el control del teléfono inicia scrcpy sin mostrar la consola auxiliar ADB/scrcpy; la ventana de imagen y los controles del teléfono siguen disponibles.
- El estado de la sesión ahora se actualiza según la finalización real del proceso scrcpy, sin deducirla del cierre de stdout. Se conserva la finalización desde «Detener» y al salir de Alero.
- Se mantiene la conexión USB/Wi-Fi, el control de escritorio y las herramientas Dextop incorporadas en 0.1.9. No se requieren nuevos permisos en Android.
- Versión visible sincronizada con la del instalador y APK. Corrección pendiente de comprobación en un Pixel conectado a Windows.

## 0.1.9 — 2026-11-01

- Alero amplía el control de Windows a Android con un **taller de escritorio** inspirado en Dextop: lista dinámica de aplicaciones instaladas mediante ADB autorizado, búsqueda y apertura de aplicaciones.
- **Espacios de trabajo:** selecciona varias aplicaciones, guarda configuraciones localmente, restáuralas de forma explícita e importa/exporta JSON (máximo 32 espacios y 12 apps por espacio, con validación de paquetes).
- **Varias pantallas:** descubre los identificadores que scrcpy anuncia, permite escoger un display disponible y solicita a Android iniciar allí las aplicaciones.
- **Ventanas libres:** se solicita freeform y, bajo autorización explícita, se intenta distribuir hasta cuatro tareas mediante `am task resize` cuando Android expone identificadores fiables y admite esa orden. Si el fabricante lo impide, Alero informa y conserva las apps abiertas sin forzar configuraciones ocultas.
- **Resolución del escritorio:** perfiles 720p, 900p, 1080p y 1440p; opción experimental de cambiar dinámicamente el tamaño de la pantalla virtual mediante scrcpy.
- **Diagnóstico real bajo demanda:** batería, temperatura y memoria disponibles mediante ADB sin estimar FPS ni consumo eléctrico no medidos.
- **Control existente conservado:** ratón, teclado, gestos y portapapeles de scrcpy, conexiones USB/Wi-Fi, navegación y cierre de sesión; herramientas para recuperar voluntariamente espacios tras reconectar.
- Nuevas pruebas de catálogo de paquetes, validación de entradas, perfiles JSON, pantallas, comandos de scrcpy y métricas; se mantiene la firma e identidad Android.
- **Limitaciones:** la distribución nativa es experimental y depende de `am task resize`, no un gestor privilegiado de ventanas de Dextop. No se implementa el movimiento automático del puntero entre monitores; requiere validación con hardware real.
- Se conserva la función de notificaciones y medios de Android. Play Protect puede seguir bloqueando APK distribuidos fuera de Google Play.


## 0.1.8 — 2026-11-01

- **Controlar el teléfono desde Windows** (scrcpy 4.1 incluido): nueva página con los teléfonos por USB y Wi-Fi y su estado («Listo», «Falta permiso: toca Permitir en el teléfono», «Sin respuesta»), detección automática de cables cada 3 s, elección entre varios dispositivos y vinculación por Wi-Fi con código.
- Opciones de sesión: resolución (1024, 1600, original), calidad (4, 8, 16 Mbps), 30/60 fps, orientación, sonido, pantalla completa y apagar la pantalla del teléfono. Ratón, teclado y portapapeles funcionan en la ventana (Alt+F pantalla completa, Alt+R girar).
- Barra durante la sesión: Atrás, Inicio, Recientes, volumen y reproducción, enviados al servidor de adb ya en marcha (sin lanzar procesos adb ni cortar la sesión).
- **Modo escritorio** solo donde Android lo ofrece: con ventanas libres y la opción de desarrollador «Forzar modo de escritorio» se abre una pantalla aparte con el escritorio de Android; si falta la opción se explica cómo activarla, y si el teléfono no lo admite se usa su pantalla normal. Alero no cambia ajustes del teléfono por su cuenta.
- Seguridad: el teléfono emparejado muestra «<PC> controla este teléfono» con un botón «Detener» que cierra la sesión en el PC; el aviso desaparece al terminar o si el PC se desconecta. Cerrar Alero en Windows termina todas las sesiones.
- Corrección: una alerta sin ventana disponible ya no produce un error asíncrono (causaba un fallo intermitente en las pruebas desde 0.1.4). La versión mostrada en la app volvía a decir 0.1.5.
- Pruebas nuevas: lectura de `adb devices -l`, decisión del modo escritorio y argumentos de scrcpy.

## 0.1.7 — 2026-11-01

- Configuración inicial en Windows y Android: el campo «Nombre del dispositivo» presenta la etiqueta por encima del cuadro, texto alineado verticalmente y una ayuda separada; evita la superposición con nombres largos y la tipografía variable.
- Se añade una prueba de regresión del diseño en anchos de móvil y escritorio.
- **Se mantienen todas las funciones Android**, incluido el acceso a notificaciones y controles multimedia; un único APK con el mismo nombre de paquete y la misma identidad de firma que la versión anterior.
- Google Play Protect puede bloquear la instalación directa desde GitHub por el acceso legítimo a notificaciones; la firma correcta del APK no elimina esta restricción. Para instalaciones con Play Protect activado, evaluar el canal de pruebas internas de Google Play o la apelación oficial. El bloqueo **no se declara resuelto**.

## 0.1.6 — 2026-11-01

- Animaciones Orion Store adaptadas a Flutter en Windows y Android: transición entre pantallas con opacidad y escala de 98 % a 100 %, reversible al salir.
- Pulsación elástica en navegación lateral y barra flotante; selección de pestaña con muelle espacial, respetando los ajustes de movimiento reducido.
- Firma Android: las compilaciones release exigen la identidad de firma configurada en los secretos de GitHub; queda prohibido generar por accidente una versión release con la clave de depuración. Se conserva la identidad usada para actualizar instalaciones existentes.
- Distribución: paquetes de Windows y Android generados en GitHub Actions con pruebas y hashes SHA-256.
- Play Protect sigue decidiendo de forma independiente la aceptación de instalaciones externas. Las advertencias por permisos sensibles, escaneos o reputación de firma no pueden eliminarse desde el APK sin aprobación de Google.


## 0.1.5 — 2026-11-01

- Emparejar por QR ya no falla con «No route to host»: el QR del PC se actualiza cuando cambia su red (Wi-Fi ↔ cable) y el teléfono usa la dirección desde la que oye al PC si el QR es viejo.
- Reconexión: con la app abierta el teléfono oye los anuncios del PC aunque el servicio no esté activo, y al volver a oír a un equipo tras un silencio se reintenta al instante en vez de esperar el último intervalo (hasta 30 s).
- Control remoto: cuando Windows muestra una pantalla protegida (permiso de administrador/UAC o bloqueo) el teléfono avisa de que hay que responderla en el PC; la imagen y el control vuelven solos al cerrarla.
- Botones de clic: icono de mouse con el botón izquierdo o derecho pintado.

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
