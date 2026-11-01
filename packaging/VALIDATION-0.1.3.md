# Alero 0.1.3 — implementación y validación local

Fecha: 31 de octubre de 2026. App `0.1.3+4`; Windows x64 y Pixel 9a (Android 17). Código aplicado a n1mz/Proyecto. No se publicó una release.

## Estado al detener el control del equipo

El usuario detuvo Computer Use con la tecla física Esc. Se dejó de controlar las apps. La opción experimental de backend gráfico se retiró del código fuente porque no se terminó su comparación. El ejecutable Windows abierto corresponde a una compilación de prueba anterior a esa retirada; no debe tratarse como un paquete final. El APK disponible e instalado se generó antes del último ajuste de vida de las imágenes. Falta regenerar los paquetes finales desde este código; no se modificó la firma.

Queda pendiente retirar únicamente los archivos sintéticos creados por esta sesión: tres `Alero-prueba-RAM-*.bin` de 128 MiB en Descargas/Alero y la carpeta `/sdcard/Alero-RAM-0d77ca2b` con 3000 archivos vacíos. También existen las copias sintéticas locales en la carpeta `v013-work` de Alero. No se borraron datos preexistentes. El script de limpieza preparado comprueba nombres, tamaños y contenido antes de retirar sus propios fixtures; no se ejecutó después de Esc.

## Resultado

Se implementaron los cambios funcionales y de retención de cachés. **Las mediciones no demuestran una reducción global de RAM de 0.1.3 respecto a 0.1.2.** En la comparación repetida la app nueva utiliza más memoria en varios escenarios. La liberación de objetos comprobada no equivale a que el runtime devuelva inmediatamente ese espacio al sistema.

Los controles y mensajes nuevos son `pb.x.*`. `replyable`, `request`, `actions` y `speed` son opcionales; los peers antiguos no muestran respuesta cuando falta `replyable`. `pb.x.notif.reply`, su resultado y `pb.x.pcmedia.unwatch` son mensajes nuevos, ignorables por versiones anteriores.

## Causas confirmadas y archivos por punto

Las rutas Kotlin siguientes son relativas a `app/android/app/src/main/kotlin/dev/alero/app/`; sus tests están en `app/android/app/src/test/kotlin/dev/alero/app/`.

