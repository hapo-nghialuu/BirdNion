<div align="center">
  <img src="docs/social.png" alt="BirdNion - AI quota companion for macOS and Linux" />
</div>

# BirdNion - Que tus agentes de IA no se salgan del presupuesto.

> Todas las cuotas de programación con IA y los ajustes de tus agentes, en la barra de menús de macOS o en la bandeja del sistema de Linux.

[English](README.md) · [Tiếng Việt](README.vi.md) · [中文](README.zh.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · **Español** · [Deutsch](README.de.md) · [Français](README.fr.md)


[![Latest release](https://img.shields.io/github/v/release/hapo-nghialuu/BirdNion?style=flat-square&color=0a0a0c)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-0a0a0c?style=flat-square)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Linux x86_64](https://img.shields.io/badge/Linux-x86__64-fcc624?style=flat-square&logo=linux&logoColor=111)](https://github.com/hapo-nghialuu/BirdNion/releases/latest)
[![Homebrew](https://img.shields.io/badge/brew-hapo--nghialuu%2Ftap%2Fbirdnion-orange?style=flat-square)](https://github.com/hapo-nghialuu/homebrew-tap)
[![License: MIT](https://img.shields.io/badge/license-MIT-6e5aff?style=flat-square)](LICENSE)

38 proveedores. BirdNion es una pequeña aplicación para la barra de menús de macOS 14+ y la bandeja de Linux que mantiene visibles los límites de programación con IA, muestra cuándo se restablece cada periodo y centraliza cómo se consultan los datos de cada agente de programación. Codex, Claude, MiniMax, OpenRouter, DeepSeek, z.ai, ElevenLabs, Deepgram, Groq, Grok, xAI, OpenAI, Ollama, GitHub Copilot, Kilo, Command Code, Xiaomi MiMo, Alibaba/Qwen, Cursor, Gemini, Kiro, OpenCode, OpenCode Go, Antigravity, AWS Bedrock, FreeModel, Devin y Hapo AI Hub, además de proveedores mediante complementos JavaScript (Aixy, Atlas Cloud, ClinePass, LiteLLM, Muse Code, Nous Portal, Raycast, Sakana AI, Venice, xKiro).

La aplicación nativa de macOS usa SwiftUI/AppKit y un subconjunto reducido de `CodexBarCore` incluido en el repositorio. La versión para Linux se encuentra en `linux/` y usa Tauri v2 con un núcleo en Rust y una interfaz en TypeScript sin frameworks. Ambas plataformas comparten el mismo esquema XDG de configuración de proveedores.

## Por qué usarlo

- **Planifica en torno a los restablecimientos.** Periodos de 5 horas, semanales, mensuales, de créditos y de presupuesto para cada proveedor, con cuentas atrás hasta su restablecimiento.
- **Consulta el gasto y los costes.** Análisis de archivos JSONL locales de Claude, información sobre el uso semanal, clasificaciones de proyectos que protegen la privacidad, gráficos de la API de administración de Claude, créditos de Codex, saldos de OpenRouter, presupuestos de Bedrock y resúmenes de costes o créditos específicos de cada proveedor, cuando estén disponibles.
- **Configura las fuentes de los agentes.** Elige OAuth, CLI, cookies del navegador, claves de API, credenciales de AWS, archivos de aplicaciones locales o aplicaciones del proveedor desde Ajustes para cada proveedor.
- **Cambia sin perder el contexto.** Tanto macOS como Linux permiten cambiar entre perfiles personalizados de Claude/Codex, restablecer créditos y preparar automáticamente Codex, y gestionar varias cuentas de Codex, Copilot, Antigravity y FreeModel.
- **Mantén un escritorio discreto.** macOS puede alternar los porcentajes de cuota de los proveedores en la barra de menús; Linux alterna el logotipo del proveedor y su porcentaje directamente en el icono de la bandeja.
- **La privacidad, primero.** BirdNion reutiliza sesiones existentes y configuraciones explícitas. No guarda contraseñas ni realiza análisis de disco sin restricciones.

## Instalación

### Requisitos

- macOS 14+ (Sonoma)
- Linux x86_64 para los paquetes publicados en formato `.deb`, `.rpm` y `.AppImage`

### Versiones en GitHub

Descarga los paquetes precompilados desde [las versiones de GitHub](https://github.com/hapo-nghialuu/BirdNion/releases):

- `BirdNion-<version>.zip` - aplicación universal para macOS, firmada con Developer ID y notarizada por Apple.
- `BirdNion_<version>_amd64.deb` - paquete para Ubuntu/Debian.
- `BirdNion-<version>-1.x86_64.rpm` - paquete para Fedora/RHEL.
- `BirdNion_<version>_amd64.AppImage` - paquete portátil para Linux.
- El cask de Homebrew usa SHA256.
- El comprobante de notarización se adjunta a la aplicación para que Gatekeeper la abra directamente (incluso sin conexión) tras la confirmación habitual de «descargada de Internet».

### macOS con Homebrew

Comando de instalación recomendado:

```bash
brew install --cask hapo-nghialuu/tap/birdnion
```

El comando completo selecciona explícitamente `hapo-nghialuu/tap/birdnion`, por lo que no hace falta ejecutar `brew tap` por separado.

Instalación con el nombre corto tras añadir el tap:

```bash
brew tap hapo-nghialuu/tap
brew trust --cask hapo-nghialuu/tap/birdnion
brew install --cask birdnion
```

O marca como fiable todo el tap:

```bash
brew trust hapo-nghialuu/tap
brew install --cask birdnion
```

No uses `HOMEBREW_NO_REQUIRE_TAP_TRUST=1` como vía de instalación habitual. Es una anulación del entorno por parte del usuario y no se puede incluir en `Casks/birdnion.rb` para eludir la comprobación de confianza antes de que Homebrew cargue el cask.

### Actualización en macOS

```bash
brew update && brew upgrade --cask birdnion
```

Ejecuta primero `brew update` (encadenado con `&&`) para que el tap obtenga el cask más reciente;
`brew upgrade` por sí solo no actualiza un tap de terceros e indicará
«ya instalado» con respecto a la versión obsoleta.

Comprueba la versión instalada:

```bash
brew list --cask --versions birdnion   # or: brew info --cask birdnion
```

### Linux

Descarga uno de los archivos para Linux de [la última versión](https://github.com/hapo-nghialuu/BirdNion/releases/latest):

```bash
sudo apt install ./BirdNion_<version>_amd64.deb
# or
sudo dnf install ./BirdNion-<version>-1.x86_64.rpm
# or
chmod +x BirdNion_<version>_amd64.AppImage
./BirdNion_<version>_amd64.AppImage
```

### Primer inicio

- Abre BirdNion desde la barra de menús de macOS o la bandeja del sistema de Linux.
- Abre Ajustes -> Proveedores y activa los que utilices.
- Instala las fuentes de los proveedores que necesites o inicia sesión en ellas: CLI, sesiones del navegador, OAuth/flujo de dispositivo, claves de API, archivos de aplicaciones locales o credenciales de la nube, según el proveedor.
- Opcional: configura las etiquetas de las cuentas, la visibilidad en la barra de menús, los intervalos de actualización, la fuente de cookies, la región, el modo de autenticación de AWS, el ámbito de organización de Kilo, el servidor empresarial de Copilot o la métrica de la barra de menús específica del proveedor.

## Configuración de los ajustes de agentes

BirdNion aspira a convertirse en una consola ligera de ajustes y configuración para agentes de programación con IA, no solo en un visor de cuotas.

Lo que ya está disponible:

- Activación y orden de proveedores, etiquetas de cuentas, intervalos de actualización y visibilidad en la barra de menús.
- Selectores de fuente para proveedores que pueden consultar OAuth, CLI, cookies del navegador, API de administración o el estado de aplicaciones locales.
- Ajustes específicos por proveedor para el modo de cookies, cabeceras de cookies manuales, regiones de MiniMax/z.ai/Alibaba, claves/perfil/región de AWS, ID de proyecto de Deepgram, ámbito de organización de Kilo, servidor empresarial de Copilot y selección de la métrica de la barra de menús.
- Detección de sesiones locales de agentes que gestionan su propio estado de autenticación: Claude Code, Codex CLI, Gemini CLI, Kiro, Cursor, Antigravity y herramientas similares.
- Una consola de configuración de Claude Code con servicios de backend predefinidos o personalizados, niveles de modelos, ámbito global o por proyecto, importación de JSON y eliminación segura de claves de entorno gestionadas por BirdNion.
- Cambio entre perfiles personalizados de Claude Code y Codex con comprobaciones reales de disponibilidad, caducidad y estado del proxy, y bloqueo de la activación ante fallos.
- Detección y cambio entre varias cuentas de Codex, GitHub Copilot, Antigravity y FreeModel, incluidas sesiones de FreeModel por navegador.

Planes de evolución:

- Ampliar la gestión de perfiles más allá de Claude Code a otros agentes de programación.
- Mostrar información más detallada sobre el estado de inicio de sesión y de las fuentes de cada agente.
- Validar las rutas de configuración locales y la disponibilidad de las CLI.
- Ofrecer indicaciones de configuración inicial para Claude Code, Codex CLI, Gemini CLI, Kiro y futuros agentes.
- Mantener las preferencias de BirdNion en su propia capa de configuración sin modificar el almacén de credenciales de cada agente.

## Proveedores

- **Codex** - API OAuth desde `~/.codex/auth.json`, alternativa mediante clave de API, alternativa local mediante `codex app-server`, estado del servicio, versión, créditos, restablecimiento de créditos, extras web opcionales de OpenAI y cambio gestionado de cuentas.
- **Claude** - API OAuth, cookies del navegador, CLI o API de administración; periodos de 5 horas/semanales/Opus/Sonnet, rutinas diarias, análisis de costes locales, extras web (gasto por uso adicional y créditos de prepago restantes) y gráfico de administración de 30 días. Los planes Max muestran su multiplicador de uso (Max 5x / Max 20x).
- **MiniMax** - Token de API, token del entorno o alternativa mediante cookies para el uso del plan de programación, el nombre del plan, los puntos/la suscripción y la región global/CN.
- **OpenRouter** - Token de API para créditos de prepago y un límite de gasto opcional por clave.
- **DeepSeek** - Token de API para el saldo en USD/CNY, desglosado entre saldo pagado y concedido, con aviso de saldo bajo.
- **z.ai** - Token de API con región global/CN para los límites de cuota y el cálculo del porcentaje restante.
- **ElevenLabs** - Clave de API para créditos de caracteres, espacios de voz, voces profesionales, plan y estado de la suscripción.
- **Deepgram** - Clave de API con ID de proyecto opcional para resúmenes de uso y un modo de agregación de todos los proyectos.
- **Groq** - Clave de API para métricas de solicitudes, tokens y aciertos de caché basadas en Prometheus.
- **Grok** - Sin configuración, desde `~/.grok/auth.json` (`grok login`); primero RPC de la CLI `x.ai/billing` y después gRPC-web de facturación de grok.com mediante cookies de Chrome / token Bearer de autenticación; identidad de SuperGrok y periodos de créditos. Costes locales en la pestaña Todo a partir de `~/.grok/sessions/**/signals.json` (totales de tokens × tabla de precios combinados por modelo).
- **xAI** - Clave de API de gestión e ID de equipo para la plataforma de desarrolladores (independiente de la suscripción de consumo de Grok); saldo de prepago y gasto de la plataforma de 30 días.
- **OpenAI** - API de administración de la plataforma (`OPENAI_ADMIN_KEY` / configuración) para el gasto de la organización de hoy/7 días/30 días; ID de proyecto opcional; alternativa heredada de créditos concedidos para claves de API de usuario. No cubre la suscripción de ChatGPT/Codex (usa Codex para eso).
- **Ollama** - Uso de sesión/semanal en la nube mediante cookies de ollama.com (Automático/Manual); la clave opcional `OLLAMA_API_KEY` verifica el acceso a la API de la nube.
- **GitHub Copilot** - Flujo de dispositivo de GitHub o alternativa mediante PAT, servidor empresarial, gestión completa para añadir/cambiar/eliminar cuentas, uso prémium, nombre de usuario y extras de presupuesto mediante cookies web.
- **Kilo** - Token de API o sesión de CLI, ámbito de organización de Kilo, créditos y detalles de recarga automática.
- **Kiro** - Uso basado en la CLI, datos de créditos/exceso de uso y 9 modos de visualización en la barra de menús.
- **Command Code** - Cookies del navegador o manuales para créditos de facturación y catálogo de planes.
- **Xiaomi MiMo** - Cookies del navegador para saldo, detalles del plan de tokens y uso.
- **Alibaba/Qwen** - Cookies del navegador y región internacional/CN para los periodos del plan de programación y del plan de tokens.
- **Cursor** - Primero `state.vscdb` de Cursor, con cookies del navegador como alternativa, resumen de uso, identidad y uso de solicitudes.
- **Gemini** - Credenciales OAuth de Gemini CLI desde `~/.gemini/oauth_creds.json` para los niveles de cuota de Cloud Code Assist.
- **OpenCode** - Cookies del navegador para el uso en periodos móviles/semanales y la renovación de la suscripción.
- **OpenCode Go** - Cookies del navegador y página del espacio de trabajo Go para el uso en periodos móviles/semanales/mensuales y el saldo de Zen.
- **Antigravity** - Comprobación de procesos/CLI locales y almacén de cuentas OAuth de Google para grupos de cuotas y datos asociados a cada cuenta.
- **AWS Bedrock** - Claves de acceso de AWS o perfil con nombre, región, campos de presupuesto y datos de uso de CloudWatch/Cost.
- **FreeModel** - Sesiones del navegador de `freemodel.dev` para presupuestos en dólares de 5 horas y semanales, con cambio de cuentas por navegador y compatibilidad con cookies gestionadas.
- **Devin** - Cuota diaria y semanal desde `app.devin.ai/api/<org>/billing/quota/usage`. Importa automáticamente el token de sesión del navegador y la organización desde localStorage de Chrome, o acepta un token Bearer manual y una organización opcional (slug o ID interno `org-...`).

Se admiten propuestas de más proveedores que encajen en el modelo `QuotaProvider` existente.

## Mascota, icono y capturas de pantalla

El icono predeterminado de la barra de menús de macOS es el pájaro de BirdNion. Al activar «Mostrar porcentaje en la barra de menús», la barra alterna entre los porcentajes de cuota de los proveedores activos con el logotipo de cada uno. Linux muestra el logotipo del proveedor y el porcentaje alternantes directamente en el icono de la bandeja.

<div align="center">
  <img src="website/assets/birdnion-readme-bird-quota-384.png" width="196" alt="BirdNion mascot holding a blue and yellow quota bar" />
  <br />
  <strong>BirdNion, tu compañero para las cuotas</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/logo.png" width="112" alt="BirdNion app icon" />
  <br />
  <strong>Icono de la aplicación BirdNion</strong>
</div>

<br />

<div align="center">
  <img src="docs/images/usage-overview.png" width="426" alt="BirdNion usage and cost overview" />
  <br />
  <strong>Resumen de uso y costes</strong>
</div>

<br />

<div align="center">
  <img src="website/assets/control-surface-redraw.jpg" width="776" alt="Illustrated BirdNion Linux control surface based on the current Settings implementation" />
  <br />
  <strong>Panel de control · ilustración basada en la implementación actual de Ajustes en Linux</strong>
</div>

## Funciones

- Valores alternantes opcionales de los proveedores en la barra de menús de macOS o el icono de la bandeja de Linux, con interruptores por proveedor y controles de reordenación adaptados a cada plataforma.
- Indicadores de uso específicos por proveedor con cuentas atrás hasta el restablecimiento.
- La configuración guiada lleva los errores corregibles de los proveedores al control exacto de Ajustes, guarda primero y solo marca el proveedor como conectado en directo cuando supera una autocomprobación real.
- Un distintivo compacto del centro de acciones en la cabecera del panel emergente abre Ajustes para los problemas actuales de configuración o conexión; los elementos resueltos desaparecen automáticamente, sin guardar un historial de incidencias.
- Actualización progresiva: cada proveedor publica sus datos en cuanto termina de obtenerlos.
- Los últimos datos conocidos siguen visibles mientras se actualizan.
- Selectores de fuente por proveedor para OAuth, CLI, cookies web, API de administración, estado de aplicaciones locales y claves estáticas.
- Intervalos de actualización y visibilidad en la barra de menús por proveedor.
- Selector de fuente de cookies con modos Automático, Manual y Desactivado para proveedores que usan cookies.
- Gráficos de costes locales de 17 fuentes de agentes —Claude, Codex, Grok, Kiro, Oh My Pi, Pi, Devin, OpenCode, Gemini CLI, Copilot CLI, Antigravity, Cursor, Amp, Droid, Kimi, Qwen Code y Goose— con un historial persistente que conserva los máximos registrados. Las barras guardadas rellenan la interfaz de inmediato mientras un análisis en tiempo real más acotado actualiza los días recientes.
- Un resumen compacto de Análisis en la pestaña Todo abre Ajustes -> Análisis para consultar comparaciones de 7 días y clasificaciones de proyectos de 7/30/90 días. Claude, Codex y Grok obtienen identidades de proyecto que protegen la privacidad a partir de los metadatos de sus sesiones locales; solo el uso residual que no se puede atribuir permanece marcado explícitamente como `Unknown`.
- Gráfico de 30 días de la API de administración de Claude y extras del panel web de Codex cuando estén activados.
- Valores de visualización personalizados de Kiro: créditos restantes, porcentaje, usados/total y modos de exceso de uso.
- Notificaciones de cuotas y fallos de proveedores con umbrales configurables.
- Archivo de configuración XDG con permisos restrictivos.

## Configuración y almacenamiento

| Datos | Ubicación |
|---|---|
| Lista de proveedores, indicadores de activación, claves de API, región, presupuesto, ID de proyecto, URL base, etiqueta de cuenta | `~/.config/birdnion/settings.json` |
| Ruta de configuración alternativa | `$BIRDNION_CONFIG` |
| Ruta XDG alternativa | `$XDG_CONFIG_HOME/birdnion/settings.json` |
| Configuración heredada | `~/.birdnion/settings.json` |
| OAuth de Codex | `~/.codex/auth.json`, gestionado por Codex CLI |
| OAuth de Claude | Elemento de Keychain de macOS `Claude Code-credentials`; en Linux, `~/.claude/.credentials.json`; ambos gestionados por Claude Code/CLI |
| OAuth de Gemini | `~/.gemini/oauth_creds.json` |
| Sesión de Cursor | macOS: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`; Linux: `~/.config/Cursor/User/globalStorage/state.vscdb` |
| Cuentas OAuth de Antigravity | `~/.config/birdnion/antigravity-oauth.json` |
| Cuentas OAuth de Copilot | `~/.config/birdnion/copilot-accounts.json` |
| Cuentas gestionadas de FreeModel | macOS: `~/Library/Application Support/BirdNion/freemodel-accounts.json`; Linux: `~/.config/birdnion/freemodel-accounts.json` |
| Historial de costes diarios (pestaña Todo) | `~/.config/birdnion/cost-history.json` (junto al archivo de ajustes; fusión que conserva los máximos registrados para mantener las barras anteriores aunque se eliminen sesiones de agentes) |
| Historial de costes por proyecto (Análisis) | `~/.config/birdnion/project-cost-history.json` (almacén opcional independiente; claves de proyecto/ID de retractación con SHA-256, nombres base seguros, fusión de máximos limitada por el total agregado, `0600`) |
| Preferencias de interfaz de macOS | `UserDefaults` (`showPercentInMenuBar`, ajustes de visibilidad, actualización, fuente y visualización) |
| Preferencias de interfaz de Linux | `localStorage` de Tauri WebView; los campos de cookies/visibilidad/actualización por proveedor permanecen en `settings.json` |

Prioridad de las rutas de configuración:

1. `$BIRDNION_CONFIG`
2. `$XDG_CONFIG_HOME/birdnion/settings.json`
3. `~/.config/birdnion/settings.json`
4. `~/.birdnion/settings.json`

El archivo de configuración se escribe de forma atómica y se le asignan permisos `0600`.

## Nota sobre privacidad

BirdNion no recorre el sistema de archivos sin restricciones. Solo consulta ubicaciones documentadas cuando el proveedor o la fuente correspondiente están activados: archivos de configuración de proveedores, archivos de autenticación de CLI, almacenes de cookies del navegador, bases de datos locales de IDE y registros de sesión locales de agentes. Los tokens de los proveedores se guardan en el archivo de configuración de BirdNion con permisos restrictivos. Los archivos de sesión de OAuth, Keychain y CLI siguen bajo el control de sus herramientas originales.

No se guardan contraseñas. Las cookies del navegador solo se reutilizan cuando el usuario elige una fuente basada en cookies. Análisis nunca guarda la ruta completa de un proyecto: Claude calcula el hash de su token estable de directorio de sesión, Codex calcula el hash de un `cwd` absoluto validado y Grok calcula el hash de su token codificado de directorio de sesión. Las rutas verificadas solo pueden mejorar la etiqueta saneada del nombre base; la interfaz y el resumen para copiar reciben esa etiqueta segura o un grupo residual explícito `Unknown`.

## Notas por plataforma

### Permisos de macOS

- **Acceso total al disco** - no es necesario para las funciones básicas de la aplicación. Los proveedores que usan cookies del navegador pueden necesitar acceso adicional en macOS según el navegador y el almacén de cookies.
- **Acceso a Keychain** - OAuth de Claude puede leer el elemento `Claude Code-credentials`, gestionado por Claude Code/CLI; la importación de cookies también puede mostrar solicitudes de acceso al llavero Safe Storage del navegador.
- **Solicitudes de Archivos y carpetas** - las comprobaciones de proveedores locales pueden provocar solicitudes de macOS si la CLI o el proceso auxiliar subyacente accede a ubicaciones protegidas.
- **Permisos que BirdNion no solicita en segundo plano** - ni Grabación de pantalla ni Accesibilidad.

### Linux

- Los proveedores que usan cookies del navegador requieren un perfil compatible de Chrome/Chromium/Brave/Edge/Firefox y pueden depender del llavero del escritorio.
- La bandeja del sistema muestra el logotipo del proveedor y el porcentaje alternantes directamente en su icono, porque los escritorios Linux no ofrecen una forma portable de mostrar texto junto a los iconos de la bandeja.
- Los atajos globales no están habilitados en Linux; usa la ventana de la aplicación y los controles de Ajustes.

## Documentación

- [docs/build.md](docs/build.md) - compilación, firma y resolución de problemas.
- [docs/system-architecture.md](docs/system-architecture.md) - arquitectura del sistema e historial de decisiones.
- [docs/development-roadmap.md](docs/development-roadmap.md) - hoja de ruta histórica.
- [docs/provider-parity/README.md](docs/provider-parity/README.md) - auditoría de paridad entre BirdNion y CodexBar.
- [docs/linux-parity-matrix.md](docs/linux-parity-matrix.md) - paridad de funciones entre macOS y Linux.
- [linux/README.md](linux/README.md) - desarrollo, empaquetado y notas de plataforma de Linux.

## Primeros pasos (desarrollo)

- Clona el repositorio. Abre `BirdNion.xcodeproj` para macOS o trabaja desde `linux/` para desarrollar con Tauri.
- Inicia la aplicación una vez y después activa los proveedores en Ajustes -> Proveedores.
- Instala las fuentes de los proveedores que necesites o inicia sesión en ellas: CLI, cookies del navegador, OAuth/flujo de dispositivo, claves de API, aplicaciones del proveedor o archivos de configuración locales.
- Opcional: configura las cookies de OpenAI para los extras del panel de Codex y el enrutamiento de fuentes de Claude para OAuth/Web/CLI/API de administración.

## Compilación desde el código fuente

### macOS

Requiere macOS 14+ y Xcode con compatibilidad con Swift para el esquema del proyecto.

```bash
xcodebuild test -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Debug -destination 'platform=macOS'

xcodebuild build -project BirdNion.xcodeproj -scheme BirdNion \
  -configuration Release -destination 'platform=macOS'
```

BirdNion incluye una versión reducida del paquete `CodexBarCore` en `Vendor/CodexBar`; no se necesita una copia externa de `~/Desktop/CodexBar`.

### Linux

El desarrollo y las pruebas se pueden ejecutar desde `linux/` en macOS o Linux. Los paquetes nativos de Linux deben compilarse en Linux con las dependencias de WebKitGTK/AppIndicator instaladas.

```bash
cd linux
npm ci
npm test
npm run build
cargo test --manifest-path src-tauri/Cargo.toml

# On Linux: build .deb, .rpm, and AppImage bundles
npm run tauri build
```

## Créditos

Inspirado en [CodexBar](https://github.com/steipete/CodexBar), especialmente en la idea de mantener visibles todos los límites de programación con IA sin abrir un panel. BirdNion mantiene su propia implementación multiplataforma de proveedores, configuración y distribución.

## Licencia

MIT.
