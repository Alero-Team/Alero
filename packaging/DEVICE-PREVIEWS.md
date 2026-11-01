# Miniaturas de dispositivos

Las dimensiones de pantalla y el fabricante/modelo llegan del propio dispositivo. El Pixel 9a añade las medidas de su chasis (73,3 × 154,7 × 8,9 mm); la Lenovo V15 G4 IAH, identificada por el producto 83FS, añade 359,2 × 235,8 × 19,9 mm.

- [Especificaciones oficiales de Pixel](https://support.google.com/pixelphone/answer/7158570?hl=en)
- [Especificaciones oficiales Lenovo V15 G4 IAH](https://psref.gtm.lenovo.com/syspool/Sys/PDF/Lenovo/Lenovo_V15_G4_IAH/Lenovo_V15_G4_IAH_Spec.pdf)

Android obtiene el fondo integrado del fabricante mediante `WallpaperManager.getBuiltInDrawable()`. Windows usa la imagen de fábrica de Windows instalada en `Windows/Web/Wallpaper/Windows/img0.jpg`. Las miniaturas se producen en el dispositivo y viajan únicamente al otro equipo emparejado. No se distribuyen imágenes OEM de terceros dentro del repositorio.

La ilustración de la laptop mantiene la proporción real de pantalla y muestra su modelo. Es un dibujo frontal, no un render fotográfico del chasis Lenovo ni una copia de su fondo OEM.

## Tapa trasera del modelo exacto (Windows)

El teléfono envía `Build.MANUFACTURER/BRAND/MODEL/DEVICE/PRODUCT` y `ro.product.marketname` en `pb.x.info`; Alero no usa ADB para esto. `app/lib/device_image.dart` hace el resto en el ordenador, sin bloquear la conexión, y el resultado es el icono del panel lateral (`PhoneCover`):

1. **Nombre comercial:** `marketName` del teléfono; si no lo tiene, la lista pública «Supported devices» de Google Play (`storage.googleapis.com/play_public/supported_devices.csv`: Retail Branding, Marketing Name, Device, Model) por pareja dispositivo+modelo. Si solo se conoce el código de modelo, no se busca imagen.
2. **Imagen:** búsqueda en la API de Wikimedia Commons (`commons.wikimedia.org/w/api.php`, `generator=search`, `iiurlwidth=480`). Un archivo se acepta solo si: es PNG o SVG (las fotos de tienda no sirven como icono); licencia libre (CC0, CC BY, CC BY-SA, dominio público, GFDL); el título contiene las palabras del modelo, seguidas de una palabra que no lo convierta en otro (Pro, Ultra, Plus, FE, un año…) y una de «back/rear/backside»; aparece la marca en título, descripción o categorías; la descripción no dice «series»; ninguna categoría nombra una variante mayor.
3. **Caché:** `<datos de la app>/device-covers/` (`index.json` + una imagen por modelo, máximo 60, las más antiguas se retiran). Sin imagen verificable se recuerda 14 días. Una imagen `<clave>.png|jpg|webp` colocada a mano en esa carpeta tiene prioridad (por ejemplo un render oficial con permiso).
4. **Respaldo:** sin tapa verificable queda el icono genérico de teléfono, junto al nombre.

Cobertura medida el 31 de octubre de 2026: Commons solo tiene renders limpios de tapa para los Pixel (7, 8, 9, 9a…). Galaxy, Xiaomi, Motorola, OnePlus y Nothing solo tienen fotos, que se descartan.

## Carga

`BATTERY_PROPERTY_CURRENT_NOW` (µA por contrato de Android) × `EXTRA_VOLTAGE`, solo con estado CHARGING; es la potencia que entra en la batería, no la del cargador, y el voltaje es el de la batería (las apps no ven el del cargador). Bajo 0,5 W se considera mantenimiento (un Pixel al límite del 80 % marca ±5 mA con estado CHARGING). Estado: Buena ≥ 10 W, Mala ≥ 5 W, Deficiente por debajo.