| Punto | Causa y cambio | Archivos |
| --- | --- | --- |
| 1. Abrir APK | Faltaba el permiso del manifest; el MIME genérico ocultaba el instalador; no se revisaba la autorización. Se fuerza el MIME para APK, se valida lectura, se publica una copia completa cuando hace falta y se reintenta al volver del ajuste. Los errores nativos llegan a la UI. | `AndroidManifest.xml`, `MainActivity.kt`, `FileOpening.kt`, `FileOpeningTest.kt`, `app/lib/hub.dart`. |
| 2. Responder | Faltaban serialización, handler, filtro JNI, modelo y UI. Acciones de respuesta en memoria: máximo 50, caducidad de una hora, eliminación al retirar la notificación. Resultados recientes evitan repetir la misma solicitud de transporte. La UI espera un ack del peer y de la notificación correctos; el borrador pertenece a ese teléfono. | `NotifListener.kt`, `ReplyTargets.kt`, `Features.kt`, `ReplyTargetsTest.kt`, `app/rust/src/jni_api.rs`, `app/lib/remote.dart`, `hub.dart`, `ui/notifications.dart`, `app/test/v013_test.dart`. |
| 3. Reproducción PC | Inicio Android omitía el panel. Se reutiliza `MediaPanel` en Inicio y detalles del PC, con watch/unwatch, capacidades opcionales y posición extrapolada. Se conserva volumen en detalles aunque no haya sesión. El horizonte temporal ya cubre los informes cada 10 segundos del daemon. | `app/lib/ui/home.dart`, `media.dart`, `pc_details.dart`, `app/lib/pc_remote.dart`, `remote.dart`, `ui/shell.dart`, `daemon/src/remote.rs`, `sys.rs`, `app/test/v013_test.dart`. |
| 4. Laptop → Dispositivos | El mockup carecía de acción. Se añade InkWell con foco y semántica de botón. Usa la navegación existente; no se añade selección automática entre múltiples peers. | `app/lib/ui/home.dart`, `app/test/v013_test.dart`. |
| 5. Arranque y setup | Los inicializadores impedían dibujar el primer frame. Se dibuja primero el intro de 900 ms sin espera mínima, se carga el bloqueo antes de mostrar contenido y luego se ofrece setup omitible. Android recuerda el primer intro; `setupDone` se guarda conservando campos desconocidos del JSON. Se eliminó la solicitud automática de avisos en onCreate. Windows permite elegir inicio con sesión mediante HKCU. | `app/lib/main.dart`, `hub.dart`, `native.dart`, `ui/setup.dart`, `settings.dart`, `shell.dart`, `MainActivity.kt`, `app/windows/runner/flutter_window.cpp`, `res/drawable/alero_splash.xml`, ambos `launch_background.xml`, `res/values-v31/styles.xml`, `values-night-v31/styles.xml`, `app/test/v013_test.dart`. |
| 6. Conteos | Storage fijaba cero y SAF reutilizaba COLUMN_SIZE. Se cuentan hijos en el pool existente, hasta 1000; ilegible es -1. La UI muestra «—» o «999+ elementos». | `Files.kt`, `StoragePaths.kt`, `StoragePathsTest.kt`, `app/lib/fs_client.dart`, `ui/explorer.dart`, `app/test/v013_test.dart`. |
| 7. Papelera | La búsqueda inicial no encontró uso ni creación de .trash-storage en el repo. StoragePaths ahora deniega esa ruta y cualquier descendiente; el listado pasa por la misma validación. No se ocultan otras carpetas ni se borra la papelera. | `StoragePaths.kt`, `StoragePathsTest.kt`; el filtro se aplica desde `Files.kt`. |
| 8. Memoria | Se cierran listas y miniaturas del explorador al salir, se cancelan sus timers, se evitan copias de la cola de una página Android, se descarta el cache al terminar la paginación y ante trim de memoria, se reciclan bitmaps temporales y se limpian imágenes al minimizar Windows. La miniatura del teléfono ahora cierra codecs y libera imágenes reemplazadas, vaciadas o que llegan cuando el widget ya no las necesita. Se suspenden suscripciones de media en segundo plano. | `app/lib/fs_client.dart`, `ui/explorer.dart`, `ui/shell.dart`, `pc_remote.dart`, `ui/media.dart`, `Files.kt`, `MainActivity.kt`, `NotifListener.kt`, `app/test/v013_test.dart`, `app/lib/ui/expressive.dart`, `app/test/image_lifetime_test.dart`. |

Versión actualizada en `app/pubspec.yaml` y `app/lib/app_info.dart`; notas en `CHANGELOG.md` y `CHECKLIST.md`.

## Verificación

- `cargo test --locked --workspace`: aprobado; el workspace no contiene casos Rust, por lo que este resultado valida compilación y objetivos/doc-tests.
- `flutter analyze --no-pub`: cero incidencias.
- `flutter test --no-pub`: 21 pruebas aprobadas. Incluyen ack y errores, peers antiguos, timeout, borradores por teléfono, controles según capacidades, watch/unwatch, offline, navegación, limpieza de 3000 entradas y miniaturas, liberación de imágenes reemplazadas y setup a 320 px, texto 150 % y movimiento reducido.
- Kotlin: cinco pruebas aprobadas con JUnitCore sobre las clases compiladas por Gradle. Incluyen N hijos, carpeta vacía, cap, carpeta con listado realmente denegado mediante ACL temporal restaurada, MIME, expiración/tope y rutas. El worker local `testDebugUnitTest` falla al cargar GradleWorkerMain; no se presenta como aprobado. `compileDebugUnitTestKotlin` sí pasó.
- Windows y APK ARM64: compilaciones release intermedias aprobadas; certificado Android SHA-256 idéntico a 0.1.2, paquete `dev.alero.app`, versión 0.1.3 y código 4. Actualización con `adb install -r`, sin limpiar datos.
- Windows: setup completo, retorno directo a Inicio tras reiniciar y conservación del peer comprobados visualmente. El inspector web no se aplica a Flutter nativo: se utilizaron capturas nativas y tests de widgets.
- Compatibilidad real: PC 0.1.3 con móvil 0.1.2; después PC 0.1.2 con móvil 0.1.3. Exploración y transferencias sintéticas completadas. El cliente antiguo también leyó el listado real de 3000 archivos.
- Sonda sobre el Pixel: listado de storage con conteos no nulos y denegación directa de `.trash-storage` comprobados mediante el protocolo. No se modificó contenido de carpetas preexistentes.

