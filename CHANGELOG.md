# Cambios

## Beta 1.1 (1.1.0) — 2026-11-05

### Rediseño: Alero Fluent Identity

- **Tema principal AMOLED** (negro puro) por defecto en instalaciones nuevas; Claro y Oscuro siguen disponibles en Ajustes › Apariencia. Quien ya eligió un tema lo conserva.
- **Acento monocromo:** blanco sobre oscuro y negro sobre claro. El color se reserva al estado (verde de conectado, rojo de error). El color de acento de Windows ya no tiñe la app.
- **Superficies sutiles y esquinas Fluent:** fondo de ventana negro, tarjetas a un paso del fondo, bordes finos sin sombras, botones con esquinas de 10 px, tarjetas de 16 px y diálogos de 20 px.
- **Iconos unificados:** todos los iconos usan Material Symbols Rounded (había 40 iconos de otra familia que no siempre se dibujaban).
- **El logo no cambia.**

### Nueva distribución del inicio (Windows y Android)

- **Windows:** a la izquierda, la tarjeta del teléfono, su estado y el reproductor; a la derecha, los controles rápidos y las notificaciones; la actividad reciente, a lo ancho abajo. La sección «Arrastra archivos aquí» desaparece del inicio: Enviar archivos sigue en la tarjeta del teléfono y se pueden soltar archivos en cualquier parte de la ventana.
- **Controles del teléfono:** mosaicos pequeños con icono y nombre (como en el prototipo de identidad), «Buscar teléfono» en una línea discreta al final, y el aviso de depuración USB/inalámbrica solo cuando no está activa (antes aparecía un momento cada vez, aunque estuviera activada).
- **Reproductor:** portada cuadrada junto al título y controles debajo, la misma en el teléfono y en el PC. Sustituye a la portada estirada de fondo, que en el teléfono se veía deformada y cargada.
- **Android:** mismo orden que en el PC (equipo, reproductor, controles, actividad) y mosaicos compactos con el mismo estilo.
- **Personalizar › Tamaño de los mosaicos:** Compacto, Normal o Amplio; cambia el relleno y la separación de las tarjetas del inicio al momento, en Windows y Android.

### Errores corregidos

- **No se podía volver a vincular un dispositivo después de desvincularlo.** Causa: el otro dispositivo seguía confiando en el primero, y al reintentar (con «Emparejar de nuevo» o escaneando el QR) el motor lo daba por «ya emparejado» y se saltaba la vinculación. Ahora lo comprueba en la misma conexión y, si el otro lado lo rechaza, inicia una vinculación nueva con código de confirmación. La desvinculación sigue borrando la confianza como antes. Lo cubre una prueba automática nueva.
- **El chat desaparecía mientras se escribía.** Causa: cada cambio del hub (una notificación, la batería, la música) llamaba a la carga de SMS, que vaciaba hilos y mensajes tras un error o un retraso del teléfono. La conversación abierta y el texto escrito se perdían. Ahora solo se reinicia al cambiar de teléfono, y un corte breve de conexión deja el chat abierto con un aviso. Lo cubre una prueba automática nueva.
- **La cámara del teléfono no abría.** Causa: al pasar de una cámara a otra se abría la nueva antes de que el teléfono liberase la anterior, y fallaban las dos sin avisar. Ahora Alero espera a que la sesión anterior termine y, si la cámara está ocupada o bloqueada, explica el motivo en pantalla. Probado con las cámaras trasera y frontal de un Pixel 9a (Android 17).
- **`main` no compilaba en Windows** (import de `BOOL` del crate `windows` 0.62) ni en Dart (coma sobrante en `obs_webcam.dart`).
- La versión de la app mostraba 0.1.18.
- Etiqueta accesible de la tarjeta del dispositivo («Ver X en Dispositivos»).
- El analizador vuelve a pasar sin avisos (25 correcciones de estilo).

### Funciones revisadas

