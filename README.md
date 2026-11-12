# Alero — Android, Windows y Linux, conectados

<div align="center">

  <img src="branding/alero_icon.svg" alt="Logo oficial de Alero" width="180" />

  <h2>Una conexión. Sin fricción.</h2>

  <p>Alero conecta tu teléfono Android y tu PC con Windows o Linux directamente por tu red local o por cable USB, con <strong>Flutter</strong>, <strong>Rust</strong> y <strong>Kotlin</strong>.</p>

  <p>Transfiere archivos, explora tu teléfono, comparte el portapapeles, replica notificaciones y controla un equipo desde el otro, sin cuenta ni nube.</p>

  <p>
    <a href="https://github.com/Alero-Team/Alero/releases">
      <img src="https://img.shields.io/badge/Descargar-GitHub%20Releases-238636?style=for-the-badge&logo=github&logoColor=white" alt="Descargar Alero desde GitHub Releases" />
    </a>
    <a href="README.md"><img src="https://img.shields.io/badge/Idioma-Espa%C3%B1ol-2563EB?style=for-the-badge" alt="Leer en español" /></a>
    <a href="README.en.md"><img src="https://img.shields.io/badge/Language-English-6B7280?style=for-the-badge" alt="Read in English" /></a>
  </p>

  <p>
    <img src="https://img.shields.io/badge/Android-8.0%2B-3DDC84?logo=android&logoColor=black" alt="Android 8.0 o posterior" />
    <img src="https://img.shields.io/badge/Windows-x64-0078D4?logo=windows&logoColor=white" alt="Windows x64" />
    <img src="https://img.shields.io/badge/Linux-x64-FCC624?logo=linux&logoColor=black" alt="Linux x64" />
    <img src="https://img.shields.io/badge/Flutter-Rust-02569B?logo=flutter&logoColor=white" alt="Flutter y Rust" />
    <img src="https://img.shields.io/badge/Estado-Beta-F59E0B" alt="Versión Beta" />
    <img src="https://img.shields.io/badge/Licencia-GPL--3.0--or--later-blue" alt="Licencia GPL-3.0 o posterior" />
  </p>

</div>

## Descripción general

**Alero** te permite usar tu teléfono y tu computadora como un solo equipo. Los dispositivos se emparejan una vez con un código o un QR y desde entonces hablan por TLS con autenticación mutua. Nada pasa por un servidor ni necesitas crear una cuenta.

## Desarrolladores

Un proyecto de **Alero Team**, desarrollado por:

- **[@edwindidier17](https://github.com/edwindidier17)**
- **[@k0op4](https://github.com/k0op4)**

## Funciones principales

| Desde la computadora | Desde el teléfono |
| --- | --- |
| Enviar archivos y carpetas, con transferencias reanudables | Enviar archivos y compartir desde cualquier app |
| Explorar, renombrar y borrar los archivos del teléfono | Explorar las carpetas que comparte la computadora |
| Notificaciones con respuesta, SMS y llamadas | Touchpad, teclado y teclas multimedia para la computadora |
| Pantalla, cámara, webcam y grabación del teléfono (scrcpy) | La pantalla de la computadora en vivo, con su puntero |
| Controles rápidos: No molestar, linterna, volumen, buscar mi teléfono | El teléfono como segundo monitor de Windows |
| Portapapeles compartido | Portapapeles compartido |

## Cómo funciona

1. Instala el APK de Android y el instalador de Windows o el paquete de Linux (.deb, .rpm, AppImage o .tar.gz) de la misma versión.
2. Abre Alero en ambos dispositivos, conéctalos a la misma red Wi-Fi y empareja en **Dispositivos**, o escanea el QR de la computadora.
3. Permite el control remoto en Windows y concede al teléfono solo los permisos de las funciones que vayas a usar.

La interfaz está en español.

### Controlar la computadora desde el teléfono

El touchpad mueve el puntero con un dedo y desplaza con dos. Toca dos veces y mantén el segundo toque para arrastrar o seleccionar. Los botones izquierdo y derecho quedan activos hasta que los vuelves a tocar. El botón del teclado abre la entrada de texto y los atajos.

### Usar el teléfono desde la computadora

**Acceso remoto** abre la pantalla del teléfono en una ventana con [scrcpy](https://github.com/Genymobile/scrcpy), por depuración USB o inalámbrica, que el dueño del teléfono autoriza en Android. La misma página abre la cámara del teléfono, la convierte en webcam mediante OBS Studio y graba la pantalla en un archivo de video.

### Archivos y privacidad

La sección Música del explorador excluye audios de 5 segundos o menos, tonos de llamada, sonidos de notificación y alarmas. **Todas las carpetas** requiere el permiso especial de almacenamiento compartido de Android. Los datos privados de otras apps siguen inaccesibles. Pulsa una transferencia completada para abrirla con la aplicación asociada del sistema.

El ajuste opcional **Seguridad** de Android desbloquea la app con la huella del sistema o el PIN del dispositivo. Alero nunca guarda el PIN ni datos biométricos.

## Descargas

Los paquetes de Android, Windows y Linux se publican en **[GitHub Releases](https://github.com/Alero-Team/Alero/releases)** junto con las novedades de cada versión. Consulta también el [historial de cambios](CHANGELOG.md).

Alero sigue en fase Beta. Descarga siempre el APK y el instalador de la misma versión.

## Firma y limitaciones

Las compilaciones de Android conservan una sola identidad de firma para que cada versión actualice a la anterior. No es un certificado de producción. Google Play Protect puede bloquear APK descargados de GitHub porque la app declara capacidades sensibles (acceso a notificaciones, SMS), aunque el APK esté bien firmado; consulta la [guía de Play Protect para desarrolladores](https://developers.google.com/android/play-protect/warning-dev-guidance). El instalador de Windows no tiene firma Authenticode comercial.

En Linux (x64), los paquetes incluyen scrcpy y adb. En Wayland, la pantalla del PC en el teléfono se actualiza despacio.

## Información de la aplicación

| | |
| --- | --- |
| **Nombre** | Alero |
| **Plataformas** | Android 8.0 o posterior, Windows (x64) y Linux (x64) |
| **Paquete** | `dev.alero.app` |
| **Tecnologías** | Flutter, Rust y Kotlin |
| **Conexión** | Red local o USB, TLS con autenticación mutua, sin servidores |
| **Licencia** | GNU GPL-3.0-or-later. Consulta [LICENSE](LICENSE); los componentes de terceros conservan sus licencias |

---

<div align="center">
  <sub>Diseñado para Android, Windows y Linux · Alero Team</sub>
</div>
