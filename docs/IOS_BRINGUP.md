# Pinyon Shift para iPhone — prueba de arranque

La rama local `ios/bringup` parte de Pinyon Shift
`620e7c4d60823520a27171bc28b3539880eeed6d`. El parche de ShiftGlue parte de
`101ad468f1398646ecf74a6dcdead772cbe08624`. El paquete contiene código fuente y
parches. La app de diagnóstico arranca sin un disco y comprueba el contenedor
de iOS, dos vistas de memoria compartida y una superficie Vulkan sobre Metal.
El objetivo `pinyon_ios_probe` crea un dispositivo Vulkan, limpia una imagen
de la cadena de presentación en azul y la envía a la pantalla. La consola de
Xcode muestra el resultado de cada etapa.

## 1. Preparar la rama

En una Mac, extrae el ZIP y ejecuta lo siguiente desde la carpeta extraída. Si
los parches ya están aplicados en la copia de trabajo, continúa con el paso 2.

```bash
PATCH_DIR="$PWD"
git clone https://github.com/arcanite24/pinyon-shift.git
cd pinyon-shift
git switch -c ios/bringup 620e7c4d60823520a27171bc28b3539880eeed6d
git submodule update --init thirdparty/shiftglue-sdk
git apply --check "$PATCH_DIR/pinyon-ios.patch"
git -C thirdparty/shiftglue-sdk apply --check "$PATCH_DIR/shiftglue-ios.patch"
git apply "$PATCH_DIR/pinyon-ios.patch"
git -C thirdparty/shiftglue-sdk switch -c ios/mach-memory
git -C thirdparty/shiftglue-sdk apply "$PATCH_DIR/shiftglue-ios.patch"
git -C thirdparty/shiftglue-sdk submodule update --init \
  thirdparty/sdl3 thirdparty/vulkan-headers thirdparty/moltenvk
```

Las dos ramas son locales. Si publicas el trabajo en forks, publica primero
la rama de ShiftGlue y actualiza el puntero del submódulo y su URL en el fork
de Pinyon Shift, para que un clon limpio pueda resolver el commit.

## 2. Generar el proyecto de Xcode

Usa Xcode con el SDK de iOS y compatibilidad con la versión instalada en tu
iPhone, CMake 3.28 o posterior, Git y las herramientas de línea de comandos de
Xcode. El ejemplo elige ARM64 para dispositivo físico y un mínimo de iOS 18
para la app de diagnóstico. MoltenVK se compila desde la revisión fijada por
ShiftGlue.

```bash
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
cmake --version
MVK="$PWD/thirdparty/shiftglue-sdk/thirdparty/moltenvk"
(cd "$MVK" && ./fetchDependencies --ios && make ios)
cmake -S ios/bringup -B out/ios-probe -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
  -DMOLTENVK_XCFRAMEWORK="$MVK/Package/Latest/MoltenVK/static/MoltenVK.xcframework"
open out/ios-probe/PinyonShiftIOS.xcodeproj
```

Selecciona el esquema `pinyon_ios_probe`, el iPhone y tu equipo en
**Signing & Capabilities**. Si el identificador está ocupado, cámbialo en
**Product Bundle Identifier**. Empareja el dispositivo y activa
**Developer Mode** si Xcode lo pide. Pulsa **Product → Run**. Debes ver una
pantalla azul si el primer cuadro se muestra correctamente.
Puedes compilar sin firmar para revisar errores de compilación o enlace.

```bash
cmake --build out/ios-probe --config Debug --target pinyon_ios_probe -- CODE_SIGNING_ALLOWED=NO
```

[Instalación y ejecución desde Xcode](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices)

## 3. Verificar en el iPhone 17 Pro Max

1. Comprueba que la consola muestre `SDL video driver: uikit`.
2. Busca `Mach aliases: PASS`. La prueba reserva 4,5 GiB de **espacio
   virtual** y escribe dos bytes a través de vistas compartidas. En un kernel
   con páginas de 16 KiB debe indicar `page=16384, bias=4096`. El runtime
   utiliza las mismas primitivas para su mapa completo.
3. Busca `MoltenVK surface: PASS` y `MoltenVK first frame: QUEUED`. El segundo
   mensaje confirma que Vulkan aceptó la solicitud. Comprueba visualmente que
   se muestre la pantalla azul. La prueba envía un cuadro por arranque y
   registra los eventos de ciclo de vida.
4. Busca `Sandbox Documents: PASS`. Cierra y vuelve a lanzar la app para
   confirmar `persisted from previous launch: yes`.
5. Toca la ventana, conecta un mando y vuelve desde segundo plano. La consola
   debe registrar los eventos correspondientes. Conserva el log si algo falla.