- **Archivos del PC desde el teléfono:** solo las carpetas que autorizas en Ajustes, rutas validadas contra path traversal (`canonicalize` y comprobación de la raíz), conexión TLS emparejada y edición solo con un permiso aparte. Las descargas usan las transferencias de Alero (progreso y cancelación).
- **Pantalla extendida:** Windows ve un monitor real mediante un controlador IddCx (Virtual Display Driver, de código abierto), y Alero transmite ese monitor al teléfono. No es una copia de la pantalla principal.

### Pendiente

- **Pantalla extendida:** necesita que instales el [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver), que requiere permisos de administrador. Alero no instala controladores por su cuenta. Sin el controlador, la app lo indica y no simula un segundo monitor.
- **APK firmado:** la firma de publicación solo existe en GitHub Actions, bloqueado en esta fecha por la facturación de la cuenta. Las compilaciones locales del APK son de depuración, con otra firma, y para instalarlas hay que desinstalar la versión anterior.

## 1.0.0 — 2026-11-05

### Rediseño de Windows y Android

- **Windows:** nuevo inicio conforme a las dos capturas proporcionadas: navegación lateral de grafito con apartados agrupados, opción «Contraer menú», tarjeta principal de dispositivo con indicadores de conexión y batería, reproductor compacto, notificaciones, archivos, estado y controles rápidos, y actividad reciente con filtros Todo/Enviados/Recibidos.
- **Android:** adaptación de las superficies, tarjetas, colores, tipografía y jerarquía del mismo diseño a pantallas estrechas. **Se conserva la píldora flotante de navegación inferior original**, su funcionamiento y todas sus secciones.
- **Personalizar:** acceso directo a Apariencia y Ajustes desde el inicio de Windows.
- **Datos reales:** el resumen, los archivos, la reproducción, las notificaciones y los controles siguen conectados a las funciones existentes de Alero; no se utilizan nombres ni mensajes ficticios de las capturas.

### Animaciones

- Se adaptaron los movimientos de Material 3 Expressive/Orion: presión elástica al 95,5 %, entrada y salida de apartados con transición de escala 98–100 % y fundido, aparición escalonada de tarjetas con desplazamiento vertical y movimiento animado de cifras.
- Indicador de actividad pulsante solo para transferencias reales, detenido durante inactividad.
- Se respeta la preferencia de accesibilidad «Reducir animaciones» en Windows y Android.
- **Píldora de Android:** mantiene el mismo diseño y la transición elástica entre opciones.

### Funciones conservadas

- Se mantienen las transferencias de archivos, la sincronización de portapapeles, mensajes, llamadas, notificaciones, fotos, explorador, controles del teléfono, conexiones, dispositivos, configuración y las demás funciones previamente incorporadas.
- Se mantienen Alero Present, Alero Vault, el acceso remoto y las integraciones de pantalla extendida, webcam y archivos del ordenador incluidas en el código anterior.
- Los antiguos destinos «Aplicaciones» y «Alero Desktop» continúan retirados, como se solicitó anteriormente; sus opciones no vuelven a aparecer.

### Errores corregidos

- Navegación lateral organizada por secciones con estado y contadores actualizados.
- Paneles de Windows ajustados a la anchura disponible, evitando columnas desordenadas.
- Diseño adaptable a Windows y Android sin sustituir ni eliminar la navegación inferior del teléfono.
- Reproductor compacto sin mostrar un panel multimedia enorme dentro del dashboard.

### Paquetes

- APK Android ARM64 e instalador Windows x64 procedentes del mismo commit de `main`, sujetos a la generación correcta de ambos paquetes en GitHub Actions.
- Publicación con changelog y sumas SHA-256 una vez que el proceso de compilación finalice correctamente.
- Por petición expresa, esta entrega no agrega pruebas manuales ni nuevas suites de prueba.


## 0.1.18 — 2026-11-04

Actualización incremental basada en 0.1.17. Se mantienen todas las funciones existentes, la firma Android original y la compatibilidad de los componentes anteriores.

### Funciones nuevas