## RAM medida

Unidades: MiB. Windows: Working Set / Private Bytes, obtenidos del proceso de la app y del daemon por separado. Serie repetida con procesos recién iniciados y ventana de 900 × 680, sin redimensionar; Android 0.1.3 sirve a ambos clientes Windows. Las bibliotecas de fotos tenían 177 elementos en esta serie. La carpeta grande contiene 3000 archivos vacíos generados para la prueba. Las transferencias usan 128 MiB sintéticos.

| Escenario | App 0.1.2 WS / Private | App 0.1.3 WS / Private | Daemon 0.1.2 WS / Private | Daemon 0.1.3 WS / Private |
| --- | ---: | ---: | ---: | ---: |
| Inicio, reposo | 173.3 / 171.3 | 183.0 / 187.6 | 18.1 / 3.7 | 18.1 / 3.6 |
| Explorador, 177 fotos | 183.0 / 181.2 | 196.8 / 194.5 | 18.1 / 3.6 | 18.2 / 3.6 |
| Explorador, 3000 archivos vacíos | 187.9 / 185.2 | 247.4 / 243.7 | 18.4 / 3.8 | 16.8 / 4.2 |
| Minimizado, tras explorar | 183.0 / 181.2 | 203.4 / 200.0 | 18.1 / 3.6 | 18.2 / 3.6 |
| Transferencia sintética, 128 MiB | 185.1 / 182.7 | 202.6 / 200.1 | 19.3 / 4.8 | 19.4 / 5.0 |


El proceso inicial con uso acumulado mostraba 307.5 / 301.0 MiB en Inicio y 325.8 / 319.9 MiB durante transferencia. Esas muestras se conservan en los datos originales, pero no se comparan con un proceso recién abierto para atribuir un supuesto ahorro al código.

Android, `adb shell dumpsys meminfo dev.alero.app`. Se muestran PSS, RSS y Swap PSS separados; no se suman. La base 0.1.2 se midió antes de actualizar el dispositivo; las lecturas posteriores incluyen el arranque de 0.1.3 y distinta presión de swap. Son muestras observacionales, no una medición aislada de cada optimización.

| Escenario | 0.1.2 PSS / RSS / Swap PSS | 0.1.3 PSS / RSS / Swap PSS |
| --- | ---: | ---: |
| Inicio, reposo | 74.0 / 142.1 / 42.7 | 108.4 / 151.8 / 61.1 |
| Explorador, 177 fotos | 74.8 / 141.2 / 42.0 | 106.7 / 149.6 / 61.5 |
| Explorador, 3000 archivos vacíos | No medido | 100.2 / 159.1 / 52.8 |
| Minimizado, tras explorar | 77.3 / 145.4 / 40.4 | 105.7 / 147.6 / 62.2 |
| Transferencia sintética, 128 MiB | 77.1 / 151.2 / 38.7 | 107.1 / 149.1 / 62.0 |


No se dispone de una lectura Android 0.1.2 con la carpeta sintética de 3000 archivos: se creó después de actualizar el teléfono. No se rebajó la app ni se borraron datos para fabricar esa comparación. Los valores completos de cada escenario están en `packaging/RAM-0.1.3.json`.

Comprobación cuantitativa de retención: el test de FsClient pasa de 3000 entradas a 0 al cerrar, de una miniatura almacenada a ninguna y deja de emitir solicitudes tras cancelar timers. El recorrido Android de una página deja de copiar la cola completa: recorre como máximo PAGE=300 entradas. El test de la miniatura comprueba que tres imágenes quedan liberadas al reemplazar, vaciar y desmontar, y el codec se cierra en finally. Eso prueba el límite/vida de esos objetos; no prueba una bajada equivalente del Working Set. No se adjudica una cifra de ahorro independiente a reciclado de bitmaps o descarte de cachés porque no se aislaron en un ensayo A/B.

## Revisión de RAM que no produjo cambios especulativos

Se revisaron `core/src/engine.rs`, la paginación y los timers. El daemon tiene pocos MiB de Private Bytes en estos escenarios. No se redujeron stacks, buffers de transferencia, tamaño global del imageCache, fuentes ni colas del motor sin una medida que justificase el cambio. La cola de msg_worker continúa sin un tope explícito; sigue pendiente probar saturación sostenida. GridView/ListView ya eran virtualizados. `cacheWidth` ya se aplica en las miniaturas grandes y el stream de pantalla; ScreenFeed detiene timers y libera el JPEG al salir o pasar a segundo plano. El tree shaking de iconos se mantiene en release.