[SDL3 en iOS](https://github.com/libsdl-org/SDL/blob/main/docs/README-ios.md) ·
[MoltenVK en aplicaciones Vulkan](https://github.com/KhronosGroup/MoltenVK/blob/main/Docs/MoltenVK_Runtime_UserGuide.md)

## Siguiente integración del juego

- **ShiftGlue y CMake.** Separar el generador macOS del runtime iOS. El
  generador se ejecuta en la Mac con el disco propio. La traducción local se
  compila como ARM64 de iOS. `cmake/PinyonShiftRexGlue.cmake` permite indicar
  el generador del host y es el punto de entrada para resolver la compilación
  cruzada. Revisar dependencias Apple del SDK, binarios auxiliares y
  `rexglue_helpers.cmake`, que actualmente copia el loader y un manifiesto ICD
  para macOS.
- **UIKit.** El parche de ShiftGlue selecciona `uikit`. Falta enlazar
  `REX_DEFINE_APP` con el arranque de SDL en iOS y adaptar
  `RunMainMessageLoop` a la escena, con pausa y reanudación del runtime.
  `WindowSDL::CreateSurface` ya usa una `CAMetalLayer` en Apple.
- **Memoria.** El parche reemplaza el backing del mapa invitado en iOS con
  una entrada Mach RW. Conserva las posiciones del mapa, el redondeo de
  offsets y el sesgo de 4 KiB en páginas grandes. Validar el mapa completo,
  protección y desprotección de páginas, fallos MMIO y liberación en el
  dispositivo. El diagnóstico comprueba solo dos vistas.
- **MoltenVK.** El diagnóstico enlaza MoltenVK estáticamente. Para el juego,
  conectar el cargador de funciones de `vulkan_instance.cpp` a
  `vkGetInstanceProcAddr` y el resto de la tabla de funciones a esa instancia.
  Verificar `VK_KHR_portability_subset`, formatos, memoria y requisitos del
  renderer antes de crear una cadena de presentación. Medir frame y memoria
  con el iPhone, empezando en 720p y 30 fps.
- **Datos.** El host ya selecciona `Documents/PinyonShift` para el estado
  y `Documents/PinyonShift/game` para el contenido en la compilación iOS.
  El parche también activa el control táctil por defecto. Falta el flujo de
  importación de una copia propia y la prueba de persistencia de una partida.
  Mantén fuera de Git el disco, el XEX, los recursos, las fuentes generadas
  a partir del juego y cualquier IPA que los contenga.
- **Primer arranque del juego.** El hito es instalar con Xcode, llegar al
  menú, iniciar una carrera, suspender, reanudar y comprobar guardado. Una IPA
  de prueba requiere la app del juego enlazada, firmada y ejecutada en el
  dispositivo.

El [reporte de iPad Pro M1](https://github.com/arcanite24/pinyon-shift/issues/634)
es una prueba de otro desarrollador sobre la versión 0.1.1. El autor describe
la adaptación y advierte que parte de su trabajo procede de parches GPL-3.
Los cambios de este paquete usan las APIs de Apple y el código de las
revisiones indicadas. En Windows se verifican parches, estructura y plist.
La compilación, firma, ejecución y resultados de la app quedan pendientes
de Xcode y del iPhone.
## Compilar desde Windows con GitHub Actions

1. Crea un fork del repositorio original en GitHub. Abre su pestaña **Actions**
   y habilita los workflows si GitHub los dejó desactivados.
2. Sigue el paso 1 para crear la rama local y aplicar `pinyon-ios.patch`.
   El workflow aplica el parche de ShiftGlue por su cuenta en el servidor.
   Si también lo aplicaste localmente, deja el submódulo fuera del commit.
3. Desde la raíz de tu copia, ejecuta estos comandos. Sustituye
   `TU_USUARIO` por tu usuario de GitHub.

   ```powershell
   git remote add mi-fork https://github.com/TU_USUARIO/pinyon-shift.git
   git add -- .github/workflows/ios-diagnostic.yml ios/bringup site/pages/macos.md src/pinyon_shift_app.cpp src/pinyon_shift_diagnostics.cpp
   git add -f -- docs/IOS_BRINGUP.md
   git commit -m "build(ios): add unsigned diagnostic workflow"
   git push -u mi-fork ios/bringup
   ```

4. En **Actions → iOS diagnostic build**, abre la ejecución de la rama
   `ios/bringup`. Si el build termina correctamente, descarga
   `PinyonShiftProbe-unsigned-arm64` en **Artifacts**. Si falla, abre el
   primer paso en rojo y conserva su registro. Si habilitaste Actions
   después de publicar la rama, vuelve a publicar un cambio en el
   workflow para activar el build.

El artefacto esperado es una app de diagnóstico ARM64 sin firmar. El workflow
no solicita credenciales de Apple ni utiliza archivos del juego. La firma
y la prueba en el iPhone son pasos posteriores.