- **Depuración USB e inalámbrica por separado:** botones independientes en Dispositivos, Aplicaciones y Alero Desktop (Windows). Las tres pantallas comparten la selección del transporte ADB autorizado del mismo teléfono.
- **Vinculación ADB por Wi-Fi:** diálogo con dirección IPv4, puerto de vinculación, código temporal de seis dígitos y puerto de conexión distinto, con descubrimiento mDNS cuando sea posible. El código se envía a adb por entrada estándar, no como argumento del proceso.
- **Aplicaciones y Alero Desktop sin cable:** permiten usar una conexión ADB Wi-Fi autorizada y seleccionar el transporte USB sin rehacer el emparejamiento propio de Alero. Se puede desconectar el transporte Wi-Fi independientemente de la confianza TLS de Alero.

### Errores corregidos

- **Píldora de navegación:** centrado mediante disposición real del grupo icono/etiqueta en lugar de posicionamiento absoluto; una insignia no cambia el centro geométrico del icono. Se conserva la animación entre apartados.
- **Reconexión:** el cierre tardío de un socket no sustituye el estado «Desconectado voluntariamente» por «Conexión perdida».
- **Android:** un ordenador que desconecta Alero no provoca la terminación inmediata del servicio del teléfono: se mantiene el margen de reconexión para permitir reanudar sin repetir QR.
- Actualizaciones del dispositivo ADB seleccionado se propagan a las demás pantallas de Windows sin depender de una recarga completa.

### Pruebas y limitaciones

- Pruebas automáticas de centrado, múltiples ciclos de conexión/desconexión, servicio Android y verificación Rust/Flutter/Kotlin ejecutadas mediante GitHub Actions (consultar la ejecución de cada compilación).
- La conexión ADB inalámbrica requiere activación y autorización oficiales del usuario desde Android; IP y puertos pueden cambiar.
- Tras el período de gracia del servicio Android y si Android suspende el proceso, la reconexión en segundo plano puede requerir abrir Alero o activar su opción de ejecución en segundo plano. No se garantiza control remoto sin permisos del sistema.
- La instalación de la APK con Google Play Protect activado **no está verificada** mediante dispositivo real. No se han eliminado permisos ni funciones.
- La reproducción de vídeo en directo y demás funciones pendientes de versiones anteriores no se declaran corregidas en esta versión.

## 0.1.17 — 2026-11-04

Instala juntos el APK de Android y el instalador de Windows de esta versión: la portada de lo que suena en el ordenador necesita ambos lados actualizados.

### Funciones nuevas

- **Portada de lo que suena en Windows:** el teléfono muestra la portada de Spotify, el navegador o cualquier reproductor que se la dé a Windows.
- **Clic derecho con dos dedos** en el panel táctil del teléfono.

### Cambios

- **Inicio ocupa toda la ventana:** los paneles se reparten en dos columnas (tres en ventanas muy anchas). Controles del teléfono y Estado van a la derecha.
- **Controles del teléfono compactos:** cuadrícula de iconos que llena el ancho; el nombre, el estado y por qué un control no está disponible aparecen al pasar el ratón.
- **«Reproduciendo» rediseñado otra vez:** se adapta a cada pantalla (portada grande arriba en pantallas estrechas, al lado en anchas), portadas no cuadradas recortadas sin salirse, títulos en dos líneas, botones más grandes y barras de progreso más gruesas.

### Errores corregidos

- **La cámara del teléfono no se abría:** scrcpy rechaza «mantener despierto» sin control y se cerraba al instante.
- **Desplazamiento horizontal invertido** en el panel táctil: ahora el contenido sigue a los dedos, igual que en vertical.
- **Alero seguía en segundo plano en Android tras desvincular:** un ordenador desemparejado seguía contando como conectado. Al desemparejar o desconectar a propósito el servicio se detiene al momento, salvo que actives «segundo plano» en Ajustes.
## 0.1.16 — 2026-11-04 (mejoras incrementales Android + Windows)

