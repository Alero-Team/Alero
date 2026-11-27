# Cambios

## 3.0 (3.0.0) — 2026-11-27

The first stable release of Alero. Install the Android APK and the Windows or Linux package from this version together.

### Sending files

- **One animation everywhere:** the island, the computer app and the phone draw the same send. The receiving device fills like a glass as the bytes arrive and a tick pops on its screen at the end. A file dragged toward the closed island shows the same phone, small.
- Files dropped while a send is going join it instead of restarting it, and the card waits for all of them.
- **Android:** sharing from other apps opens the picker at once, refreshes the connected computers and keeps the send confirmation. Cloud files are read once, off the main thread and without filling the storage; files that cannot be read say so.

### Alero Island (Windows and Linux)

- **Claude Code and Codex:** shown as working from their own session logs instead of CPU use, so opening them no longer says "working" or "finished" at random, and closing one mid-reply does not count as finished. A minimal mode with its own switch keeps only the creature, which hops back into the notch when it leaves.
- Previews for any file, and the computer's own controls and downloads when no phone is connected.
- The empty clipboard hint sits centred under its button.

### App

- **File explorer:** a double-click only previews. Select with a long press and drag across more files; Escape clears the selection, and Select all is in the selection bar.
- **Devices:** Connect, Disconnect and Delete sit on each device's row, all the same size.
- The selected option of every segmented control (resolution, quality, frame rate, orientation) is clearly marked.
- **Start-up:** the logo breathes calmly while Alero loads. On Android, motion is calmer (25 % slower).
- Fixes to page transitions, the conversation counter and opening previews from the explorer.

### Security