## Riesgos y pruebas manuales pendientes

- Regenerar los paquetes desde las fuentes finales y retirar los fixtures propios cuando el usuario reanude la validación.

- Instalar un APK recibido tocándolo en la app: conceder/rechazar «Instalar apps desconocidas», volver del ajuste, ausencia de instalador y archivo retirado. La actualización por adb no sustituye este recorrido.
- Enviar una respuesta real a una app de mensajería, con origen cerrado, notificación retirada y permiso revocado. No se enviaron mensajes a contactos durante la prueba. El ack confirma PendingIntent.send, no la entrega al destinatario.
- Ver y controlar una sesión real del PC desde Inicio Android; las capacidades, suscripciones y UI se validaron con pruebas y compilación WinRT, pero no con reproducción humana completa en el teléfono.
- Revisar visualmente el splash/setup Android y otorgar sus permisos especiales; la captura se omitió cuando Alero dejó de ser la ventana enfocada. Verificar además escala y reducción de movimiento del sistema real.
- SAF con proveedor lento o permiso revocado y folders con miles de subcarpetas; los conteos están acotados y se hacen fuera del hilo UI, pero pueden retrasar la respuesta de un proveedor.
- Si Android destruye la Activity mientras se concede permiso de instalación, habrá que volver a tocar el archivo: el intento pendiente solo vive en esa Activity.
- La reducción global de RAM permanece sin demostrar. Faltan perfiles pareados y atribución por optimización; no se declara una reducción porcentual ni que se haya resuelto todo el consumo de Flutter.
- Al ocultar `.trash-storage`, Alero no permite vaciarla ni liberar ese espacio; el usuario debe usar la app que la administra o su gestor de archivos. No se escondieron otras carpetas de papelera.

Las APIs de instalación y splash siguen la documentación de [PackageManager](https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls()) y [Splash Screen](https://developer.android.com/develop/ui/views/launch/splash-screen). Las respuestas usan RemoteInput y PendingIntent del sistema.

## Tapa trasera, carga y estabilidad de la conexión (añadido el 31 de octubre de 2026)

- Pruebas: `flutter test` 31 (10 de `app/test/device_image_test.dart`), `ChargePowerTest` 4 con JUnitCore, `cargo test` (incluye `media_state_survives_its_thread_exiting`).
- Consulta real a Commons y a la lista de Google: tapa PNG/SVG exacta para Pixel 7, 8, 9 y 9a; ninguna para Galaxy S23/S24, Redmi Note 13, Moto G54, Nothing Phone (2) ni OnePlus 9 (solo hay fotos, descartadas). Una foto titulada «Galaxy S24» era un S24 Ultra y un teléfono inexistente recibió imagen al buscar su código de modelo: ambos casos corregidos.
- Pixel 9a (Android 17): «Google Pixel 9a» y su tapa en el panel lateral; el cuadro de Inicio sin cambios. El Pixel al 80 % marca ±5 mA (se mostraba 23 W por tomar mA); ahora «Batería mantenida». 8,996 W calculados de la lectura real 2,086 A × 4,313 V.
- Causas de desconexión halladas: (1) el `adb` incluido (1.0.41) y el del sistema (1.0.32) se mataban el servidor al ejecutarse y con él los túneles USB — comprobado con `forward --list` vacío; ahora el túnel se abre y repara con el protocolo del servidor ya activo (probado contra ambas versiones); (2) en una red «Pública» Windows bloquea el UDP entrante y no hay reglas de firewall de Alero: el PC dejaba de marcar al teléfono a los 90 s; ahora reintenta la última dirección cada ≤ 30 s; (3) `alero_daemon.exe` terminó 4 veces hoy con 0xc0000005 en la llamada WinRT de multimedia; se mantiene un hilo MTA vivo (no pude reproducir el fallo aislado, así que no está demostrado que sea la única causa) y la app relanza el daemon si muere (probado: daemon terminado, relanzado en menos de 10 s y teléfono otra vez «Conectado»).
- Pendiente: probar la reconexión tras un corte largo de Wi-Fi con la versión final (el teléfono en ese momento no respondía en Wi-Fi: RSSI −68 dBm, 2,4 GHz).