Instala ambos paquetes de la misma versión para conservar la compatibilidad. **Esta publicación es una actualización parcial de interfaz y estabilidad, no la finalización de todas las funciones solicitadas.**

### Mejoras

- **Mensajes:** conserva durante la sesión hasta 50 conversaciones procedentes de notificaciones, incluso si Android retira la notificación al contestar. Los mensajes enviados con confirmación de entrega a Android aparecen a la derecha, sin fingir una confirmación de recepción en WhatsApp. Si la notificación ya no permite responder, la conversación sigue visible en modo lectura.
- **Reproduciendo:** carátulas como fondo del recuadro de reproducción y degradado de contraste para los controles; mejor selección de ilustraciones multimedia en Android y compresión adaptativa para no exceder el límite de comunicación. La reproducción de video en vivo permanece pendiente.
- **Widgets Android:** reorganización del panel principal con información del equipo a la izquierda y controles a la derecha, aprovechando mejor las dimensiones grandes y manteniendo las acciones existentes.
- **Rendimiento Android:** no ejecutar diagnósticos de red destinados a la interfaz mientras esta esté en segundo plano. El servicio de conexión, notificaciones y transferencias se mantiene independiente y activo.

### Errores corregidos

- Corrige el desplazamiento visual de los iconos de la navegación cuando tienen insignias.
- Evita que los botones de dispositivos emparejados compriman el nombre y el estado en ventanas estrechas.
- Corrige un aviso del analizador Flutter por una referencia al observador del ciclo de vida y libera el observador al desechar el controlador.

### Limitaciones y verificación pendiente

- El bloqueo de Google Play Protect en algunas instalaciones **no está confirmado como resuelto**. Se mantiene la misma firma y todos los permisos y funciones existentes. La revisión o apelación oficial de Google puede ser necesaria.
- No se han corregido todavía de manera verificada la cámara remota, la vista previa de video directo ni la búsqueda temporal para multimedia de Windows.
- Las pruebas automáticas de Rust, Flutter y Android se ejecutan mediante GitHub Actions antes de distribuir. No afirmar ensayos físicos no realizados.

## 0.1.15 — 2026-11-03 (solo Android, versión candidata a revisión de Play Protect)

### Correcciones y seguridad Android

- Se añade un diálogo de consentimiento destacado antes de solicitar acceso al historial SMS/MMS y a los contactos. Explica los datos compartidos con un ordenador emparejado, el envío de SMS, que la función está apagada de forma predeterminada y cómo desactivarla. Cancelar no activa la función.
- Se mantienen exactamente los permisos `READ_SMS`, `SEND_SMS`, `READ_CALL_LOG`, el acceso a notificaciones y todas las funciones de 0.1.14. Sin modificaciones ni compilación de Windows.
- Se verifica automáticamente la firma de lanzamiento del APK contra la identidad original usada en 0.1.11 y 0.1.14; se publica únicamente el APK Android ARM64 y el archivo SHA-256.
- **Estado real de Play Protect:** esta compilación es una candidata para revisión, **NO una corrección confirmada del bloqueo al instalar desde GitHub**. Play Protect puede continuar bloqueando APKs descargados de Internet que declaran `READ_SMS` y el acceso a notificaciones, aun con firma válida y consentimiento explícito. No desactives Play Protect para instalarla.
- Para mantener SMS, llamadas y notificaciones al mismo tiempo, es necesaria una revisión/apelación de la clasificación de Play Protect o una distribución aprobada (Google Play permite solicitar una excepción para sincronización de SMS/llamadas entre dispositivos, sujeta a revisión). La aprobación depende de Google.

## 0.1.14 — 2026-11-03

Instala juntos el APK de Android y el instalador de Windows de esta versión: los iconos de apps, Alero Desktop, SMS, llamadas y controles del teléfono necesitan ambos lados actualizados.

### Funciones nuevas