- Thumbnails of files received from the phone no longer go through third-party Windows preview handlers (only Explorer's own cache), at most two at a time.

## Beta 2.6.3 (2.6.3) — 2026-11-25

Install the Android APK and the Windows or Linux package from this version together.

### Alero Island (Windows and Linux)

- **Calls like on the iPhone:** an answered call folds into a compact island with a pulse and the call timer; hanging up shows "Call ended" with its length. Answer, decline, hang up and mute work from the island (Android answers through the system's call service, which background apps are allowed to use).
- **Signal and other VoIP apps:** a call notification that is replaced while the call goes on no longer restarts the timer.
- **Compact player:** it steps back after a few seconds even when the player re-announces the same song, fades out instead of vanishing, and a card opening over it cross-fades instead of leaving an empty pill. The equalizer runs every frame on whole pixels (it dropped to ~9 fps and bars looked uneven).
- **Notifications:** chats show the sender's photo with the app's logo on its corner. Moving the pointer to a notification opens the island on Notificaciones at once.
- **Received files:** a photo shows a preview; any file offers Open, Folder and Discard (Discard deletes only the computer's copy).
- **Primary monitor by default:** with several screens the island appears on the main one. Contact names no longer show invisible direction marks as boxes.

### Android

- **File explorer:** double-click (or "Preview") shows a photo or video large and any other file with its details, then Delete, Rename, Download or Open on the computer.
- **Remote control card:** shows the computer's real desktop wallpaper (it follows changes) with a slow drift and touchpad taps instead of the wandering pointer.
- **Now playing from a computer:** the player's logo and its plain name ("Spotify", "Firefox") instead of its system ID.
- **Phone wallpaper on the computer:** the phone sends its actual home-screen wallpaper when it can read it ("All folders" access), else the picked image or the stock one; the picked image is now actually sent.

### Computer

- The computer sends its current wallpaper (Windows, KDE Plasma, GNOME) instead of the stock picture, and again when it changes.

## Beta 2.6.2 (2.6.2) — 2026-11-24

Install the Android APK and the Windows or Linux package from this version together.

### Alero Island (Windows and Linux)

- **No click afterimage:** removed the 0.55-second ink ripple. Buttons show their pressed state immediately and clear it on release.
- **No outer shadow:** removed the blurred shadow and its rendering buffers.
- **Lighter transitions:** content fades without rescaling every frame; the island keeps its size animation. After a long missed frame, springs settle instead of replaying stale motion.
- **Windows under load:** reuse the native bitmap as the island changes size instead of reallocating it every frame; pace frames at the monitor refresh rate without blocking on DWM when other apps occupy the GPU.
- Includes the Island, streaming-source and Android fixes prepared for 2.6.1, which was built privately but not published.

## Beta 2.6.1 (2.6.1) — 2026-11-24

Install the Android APK and the Windows or Linux package from this version together.

### Alero Island (Windows and Linux)

- **Smoother animation:** the compositor processes only the visible content, skips shadow pixels hidden by the card and uses SIMD rasterization. The daemon is optimized for speed while keeping the existing animation styles.
- **No cover decoding during animation:** album covers are prepared off the rendering thread. Common symbols and emoji no longer trigger loading large language font collections first.
- **Player controls stay inside the card:** the expanded player leaves enough bottom space for its playback and volume buttons.
- **Streaming sources only:** supported music and video players and streaming websites can open the media island. WhatsApp voice messages, TikTok and unidentified audio sources do not trigger it.

### Android

- **Devices:** removed the send shortcut from paired-device cards; connection and forget actions remain available.
- **Album covers:** image dimensions are read from metadata without decoding the full image just to size the player; asynchronous updates are discarded when their widget has been disposed.

### Development and releases

- Checks and package builds run in the private repository. All Windows, Android and Linux packages must pass the private pipeline before their source snapshot and existing artifacts can be promoted to the public release repository.

## Beta 2.6 (2.6.0) — 2026-11-23

Install the Android APK and the Windows or Linux package from this version together.

### Everywhere

- **Updates inside Alero:** on opening, Alero checks the latest public release and offers "Actualizar ahora". The download shows its progress and is checked against the SHA-256 that GitHub publishes before anything is installed. Android hands the APK to the system installer; Windows runs the setup silently and opens Alero again; Linux replaces the AppImage, or opens the .deb/.rpm in the system installer. Settings › About has a switch to check on opening (on by default) and a "Buscar actualizaciones" button.
- **Lighter motion on modest hardware:** on machines with four cores or fewer, and whenever the system asks for reduced motion, the decorative movements (staggered entrances, sections fading up, the player's wave) are skipped; page changes, presses and switches still animate. Nothing changes on faster devices.

### Android

- **Fluent icons, as on the computer:** the phone uses the same Fluent UI System Icons as Windows and Linux again (outlined at rest, filled when selected), instead of Material ones.
- **No pinned header:** the page title scrolls away with the content; the compact title bar that stayed at the top, and the line under it, are gone.

### Alero Island (Windows and Linux)

- **Connect and disconnect alerts:** when a paired device connects or disconnects, the island opens briefly with the phone icon, its name and "Conectado" or "Desconectado", then closes by itself. Quick reconnections show only the final state, alerts of several devices wait their turn, nothing is announced for the devices that connect as Alero starts, and an island you are using is not interrupted. It can be turned off in the island's settings ("Conexión y desconexión de dispositivos").
- **Cover in the closed island:** the music line (and its lyrics) shows the album cover with the playing app's icon on its corner instead of a music note.
- **Lyrics and progress keep moving:** the player's progress bar no longer stops at 0:15 and synced lyrics follow the song again, for music on the computer and on the phone.

## Beta 2.5.1 (2.5.1) — 2026-11-23

Install the Android APK and the Windows or Linux package from this version together.

### Everywhere

- **No more outlines on cards:** cards, chips, filters, the sound selector, outlined buttons, dialogs and the floating navigation pill no longer draw a border, in every theme (light, dark, AMOLED and Material 3 Expressive). Surfaces now stand apart by tone alone; in AMOLED the cards and their buttons are one step lighter so they still read against pure black. Borders that mark a selection or keyboard focus stay.

### Android

- **Devices › IP address:** the "Emparejar" button now sits level with the address field and matches its height; the hint moved under both.

### Windows and Linux

- **Phone card in the side menu:** Google phones show the four-color Google G instead of a plain blue letter, and the card shows the phone's name next to the logo in the theme's text color, readable in light and dark.
- **Quick controls:** the flashlight, lock, rear camera and front camera squares grow to fit their icon and label at every tile size and text scale, so nothing spills out of the square any more (it did with compact tiles).

## Beta 2.5 (2.5.0) — 2026-11-22

Install the Android APK and the Windows or Linux package from this version together.

### Android

- **Material 3 Expressive:** icons are Material on the phone (outlined at rest, filled when selected); choices such as theme and language are connected buttons, where the chosen one fills and rounds and the pressed one widens; Home's quick actions widen under your finger. Existing motion (cards rising in, sections fading up as you scroll, tab changes, the floating bar) is unchanged.
- **New "Estilo de color" in Appearance:** keep Alero's monochrome look or pick Expressive, a tonal palette from your wallpaper or from a fixed color. Both follow light, dark and AMOLED.
- **Player:** the progress bar waves while music plays; video thumbnails (YouTube in a browser, VLC…) are shown whole at 16:9; in the Expressive style the card takes the cover's colors.
- **Battery colors:** the computer's battery icon and bar turn green above 50 %, amber from 21 to 50 % and red at 20 % or less, and green with "charging" while plugged in.

### Windows and Linux

- **Phone controls in color:** each control takes its own color when on (Wi-Fi blue, Bluetooth indigo, Do Not Disturb violet, flashlight amber…), growing from where you clicked; the tile rounds a little more when on.
- **Battery and storage by color:** green, amber or red depending on the phone's battery level and how full its storage is.
- **Player:** the card takes the colors of the cover that is playing, and one volume button stretches into a slider (the bar thickens and the value shows while you drag).
- **Side menu:** the phone card at the bottom shows only the maker's mark with a connection dot; the phone itself, with its wallpaper, is on Home.
- **Sections fade up as you scroll,** as on Android. Every other animation (the folding menu, cards rising in, the sliding selection, dialogs, toasts) is unchanged.

### Everywhere

- **Reconnecting takes one tap:** after "Desconectar" on one device, "Conectar" on either device brings the pair back.
- **Pairing again after "Olvidar" asks only once:** the device that still trusts the other accepts by itself; only the one that forgot confirms the code.
- **System language:** "Sistema" follows a language change while Alero is open, and the Windows background service (tray, notifications, Alero Island) now reads the Windows display language instead of defaulting to Spanish.

## Beta 2 (2.0.0) — 2026-11-22

Install the Android APK and the Windows or Linux package from this version together.

### Android

- **Sections fade up as you scroll:** cards and panels on Home, Devices and Settings rise into place each time they come into view, from the side they enter (from below when scrolling down, from above when scrolling back up), in a soft cascade.
- **Collapsing title:** the large page title fades out as you scroll and a compact title slides into a pinned bar, switching at the same moment as the bottom navigation pill.
- **Clipboard button on Home:** the icon is centred properly and the label shrinks to fit instead of being cut off.

### Windows and Linux

- **Side menu folds smoothly:** collapsing and expanding the menu runs on a soft spring with a slight bounce, and the cards resize with it instead of jumping to their final size.
- Names fade and slide, group titles fold into a thin line, unread counters turn into a dot on the icon and the toggle icon cross-fades; the selected highlight stays with its item.

### Alero Island

- **New player:** drag the progress bar to move through the song (computer and phone). The speaker button stretches into a volume slider (the computer's output, or the phone's media volume); the mouse wheel over the player works too.
- **Lyrics:** for Spotify, YouTube Music, Tidal, Apple Music and Deezer, a lyrics button shows synced lyrics in a second column of the player. While lyrics are on, the closed island keeps showing the line being sung and the whole island takes the colours of the album cover. Lyrics come from LRCLIB (lrclib.net) and are only requested when you turn them on: the song's title, artist and length are sent, nothing else.
- **The closed island behaves as before otherwise:** music still appears for a few seconds when a song starts or changes, then the island goes back to its slim tab.
- **Touch feedback:** every button answers with a ripple from where you touched it.
- **Phone controls:** a tile's colour grows from the point you touched when it turns on and shrinks back to it when it turns off; the icon jumps, and the flashlight gives a warm glow.
- **Clipboard:** copying turns the copy icon into a check, the row turns green and "Copied" slides in; "Send my clipboard" swaps to "Sent to the phone".
- **Notifications:** dismissing slides the notification out and the others glide up (you can also drag it to the right). New buttons mark a notification as read and reply to chats right from the island, with quick replies or your own text.
- **Dragging files:** the closed island reaches out to a file you carry towards it, a light runs round the drop target while the file is over it, and dropping lands with a soft squash, a pop and two rings before the transfer starts.

### Performance

- **Windows:** while open, the island's window is cut to the island and its shadow, so far fewer pixels go to the compositor.
- **Windows and Linux:** with the pointer far from the top of the screen, Alero Island wakes 10 times a second instead of 25.
- **Linux:** the island waits for X11 events instead of waking every 20 ms to check, and Alero keeps a single session-bus connection for media instead of opening a new one every second.
- **Android:** with the screen off, the media-session check runs every 20 seconds instead of every 2 (changes still arrive immediately). Decoded images are released when Alero goes to the background.
- **Computer app:** no network-diagnostics polling while the window is minimised or hidden in the tray.

## Beta 1.4.10 (1.4.10) — 2026-11-21

Install the Android APK and the Windows or Linux package from this version together. This is a performance release for Alero Island on Windows; nothing changes on Android.

### Windows

- **Lower idle cost for Alero Island:** the island now uses far less CPU while it sits closed or nothing is playing.
- **Media:** Alero keeps a single media session manager and wakes on its change events instead of asking Windows for a new one every second. A 5-second poll stays as a fallback.
- **Player updates:** the player state is sent to the island only when something the island draws has changed.
- **Closed island:** the layered window shrinks to the notch and its shadow while the island is closed.
- **Always on top:** the island re-asserts its topmost position only when a visible topmost window actually covers it, and backs off if another program keeps taking the top.

## Beta 1.4.9 (1.4.9) — 2026-11-19

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión.

### Toda la app

- **Iconos nuevos, los mismos en todas partes:** la app, Alero Island, el widget de Android y los avisos de transferencia usan ahora Fluent UI System Icons (Microsoft, MIT). La isla dibuja exactamente los mismos glifos que la app, y un icono seleccionado o encendido pasa a su versión rellena.
- **Pantalla de carga:** el logo ya no se queda quieto tras la entrada; un trazo de luz lo recorre hasta que Alero termina de cargar (sin bucle con «reducir animaciones»).
- **Tipos de archivo más claros en modo oscuro:** cada tipo tiene un color vivo (imagen azul, vídeo naranja, audio rosa, documento rojo, hoja de cálculo verde, comprimido ámbar, APK lima).
- **Controles del teléfono:** se quita «Reproducción en el teléfono» de «Controles avanzados»; el reproductor de Inicio sigue igual.

### Alero Island

- **Controles a tu medida:** en Ajustes › Alero Island › Controles del teléfono, arrastra para ordenar y enciende los que quieras (hasta 12, tres filas). Están todas las acciones de la app: además de las de antes, Zona Wi-Fi, cámara trasera y frontal, Ver pantalla, Captura, Silenciar y Portapapeles.
- Las cámaras, Ver pantalla y Captura las hace la app igual que su botón; si está cerrada, la isla la abre.
- «Buscar» usa el mismo icono que en la app y la isla es un poco más alta para caber tres filas.

### English

#### Whole app

- **New icons, the same everywhere:** the app, Alero Island, the Android widget and transfer notifications now use Fluent UI System Icons (Microsoft, MIT). The island draws exactly the same glyphs as the app, and a selected or switched-on icon turns into its filled version.
- **Loading screen:** the logo no longer stops after its entrance; a trace of light runs along it until Alero has finished loading (no loop with "reduce animations").
- **Clearer file types in dark mode:** each type gets a vivid colour (image blue, video orange, audio pink, document red, spreadsheet green, archive amber, APK lime).
- **Phone controls:** "Playback on the phone" is gone from "Advanced controls"; the Home player stays as it was.

#### Alero Island

- **Controls your way:** in Settings › Alero Island › Phone controls, drag to reorder and turn on the ones you want (up to 12, three rows). Every action of the app is there: besides the earlier ones, Hotspot, rear and front camera, View screen, Screenshot, Mute and Clipboard.
- The cameras, View screen and Screenshot are carried out by the app, just like its own buttons; if it is closed, the island opens it.
- "Find" uses the same icon as the app, and the island is a little taller to fit three rows.

## Beta 1.4.8 (1.4.8) — 2026-11-19

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión.

### Windows

- **Juegos con Alero abierto:** la isla se oculta también con juegos en ventana sin bordes (borderless), no solo en pantalla completa exclusiva, y deja de disputarles el primer plano. Con la isla encima, Windows no podía mostrar el juego directamente y se perdían FPS y G-Sync.

### Toda la app

- **Animaciones en todo:** botones y tarjetas reaccionan al pasar el ratón y al pulsar; menús, hojas y avisos aparecen con movimiento; los cambios de contenido, listas, paneles desplegables, progreso y valores se animan en lugar de saltar. Todo a velocidad normal (1×) y respetando «reducir animaciones» del sistema.
- **Selectores deslizantes** en Ajustes, el panel de la isla y la conexión ADB: la opción elegida se marca con una píldora que se desliza.
- **Controles del teléfono:** las acciones (cámaras, ver pantalla, captura, rotación, linterna, bloquear, portapapeles) son ahora botones cuadrados del mismo tamaño.
- **Inicio más fluido:** el reproductor y las notificaciones solo se redibujan cuando cambian.

## Beta 1.4.7 (1.4.7) — 2026-11-18

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión.

### Android

- **Zoom al ver la pantalla del ordenador:** pellizca la imagen o usa la lupa de la barra (hasta 4×); al acercar, la vista sigue al puntero.
- **El teclado del ordenador ya no pierde lo escrito** al cerrarlo, pasar al panel táctil o cambiar de teclado en el teléfono; corregir en medio de una frase cambia solo esa parte en el ordenador, y la X vacía el campo sin borrar nada allí.
- **Apagar el ordenador desde el teléfono:** en el control remoto, junto a Bloquear y Suspender, hay un botón «Apagar» que pide confirmación. En Windows apaga como Inicio › Apagar; en Linux usa el apagado de Plasma (cierra las apps y guarda la sesión) y, si no hay Plasma, el del sistema.

### Windows y Linux

- **Alero Island muestra el icono de la app que suena** (Spotify, YouTube, el navegador), del PC o del teléfono.
- **Las ofertas de archivos se responden en la isla** cuando se abre sola para ellas; la ventana de Alero ya no aparece después repitiendo la misma pregunta.
- **Atajo de la isla grabándolo:** pulsa «Grabar atajo» y la combinación que quieras, en lugar de escribirla.
- En paneles estrechos cada ajuste baja bajo su título en vez de apretarse a su lado, y los botones con texto largo lo ajustan en lugar de cortarlo.

### Linux

- **La isla ya no parpadea al abrirse:** la ventana no cambia de tamaño en cada fotograma de la animación.
- **Las apps bajo la isla o junto a ella vuelven a responder:** los clics atraviesan la muesca y su sombra; solo la isla abierta bajo el puntero los toma (como en Windows).
- En pantallas HiDPI usa la sesión **Plasma (Wayland)**: X11 no escala y todo se ve pequeño. Alero funciona igual en Wayland.

## Beta 1.4.6 (1.4.6) — 2026-11-17

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión. Reemplaza a la Beta 1.4.5, que se retiró: la isla vuelve a su diseño de muesca con resortes, ahora mucho más fluida.

### Windows y Linux

- **Alero Island como una muesca:** cuelga del borde superior con esquinas cóncavas que la funden con la pantalla, y en reposo deja una lengüeta fina visible para saber dónde está; al acercar el ratón se ensancha un poco.
- **Actividades en vivo, como la Dynamic Island:** cuando empieza a sonar algo (en el PC o en el teléfono) o cambia la canción, la muesca muestra unos segundos la carátula y un ecualizador animado; al enchufar el teléfono, el rayo y el porcentaje de carga. Luego vuelve a su tamaño.
- **Mucho más fluida:** cada fotograma se dibuja unas 7 veces más rápido (5 ms animando, 2 ms en reposo) y sigue usando unos pocos MB de memoria.
- **Ya no tapa lo que hay debajo:** los clics pasan a la ventana de abajo salvo cuando el puntero está sobre la isla abierta.
- **Estilo de Alero:** acento blanco monocromo por defecto y textos más grandes que se ajustan a la pantalla; portada con proporciones más cómodas.
- **La foto del teléfono** en la isla, la misma que muestra la app.
- **Notificaciones con el icono de su app**, centradas; tu propia respuesta a un chat ya no abre la isla como si fuera un mensaje nuevo.
- **Enviar archivos soltándolos en la isla** muestra la tarjeta de progreso.
- **Reproductor:** selector «Este equipo / Teléfono» siempre visible; la isla pide al teléfono lo que suena si Alero arrancó después de conectarse.
- **Controles del teléfono a tu elección** (Ajustes › Alero Island): No molestar, linterna, buscar, sonido y, con la depuración inalámbrica activa, Wi-Fi, Bluetooth, rotación y bloquear.
- Se mantiene encima de las demás ventanas y no desaparece después de cerrarse.

### Toda la app

- **Animaciones en todas partes:** las páginas se abren creciendo con un resorte, los diálogos entran con rebote, las tarjetas aparecen subiendo y se adaptan con suavidad cuando cambia su contenido, y las filas de ajustes responden al pulsarlas.
- **Redimensionar sin parpadeos:** al contraer o abrir el menú la página se desliza en vez de recalcularse en cada fotograma, y al cambiar el tamaño de la ventana las tarjetas siguen al ratón sin repetir animaciones.
- Los botones de la tarjeta del teléfono bajan a otra fila cuando no caben, en lugar de encoger su texto.
- **Mensajes:** botón para adjuntar archivos en un chat.

### Android

- **El mosaico de Ajustes rápidos** abre directamente el selector de archivos y los envía al ordenador conectado.
- **«Compartir» en la notificación de un archivo recibido:** lo pasa a cualquier app, por ejemplo al chat desde el que lo enviaste con Alero.

### English

Install the Android APK and the Windows or Linux package from this version together. It replaces Beta 1.4.5, which was withdrawn: the island goes back to its spring-driven notch design, now far smoother.

#### Windows and Linux

- **Alero Island as a notch:** it hangs from the top edge with concave corners that blend it into the screen, and at rest a thin tab stays visible so you know where it is; it widens a little as the pointer comes near.
- **Live activities, like the Dynamic Island:** when something starts playing (on the PC or the phone) or the song changes, the notch shows the cover and an animated equalizer for a few seconds; when you plug the phone in, the bolt and its charge. Then it shrinks back.
- **Much smoother:** each frame is drawn about 7 times faster (5 ms animating, 2 ms at rest) and it still uses a few MB of memory.
- **No longer blocks what is below:** clicks go through to the window underneath unless the pointer is on the open island.
- **Alero's look:** a monochrome white accent by default and larger text that fits the screen; a home view with more comfortable proportions.
- **The phone's picture** in the island, the same one the app shows.
- **Notifications with their app's icon**, centred; your own reply in a chat no longer opens the island as if it were a new message.
- **Dropping files on the island** shows the progress card.
- **Player:** a "This computer / Phone" switch always on screen; the island asks the phone what is playing if Alero started after it connected.
- **Phone controls of your choice** (Settings › Alero Island): Do not disturb, flashlight, find, sound and, with wireless debugging on, Wi-Fi, Bluetooth, rotation and lock.
- It stays above other windows and no longer disappears after closing.

#### The whole app

- **Animations everywhere:** pages open growing on a spring, dialogs come in with a bounce, cards rise into place and adapt smoothly when their content changes, and settings rows respond when pressed.
- **Resizing without flicker:** folding or opening the menu slides the page instead of recalculating it every frame, and resizing the window keeps the cards with the pointer without replaying animations.
- The phone card's buttons move to another row when they do not fit, instead of shrinking their text.
- **Messages:** a button to attach files in a chat.

#### Android

- **The Quick Settings tile** opens the file picker straight away and sends the files to the connected computer.
- **"Share" on a received file's notification:** hands it to any app, for example the chat you sent it from with Alero.

## Beta 1.4.4 (1.4.4) — 2026-11-17

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión.

### Windows y Linux

- **Nuevo: Alero Island.** Una isla negra (OLED) que baja desde el borde superior de la pantalla cuando pasas el ratón por el centro y se esconde sola al irte. Se abre y se cierra con animaciones de resorte inspiradas en la Dynamic Island de iOS (desenfoque, escala y morfología de tamaño entre pantallas) y no consume nada mientras está cerrada.
- **Solo funciones de Alero:** reproductor (de este equipo o del teléfono), enviar archivos arrastrándolos a la isla (el teléfono recibe la petición de aceptar), archivos entrantes con Aceptar y Rechazar, notificaciones del teléfono, llamada entrante con Contestar y Rechazar, portapapeles, controles rápidos (No molestar, linterna, buscar mi teléfono, sonido y volumen) y estado y batería del teléfono.
- **Se avisa sola:** una llamada, un archivo entrante o una notificación abren la isla un momento aunque la ventana de Alero esté cerrada.
- **Totalmente configurable** en Ajustes › Alero Island: activar o desactivar, color de fondo (negro OLED por defecto) y de acento, tamaño, animaciones normales, suaves o ninguna (respeta «reducir animaciones» de Windows), pantalla, ancho de la zona de activación, esperas de apertura y cierre, desplazamiento, margen superior, qué módulos muestra, segundos visible, sonido y ocultarse con juegos y apps a pantalla completa. En Windows, atajo de teclado opcional.
- **Linux:** funciona en X11 (y XWayland). En sesiones Wayland puras no hay forma de saber dónde está el puntero, así que no aparece. El atajo de teclado global es solo de Windows por ahora.

### English

Install the Android APK and the Windows or Linux package from this version together.

#### Windows and Linux

- **New: Alero Island.** A black (OLED) island that drops from the top edge of the screen when you move the pointer to the centre and tucks itself away when you leave. It opens and closes with spring animations inspired by the iOS Dynamic Island (blur, scale and size morphing between screens) and costs nothing while closed.
- **Only Alero's features:** player (this computer's or the phone's), send files by dragging them onto the island (the phone gets the accept request), incoming files with Accept and Decline, phone notifications, incoming call with Answer and Decline, clipboard, quick controls (Do not disturb, flashlight, find my phone, sound and volume) and phone status and battery.
- **It alerts by itself:** a call, an incoming file or a notification opens the island for a moment even when Alero's window is closed.
- **Fully configurable** in Settings › Alero Island: on or off, background colour (OLED black by default) and accent, size, normal, soft or no animations (follows Windows' "reduce animations"), screen, trigger-zone width, open and close delays, offset, top margin, which modules it shows, seconds visible, sound and hiding during games and full-screen apps. On Windows, an optional keyboard shortcut.
- **Linux:** works on X11 (and XWayland). On pure Wayland sessions there is no way to know where the pointer is, so it does not appear. The global keyboard shortcut is Windows-only for now.

## Beta 1.4.3 (1.4.3) — 2026-11-15

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión.

### Windows y Linux

- **Vuelve el menú lateral de la 1.4:** se retira la píldora; el menú muestra otra vez el nombre de cada sección, con sus grupos y la tarjeta del dispositivo.

### Windows

- **Inicio con Windows en segundo plano:** el instalador marca por defecto «Iniciar Alero con Windows». Al iniciar sesión Alero arranca solo en la bandeja y conectado, sin abrir la ventana. El interruptor «Abrir Alero al iniciar sesión» usa la misma entrada.

### Android

- **Animaciones más ágiles:** las animaciones del teléfono duran menos y responden antes al toque.

### English

Install the Android APK and the Windows or Linux package from this version together.

#### Windows and Linux

- **The 1.4 side menu is back:** the pill is gone; the menu shows every section's name again, with its groups and the device card.

#### Windows

- **Start with Windows in the background:** the installer enables "Start Alero with Windows" by default. At sign-in Alero starts in the tray and connects, without opening its window. The "Open Alero at sign-in" switch uses the same entry.

#### Android

- **Snappier motion:** phone animations are shorter and react sooner to touch.

## Beta 1.4.2 (1.4.2) — 2026-11-14

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión.

### Windows y Linux

- **Píldora compacta al costado:** el menú lateral es ahora la barra inferior del teléfono girada hacia un lado: una cápsula compacta de iconos, centrada en el borde izquierdo. Usa el mismo aspecto y el mismo muelle que la versión de Android (icono relleno y píldora en el destino elegido); los nombres aparecen al pasar el puntero.

### English

Install the Android APK and the Windows or Linux package from this version together.

#### Windows and Linux

- **Compact pill on the side:** the side menu is now the phone's bottom bar turned on its side: a compact capsule of icons, centred on the left edge. It has the same look and the same spring as the Android version (filled icon and pill on the chosen destination); names show on hover.

## Beta 1.4.1 (1.4.1) — 2026-11-14

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión.

### Windows y Linux

- **Menú en píldora:** el menú lateral es ahora una píldora flotante anclada al borde izquierdo, como la Dynamic Island del iPhone. Con el menú contraído, al pasar el puntero por encima se abre sobre la página sin moverla y se cierra al salir; con «Fijar menú» queda abierto junto a la página. Conserva el mismo muelle y todas las animaciones de siempre.

### English

Install the Android APK and the Windows or Linux package from this version together.

#### Windows and Linux

- **Pill menu:** the side menu is now a floating pill anchored to the left edge, like the iPhone's Dynamic Island. With the menu collapsed, hovering it opens it over the page without moving the page, and it closes when the pointer leaves; "Pin menu" keeps it open beside the page. It keeps the same spring and every existing animation.

## Beta 1.4 (1.4.0) — 2026-11-14

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión.

### Todas

- **Inglés:** Alero ya se puede usar en inglés. En Ajustes → Apariencia → «Idioma / Language» eliges Sistema, Español o English; «Sistema» usa el idioma del dispositivo (cualquier idioma distinto del español se muestra en inglés). El cambio es inmediato y alcanza también las notificaciones, los widgets y los avisos de Android, y las notificaciones y el menú de la bandeja de Windows y Linux.

### Android

- **Barra inferior que se encoge:** al desplazarte por una pantalla la barra se hace más pequeña, y al volver arriba recupera su tamaño con el mismo muelle de las demás animaciones.
- Los nombres de los widgets y el idioma de la app siguen el idioma del dispositivo; el selector de idioma por aplicación de Android también está disponible.

### English

Install the Android APK and the Windows or Linux package from this version together.

#### All

- **English:** Alero can now be used in English. In Settings → Appearance → "Idioma / Language" pick System, Español or English; "System" follows the device language (any language other than Spanish shows English). The change is immediate and also covers Android's notifications, widgets and notices, and the Windows and Linux notifications and tray menu.

#### Android

- **Shrinking bottom bar:** while you scroll a screen the bar gets smaller, and back at the top it returns to its size with the same spring as the rest of the animations.
- Widget names follow the device language, and Android's per-app language picker is available too.

## Beta 1.3.1 (1.3.1) — 2026-11-12

### Windows y Linux

- **Inicio igual en todas las pantallas:** con la escala de Windows al 125 % o en una ventana más pequeña, la tarjeta del dispositivo mantiene la conexión, el almacenamiento y la batería al lado de los botones, en la columna izquierda, en lugar de apilarse y mover el resto de tarjetas.

## Beta 1.3 (1.3.0) — 2026-11-12

Instala juntos el APK de Android y el instalador de Windows o Linux de esta versión.

### Linux (nuevo)

- **Alero para Linux:** paquetes .deb (Debian, Ubuntu), .rpm (Fedora, openSUSE), AppImage y .tar.gz portátil. Incluyen scrcpy y adb, así que no hay que instalar nada más.
- Notificaciones del teléfono, transferencias, portapapeles, multimedia (MPRIS), ratón y teclado desde el teléfono (uinput) y controles del teléfono por ADB, también inalámbrico.
- El teléfono muestra el modelo del equipo y el sistema («Debian GNU/Linux 13 · KDE»).
- Limitación conocida: en Wayland la pantalla del PC en el teléfono se actualiza despacio (menos de 1 imagen por segundo).

### Android

- **Acceso rápido «Alero»** en los ajustes rápidos: añádelo en «Editar» en lugar del de Quick Share; abre Alero como su icono.
- **Tarjetas de transferencia** en la barra de notificaciones, como las de Quick Share, con el progreso en vivo.
- **Varios ordenadores:** en Inicio eliges con qué ordenador trabajas; los widgets y las acciones usan ese.

### Windows

- **Tarjetas de transferencia** con progreso; al terminar, «Abrir» y «Abrir carpeta».

### Todas

- Animación de inicio al abrir la app y transiciones nuevas en la configuración inicial.

## Beta 1.2.1 (1.2.1) — 2026-11-10

Instala juntos el APK de Android y el instalador de Windows: el límite de emparejamiento y los cambios de llamadas necesitan ambos lados.

### Notificaciones (Windows)

- **Diseño nuevo, como Enlace Móvil:** lista limpia con el icono de la app, «App · hora», el nombre en negrita y el mensaje; a la derecha ⋯ y ×. Al pasar el ratón aparecen Responder, Marcar como leído y Silenciar. Arriba, «Historial» y «Borrar todo». El tamaño sigue la pantalla y el tamaño de mosaicos.
- **Responder y listo:** la respuesta se escribe en una barra con el botón de enviar dentro; al enviarla, la notificación se descarta en el teléfono y desaparece de la lista.

### Seguridad (auditoría)

- **Archivos recibidos:** un archivo llamado solo «.bat», «.lnk» u otra extensión ya no recibe el botón «Abrir»; la lista de tipos que no se abren suma Office con macros, temas, Escritorio remoto, instaladores por referencia y similares. Los archivos recibidos en Windows llevan la marca de Internet, así que SmartScreen y la Vista protegida de Office actúan como con una descarga.
- **Desconectar corta de verdad:** un teléfono desconectado ya no puede seguir enviando órdenes (ratón, teclado, bloquear) por la conexión que tenía abierta.
- **Emparejamiento:** como mucho 6 intentos por minuto desde una misma dirección (20 en total), y emparejar con un dispositivo de la lista fija su identidad. Si se supera: «Demasiados intentos… espera un minuto».
- **Olvidar dispositivo es definitivo:** la lista de emparejados se guarda de uno en uno; un anuncio de red a la vez ya no puede devolver un dispositivo olvidado, y un archivo dañado nunca se sobrescribe con una lista vacía.
- **Android:** el registro de llamadas solo se comparte con Llamadas activado, y los contactos con Llamadas o SMS. Desde el ordenador ya no se pueden marcar códigos con * o # (desvíos, PIN de la SIM, USSD).
- **Pedir un archivo:** solo el dispositivo al que se lo pediste puede enviarlo sin pregunta.
- **ADB inalámbrico:** la dirección del teléfono solo se acepta si responde el propio teléfono.
- **Publicación:** la clave de firma de Android solo existe durante el paso que compila el APK, y la publicación comprueba que el APK lleva el certificado de siempre.

## Beta 1.2 (1.2.0) — 2026-11-09

Instala juntos el APK de Android y el instalador de Windows de esta versión: el puntero de la pantalla compartida y el emparejamiento por código necesitan ambos lados actualizados.

### Seguridad

- **Emparejar comparando el código es ahora a prueba de intermediarios.** Antes, un equipo de la misma red que se colocara entre los dos dispositivos podía repetir su parte de la conexión hasta que ambos mostraran el mismo código de 6 dígitos. Ahora cada lado aporta un número al azar y quien inicia se compromete al suyo antes de ver el del otro: el código ya no se puede forzar. Emparejar con el QR no estaba afectado. Los dispositivos ya emparejados siguen igual; para emparejar de nuevo, los dos necesitan esta versión.
- **Alero no ejecuta programas recibidos.** «Abrir» sobre un `.exe`, `.bat`, `.lnk`, `.msi` y similares lo muestra en su carpeta en vez de lanzarlo (los avisos de Windows ya lo hacían; la ventana no).
- Los anuncios de la red local, que no van autenticados, ya no pueden llenar la lista de dispositivos ni cambiar la dirección de un dispositivo con el que estás conectado.
- Android: otra app no puede usar «Compartir con Alero» para apuntar a los archivos privados de Alero.
- El canal local entre la ventana y el servicio corta a quien se conecta y no presenta la clave en 5 segundos.
- La compilación publicada fija por commit la acción de terceros que instala Flutter.

### Envío de archivos

- **El aviso de envío termina.** Se quedaba en «Preparando…» cuando el archivo acababa antes de que el aviso se dibujara. Ahora llega a **Finalizado** y se queda hasta que lo cierras.
- **Vista previa al terminar, en los dos dispositivos:** quien envía y quien recibe ven el archivo (la imagen, si lo es), con Abrir, Ver en carpeta y Copiar (Windows: copia el archivo para pegarlo donde quieras); en Android, Abrir y Ver en Descargas.

### Acceso remoto (ver el teléfono desde el ordenador)

- **La pantalla del teléfono se apaga mientras la ves en el ordenador**, para no tenerla duplicada (se puede desactivar en las opciones). Android no permite mostrar la pantalla siempre activa mientras se transmite; apagada es lo más parecido.
- **Grabar la pantalla ya no acelera el sonido.** Con la ventana abierta, la grabación abría una segunda captura de todo el audio y Android lo reproducía todo al doble de velocidad. Ahora la grabación toma una copia de lo que suena (Android 13 o posterior; en versiones anteriores graba sin sonido mientras la ventana lo tenga).

### Rendimiento en Windows

- Las animaciones usan el renderizador Impeller, que no compila sombreadores la primera vez que algo se mueve, y el icono que responde al toque ya no redibuja una forma nueva en cada fotograma.

### Segunda pantalla

- **Se retira «Extender pantalla».** El controlador de monitor virtual deja su monitor encendido siempre, y no se consiguió encenderlo y apagarlo de forma fiable desde Alero. Si lo instalaste, puedes desinstalarlo desde el Administrador de dispositivos.

### Pantalla compartida (ver el ordenador desde el teléfono)

- **El puntero va por su cuenta**, hasta 60 veces por segundo, y el teléfono lo dibuja encima de la imagen: sigue al dedo aunque la imagen vaya más lenta.
- Hasta 30 fotogramas por segundo (antes 15). Calidades: Fluida 640 px · 30, Equilibrada 960 px · 15, Nítida 1280 px · 8.
- La captura se codifica sin una copia intermedia de cada fotograma.

### Controles del teléfono (Windows)

- **Rediseñados:** cada control es una ficha con su icono, su nombre y su estado (Activado / Desactivado).
- **Controles avanzados**, en un segundo cajón desplegable: Ver pantalla, Captura (guarda la pantalla del teléfono en la carpeta de descargas), Rotación, Silenciar, Buscar teléfono, Portapapeles y los botones de reproducción.
- **Tú eliges cuáles ves y en qué orden** (botón junto a Actualizar): los ocho primeros quedan siempre a la vista.
- El volumen dice su valor y el modo de sonido lleva nombre.

### Notificaciones

- **Tarjetas compactas:** la foto de quien escribe con el icono de la app, el nombre y «app · hora · N mensajes» en una línea, y los dos últimos mensajes debajo (toca la tarjeta para ver más). Responder y Marcar como leído son iconos a la derecha; Silenciar y Descartar, en el menú ⋮. El tamaño se ajusta a la pantalla.
- **Responder y listo:** la respuesta se escribe en una barra con el botón de enviar dentro; al enviarla, la notificación se descarta en el teléfono y desaparece de la lista.

### Alero Vault

- **Bloqueado siempre:** en Android pide la huella o el PIN cada vez que lo abres; en Windows, una clave propia de la bóveda que creas la primera vez. Se vuelve a bloquear al salir de la sección, al minimizar o con el botón del candado.
- **En Windows no funcionaba:** al guardar fallaba siempre porque el cifrado de Windows no llegaba a cargarse. Ahora cifra con tu cuenta de Windows y, además, con tu clave: sin ella los archivos no se abren. Alero no la guarda; si la olvidas no hay forma de recuperar el contenido.
- **Las fotos se ven dentro:** miniatura en la lista y visor propio, sin exportarlas.

### Inicio

- **Personalizar** permite ordenar los mosaicos arrastrándolos y apagar los que no uses, además de cambiar su tamaño. En Windows y en Android.
- **El orden se nota:** en una ventana ancha los primeros mosaicos van a la columna izquierda y el resto a la derecha (antes cada mosaico tenía su columna fija y moverlo entre columnas no cambiaba nada).
- **Historial del portapapeles** dentro del botón Portapapeles: lo que viajó entre los dos dispositivos, a un toque de copiarlo otra vez.
- Los textos de los botones se encogen para caber en vez de partirse o salirse al cambiar el tamaño de los mosaicos.
- **Mosaicos que se adaptan:** sin música el reproductor es una línea; con una transferencia en curso, la actividad muestra su progreso y solo el último resultado, y si no, los tres últimos con «Ver más»; sin notificaciones, una línea discreta.
- **Clic derecho en un archivo de la actividad** (pulsación larga en el teléfono): Abrir, Mostrar en la carpeta, Copiar la ruta, Enviar de nuevo, Copiar el nombre, Quitar del historial y Eliminar el archivo.
- Al cambiar el tamaño de la ventana, el paso de dos columnas a una se funde en vez de saltar.

### Ver el ordenador desde el teléfono

- El marco de la imagen tiene la forma exacta de la pantalla del ordenador (sin bandas negras) y el panel táctil ocupa el resto. El puntero se dibuja a escala de la imagen.

### Animaciones

- **Cada icono responde al toque** en Windows y Android: crece, se inclina y se rellena un instante. Sin movimiento si el sistema pide reducirlo.
- **Enviar archivos se ve:** el diálogo dibuja tu dispositivo, el otro y unos puntos que viajan entre ambos; la línea se llena con el progreso y al llegar aparece una marca.
- **Control remoto (Android)** se abre desde una vista previa con el fondo del ordenador y un puntero en movimiento.

### Acceso remoto (antes «Controlar teléfono»)

- **Se retira Alero Desktop** y las herramientas de escritorio (espacios de trabajo, distribución de ventanas, diagnóstico, modo Escritorio). Quedan la pantalla del teléfono, la cámara, la webcam y la grabación.
- Android ya no declara el permiso «Mostrar sobre otras apps», que solo usaba Alero Desktop.
- La conexión por depuración inalámbrica se reintenta una vez: el primer intento tras despertar el teléfono solía fallar.

### Seguridad

- Desaparece con «Extender pantalla» la orden con la que un teléfono emparejado abría una página en el navegador del PC.
- Revisión de dependencias contra osv.dev: sin avisos en lo que se distribuye.

## Beta 1.1.1 (1.1.1) — 2026-11-05

### Android

- **Inicio más limpio:** la tarjeta del PC lleva cuatro botones pequeños en una fila (Enviar, Portapapeles, Pantalla y Captura). Una tarjeta nueva, **Control remoto**, reúne «Ratón y teclado» y «Archivos del ordenador». Desaparece el texto «Resumen de…» y la etiqueta «Conexión cifrada» de la tarjeta.
- **Alero Vault** sale de la barra inferior y pasa a Ajustes › Seguridad.
- **Fluidez:** el APK es ahora una compilación release (código compilado de antemano y reducido con R8). La de depuración iba a tirones. La entrada de las pantallas mueve una capa ya pintada en lugar de repintar las tarjetas en cada fotograma, y la portada se decodifica una sola vez y al tamaño en que se muestra.
- **Portadas:** el PC descartaba las portadas de más de 150 KB (muchas de Spotify); ahora las reduce a un JPEG de 400 px.
- **Barra de progreso:** saltaba hacia atrás porque Windows solo actualiza la posición cuando el reproductor informa (Spotify, cada pocos segundos). El PC ahora suma el tiempo transcurrido desde ese informe.

### Windows

- **Cámara del teléfono en una ventana, siempre derecha:** el sensor entrega la imagen en su propia orientación, que no sigue la del teléfono. Alero calcula el giro con la orientación del sensor y la rotación del teléfono (fórmula de Android), y si giras el teléfono la ventana se vuelve a abrir con el nuevo giro. Funciona con las cámaras trasera y frontal.
- **Botones del prototipo** dentro de la tarjeta del dispositivo, con el estado (almacenamiento, conectividad, carga) en la misma tarjeta. «Seguridad» y «Sincronización» desaparecen porque no aportaban información.
- **Botón de reproducir vacío:** el tema pintaba el icono del mismo color que el botón (blanco sobre blanco). Pasaba igual con Enviar en Mensajes y en las respuestas a notificaciones.
- **Personalizar › Tema y apariencia** abre Ajustes directamente en Apariencia.

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

### Animaciones de Qollqe

- Se adaptaron del ZIP de Qollqe los movimientos de Material 3 Expressive/Orion: presión elástica al 95,5 %, entrada y salida de apartados con transición de escala 98–100 % y fundido, aparición escalonada de tarjetas con desplazamiento vertical y movimiento animado de cifras.
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