- **El teléfono desde el ordenador (menú lateral):** Mensajes (SMS y chats de apps; se activa en Alero › Ajustes del teléfono), Llamadas (contestar, colgar, marcar y registro de llamadas), Fotos, Aplicaciones (cada app se abre en su propia ventana sin ocupar el teléfono) y Alero Desktop.
- **Controles del teléfono en Inicio:** nuevo apartado con Buscar teléfono, Wi-Fi, Bluetooth, zona Wi-Fi, No molestar, linterna, bloqueo de pantalla, modo de sonido, volúmenes y la cámara del teléfono en una ventana. Wi-Fi, Bluetooth, bloqueo y cámara necesitan la depuración USB o inalámbrica.
- **Aplicaciones con su icono:** el teléfono envía el icono real de cada app (una sola vez por app) para la cuadrícula de Aplicaciones, el lanzador y la barra de Alero Desktop.
- **«Reproduciendo» rediseñado:** portada grande con fondo difuminado, icono de la app que reproduce, barras animadas mientras suena, cambio de canción animado y dónde suena (en el teléfono, transmitiendo a otro dispositivo o en el ordenador). Respeta «reducir movimiento».
- **Explorador:** eliminar y renombrar archivos del teléfono; enviar y recibir carpetas completas.
- **Recientes sincronizados:** quitar una entrada la quita en los dos dispositivos (el archivo no se borra).
- **Notificaciones:** marcar como leída, silenciar una conversación o una app (lista en Ajustes del teléfono).

### Cambios

- **«Modo Deck» ahora se llama Alero Desktop.**
- **Se quitó el apartado Archivos.** Las transferencias en curso y las recientes siguen en Inicio («Abrir carpeta» abre las descargas).
- Las notificaciones de reproductores de música ya no se duplican en Notificaciones: se ven solo en «Reproduciendo».

### Errores corregidos

- **Alero Desktop:**
  - **Inicio no funcionaba:** Android 17 rechaza el botón Inicio en las pantallas virtuales de scrcpy («not allowed on display») y su barra de tareas tapaba la de Alero. El escritorio se crea ahora sin las barras del sistema, y la barra de Alero tiene su propio botón Inicio. Flota sobre las apps y se reduce a una franja fina mientras hay una app delante; al pasar el ratón por la franja vuelve a aparecer. Alero concede por adb el permiso «Mostrar sobre otras apps» al iniciar el escritorio.
  - **Relación de aspecto:** «Adaptar al tamaño de la ventana» (`--flex-display`) dibujaba la pantalla sin escalar, así que el escritorio se veía recortado y sin barra de tareas. Se quitó: el escritorio conserva su tamaño y se escala a la ventana.
  - **Apps que se abrían en el teléfono:** las apps con varias actividades de inicio (por ejemplo, Firefox) fallaban con «unable to resolve». Ahora se abre la actividad exacta que Android declara para cada app. Comprobado en un Pixel 9a con Android 17: una app abierta en el teléfono se abre como ventana nueva en el escritorio sin quitarla del teléfono.
- **Instalador de Windows:** antes de instalar o desinstalar cierra Alero, su proceso en segundo plano, scrcpy y adb (solo los que se ejecutan desde la carpeta de Alero). Ya no hay que cerrarlos a mano.
- **Mensajes y llamadas no llegaban al teléfono:** el puente de Android descartaba esos mensajes.

### Limpieza

- Se eliminaron archivos del antiguo ejecutor de Linux que seguían en el repositorio y la pantalla de Archivos.

## 0.1.13 — 2026-11-02

Instala juntos el APK de Android y el instalador de Windows de esta versión: la desconexión voluntaria, las acciones de transferencia y el Inicio de Alero Desktop necesitan ambos lados actualizados.

### Errores corregidos

- **Animaciones entre apartados:** la página que salía nunca se desvanecía (el conmutador anima la salida con una animación que la transición ignoraba), así que quedaba opaca debajo de la nueva y, al cambiar rápido, se apilaban varias. Ahora la salida es la inversa de la entrada inspirada en Orion Store (escala 1 → 0,98 y fundido), termina en el primer tercio para que una página interrumpida desaparezca enseguida, y la página que se va deja de recibir toques, teclado y foco. Se eliminó además una fuga de *listeners* que crecía con cada actualización del estado. Respeta «reducir movimiento» del sistema.
- **Cursor al compartir pantalla:** el puntero del ordenador se dibujaba a tamaño completo después de reducir la imagen y sin tener en cuenta su punto activo. Ahora ocupa un 18 % menos, sigue la escala DPI y el tamaño de puntero de accesibilidad de Windows, y la punta coincide con el punto real del clic (I-beam y mano incluidos). El cursor del sistema no se modifica.
- **Alero Desktop:**
  - Ya no se abre Ajustes al iniciar el escritorio (podía mover los Ajustes que el Pixel tenía abiertos).
  - Cada app se comprueba después de abrirla: Alero mira en qué pantalla y tarea la colocó Android e informa si se abrió solo en el escritorio, si Android movió la ventana que estaba en el Pixel, si apareció también en el Pixel o si la envió al Pixel en lugar del escritorio. Esto último ya no se da por abierto.
  - Si la app está abierta en el teléfono, se pregunta antes de abrirla en el escritorio (muchas apps solo admiten una ventana).
  - Nunca se lanza una app en una pantalla virtual que ya no existe, porque Android la redirigiría al teléfono.
  - **Inicio:** el botón Inicio abre siempre el mismo lanzador de Alero en la pantalla virtual (antes apilaba una copia en cada pulsación), se comprueba que aparezca y el botón Atrás ya no lo cierra dejando una pantalla negra. El lanzador ya no falla en Android 8–10.
  - **Cerrar ventana** quita solo la ventana del escritorio virtual (como deslizarla en Recientes) sin cerrar la app en el teléfono. «Forzar detención» sigue disponible con su advertencia.
  - El sondeo cada 5 s ya no arranca un servidor scrcpy en el teléfono; solo consulta las tareas (menos CPU y batería).
  - Las apps de «Espacios guardados» abiertas en una pantalla virtual también se verifican.
  - Se corrigió la lectura de la lista de pantallas de scrcpy (unía dos líneas con un «\n» literal).
- **Widgets de Android:** existían en el código, pero nunca se integraron en `main`, por eso no aparecían en el selector de widgets. Ya están integrados y registrados. Además, dos diseños usaban una vista que los widgets no admiten («No se puede cargar el widget») y el servicio no recibía los eventos de inicio y progreso de las transferencias, así que el widget de transferencias se habría quedado vacío.
- **Nombre comercial:** el logotipo mostraba «alero» en minúsculas; ahora dice «Alero». El proceso en segundo plano de Windows aparece como «Alero (segundo plano)» en el Administrador de tareas en lugar de `alero_daemon.exe`. Paquete Android, identificadores y rutas sin cambios.
- **Respuestas a notificaciones sin límite artificial:** Alero cortaba la escritura en 4000 caracteres (en el campo, al enviar y en el teléfono). Ahora no hay límite propio: el único es el del mensaje del protocolo, 240 KB (decenas de miles de caracteres, incluso con emojis); si se supera se avisa y no se envía ni se recorta nada.
- **Pruebas en CI:** las pruebas de Alero Desktop de 0.1.12 no compilaban (faltaba una importación), por lo que las comprobaciones de `main` no podían pasar.

### Funciones nuevas

- **Desconectar sin olvidar:** botón **Desconectar** visible en Dispositivos. Cierra la conexión, detiene las sesiones de control con ese dispositivo y cancela sus transferencias, pero conserva el emparejamiento por QR. No se reconecta solo (tampoco al reiniciar) hasta que pulses **Conectar**. El estado distingue «Desconectado por ti», «Desconectado desde el otro dispositivo» y «Sin conexión / Se perdió la conexión». **Olvidar** sigue pidiendo confirmación.
- **Transferencias desde las notificaciones:**
  - Android: «Aceptar descarga» / «Rechazar» para archivos entrantes que requieren confirmación, progreso real con «Cancelar», aviso de archivo recibido con «Abrir en Alero» y «Descargas», y acción «Enviar archivo» en la notificación de conexión.
  - Windows (con la ventana cerrada, desde la bandeja): «Aceptar» / «Rechazar» en la notificación de archivo entrante y «Abrir» / «Abrir carpeta» al recibirlo. Para archivos que Windows ejecutaría (.exe, .msi, scripts…) solo se ofrece la carpeta.
  - Nada se descarga ni se abre sin una pulsación del usuario; pulsar varias veces no duplica la transferencia.
- **Campo de respuesta Material 3 Expressive:** crece hasta 6 líneas y luego se desplaza; Intro envía y Mayús+Intro añade un salto de línea; el botón de envío sigue visible y muestra el progreso; el borrador se conserva al cambiar de diseño o de foco y si el envío falla. Tras enviar dice que Android entregó la respuesta a la app, sin afirmar que el destinatario la recibió.
- **Widgets:** dispositivos, estado, control remoto (con estado de la conexión), transferencias (botón Enviar, progreso y recientes), multimedia del ordenador y panel compacto de Alero. Colores dinámicos de Material You en Android 12+, tema claro/oscuro, esquinas del launcher, redimensionables. Se actualizan solo con eventos reales (máximo una vez por segundo), sin temporizadores.

### Arquitecturas de Windows (auditoría)

- **La aplicación es x64 nativa.** El instalador lo genera Inno Setup 6, cuyo programa de instalación siempre es un ejecutable de 32 bits; por eso Windows lo muestra como «32 bits». Instala Alero en modo de 64 bits y solo en Windows x64 o Windows 11 ARM (mediante su emulación x64). No era un error de compilación.
- El script de compilación comprueba ahora que **todos** los binarios del paquete son x64 y que llevan la información de versión «Alero». Única excepción, encontrada por esa comprobación: `adb.exe` y sus dos DLL (incluidos en el paquete oficial «win64» de scrcpy) son de 32 bits porque Google solo publica adb para Windows en x86; funcionan en Windows x64 y en Windows 11 ARM.
- **ARM64 nativo: no se publica.** Flutter no compila Windows ARM64 de forma cruzada desde x64, GitHub no ofrece ejecutores Windows ARM64 para repositorios privados y scrcpy no publica binarios ARM64 para Windows. El instalador x64 funciona en Windows 11 ARM mediante emulación.
- **x86 de 32 bits: no es posible.** Flutter no admite Windows de 32 bits.

### Limitaciones que siguen

- Android decide si una app puede abrirse en otra pantalla y si admite dos ventanas a la vez; Alero lo detecta y lo informa, no lo puede forzar sin root.
- El botón Inicio del propio visor de scrcpy (o la tecla Inicio) abre el inicio del sistema en la pantalla virtual, no el de Alero; usa el botón Inicio del panel de Alero Desktop.
- Minimizar y redimensionar ventanas individuales dependen de las decoraciones de ventana libre que ofrezca Android en esa pantalla.
- Las notificaciones interactivas de Windows funcionan con la ventana de Alero cerrada (desde la bandeja); con la ventana abierta, la oferta se responde en el diálogo de la app.
- Android no confirma la entrega al destinatario de una respuesta, solo que la app la aceptó; algunas apps de mensajería tienen su propio límite de longitud.

### Verificación

- Automatizada (local y en GitHub Actions): pruebas de Rust (emparejamiento → desconexión → sin reconexión automática → reinicio → reconexión; respuesta de 10 000 emojis a través del protocolo; tamaño y punto activo del cursor; seguridad de las acciones de las notificaciones), pruebas de Flutter (60: navegación rápida entre apartados, reducir movimiento, toques durante la transición; respuestas de 100, 500, 1000, 5000 y 10 000 caracteres, párrafos, emojis, texto pegado, Intro/Mayús+Intro, borradores; lectura de tareas y veredicto de cada lanzamiento de Alero Desktop) y pruebas unitarias Kotlin (textos de widgets, validación de respuestas). APK firmado verificado con `apksigner` e instalador comprobado (arquitectura e información de versión).
- **Pendiente de prueba en un Pixel real:** Alero Desktop en Android 17, aparición de los widgets en el selector, notificaciones de transferencia y respuestas largas en WhatsApp/Telegram.

## 0.1.12 — 2026-11-02

- **Independencia:** Alero Desktop solicita nuevas tareas de apps en la pantalla secundaria y verifica que Android realmente las registre allí, en lugar de afirmar éxito si se redirigen al teléfono.
- **Inicio:** nuevo launcher Android exclusivo para pantallas virtuales y botón «Ir a Inicio», evitando depender de KEYCODE_HOME que el Pixel puede ignorar.
- Se preserva el launcher predeterminado del Pixel. Alero no fuerza cambios del sistema ni permisos adicionales.
- Es necesario actualizar el APK de Android y el instalador Windows juntos. Pruebas unitarias de destino y errores añadidas.
- **Pendiente prueba práctica:** Android puede rechazar ejecutar determinadas apps en una pantalla secundaria; el código no puede anular esa restricción del firmware.

## 0.1.11 — 2026-11-02

- **scrcpy actualizado:** runtime Windows pasa de 4.1 a 5.0.1, con hash SHA-256 oficial verificado para mayor compatibilidad con Android 17. La elegibilidad de un display virtual para ventanas libres sigue determinada por Android.
- **Alero Desktop en Windows:** nueva pantalla accesible desde «Controlar teléfono» para iniciar una pantalla Android virtual independiente mediante scrcpy 4.1 y utilizar aplicaciones del Pixel desde la laptop.
- **Entorno de trabajo:** lanzador con búsqueda de paquetes de usuario, favoritos persistentes (hasta 12) en una barra inferior, selección de pantalla real detectada, acceso al catálogo y a espacios guardados de Dextop.
- **Resolución adaptativa:** 720p, 900p, 1080p o 1440p, densidad adecuada para pantalla grande, opción `--flex-display`, `--keep-active` y teclado/IME local en la pantalla Android.
- **Ventanas y tareas:** consultar tareas Android reales de la pantalla secundaria, traer aplicaciones al frente, solicitar maximización y organización de 2 a 4 ventanas con los comandos ADB permitidos por Android. Botón Inicio dirigido a la pantalla secundaria. El cierre forzado de apps del usuario requiere confirmación y explica sus efectos sobre notificaciones.
- **Compatibilidad Android 16/17:** la detección de ventanas libres considera el modo escritorio moderno y no depende únicamente del antiguo ajuste «Forzar modo de escritorio». La apertura de una pantalla virtual y el modo de ventanas con barra de título son capacidades distintas: Android puede denegar ventanas libres incluso cuando scrcpy muestra la pantalla.
- **Protección de pantalla física:** no se adivina el identificador de pantalla; se compara la lista antes/después de crearla y se exige seleccionar un display secundario si no puede identificarse. No se necesita root.
- **Limitaciones comprobables:** scrcpy presenta Android en una ventana propia, separada del panel Alero Desktop. Los botones de minimizar/cerrar/redimensionar individualmente mediante las decoraciones de Android solo aparecen cuando el sistema admite escritorio nativo en esa pantalla; Alero no inventa controles ni activa configuraciones privilegiadas. El lanzador alternativo es Windows, no una modificación del launcher del Pixel. Es necesaria una prueba real con el dispositivo para confirmar la compatibilidad visual.
- Se mantiene la funcionalidad de Android (sin permisos nuevos), el control normal del teléfono, las notificaciones, las herramientas de escritorio previas, los espacios JSON y la firma de APK. Se actualizan pruebas automatizadas y versión 0.1.11 para APK e instalador Windows.


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
