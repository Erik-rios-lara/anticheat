# Instalar el anti-cheat en tu propio servidor de L4D2

Guía para levantar el anti-cheat de cero en tu propia PC/servidor: instalar Metamod:Source y SourceMod, clonar el plugin, compilarlo, y dejarlo corriendo.

Repositorio: https://github.com/Erik-rios-lara/anticheat

## 1. Requisitos

- **Git** — https://git-scm.com/downloads, instalación por defecto sirve.
- **Un editor de texto/código** — VS Code recomendado, con la extensión `SourcePawn` del marketplace para resaltado de sintaxis.
- **Left 4 Dead 2 (servidor dedicado o listen server) ya instalado** en tu PC, con una carpeta `left4dead2/` accesible.

El compilador de SourcePawn (`spcomp`) ya viene incluido dentro del propio repo — no hace falta instalarlo aparte.

## 2. Instalar Metamod:Source

SourceMod (y por lo tanto el anti-cheat) no puede cargar sin Metamod:Source primero — es la capa que engancha plugins al motor del juego. El repo trae SourceMod completo, pero **no trae Metamod:Source** porque son binarios de plataforma que no se versionan en git.

1. Descarga la build estable más reciente para Windows desde https://www.sourcemm.net/downloads.php (elige la de **Windows**, no Linux).
2. Extrae el `.zip` directamente dentro de tu carpeta `left4dead2/` — debe quedar así:

   ```
   left4dead2/
   ├── addons/
   │   ├── metamod.vdf          " lo trae Metamod
   │   └── metamod/
   │       └── ... (bin, server.dll, etc.)
   └── ...
   ```
3. Inicia el servidor una vez y escribe en su consola:

   ```
   meta version
   ```

   Si responde con la versión de Metamod instalada, quedó bien puesto.

## 3. Clonar el repositorio del anti-cheat

El repo es público, no necesitas invitación para clonarlo.

```bash
git clone https://github.com/Erik-rios-lara/anticheat.git
cd anticheat
```

Esto trae `addons/sourcemod/` completo (binarios, extensions, gamedata, plugins base, traducciones), los 20+ archivos `.sp` del anti-cheat (aim, bhop, integrity, correlation, evidence, etc.), el compilador `spcomp.exe`, y el bot de Discord en `discord-bot/`.

## 4. Copiar SourceMod a tu servidor

Copia la carpeta `addons/sourcemod/` del repo (junto con `addons/metamod/sourcemod.vdf`, que ya viene incluido) dentro de tu `left4dead2/`, fusionándola con la que dejó Metamod en el paso 2:

```
left4dead2/
├── addons/
│   ├── metamod.vdf
│   ├── metamod/            " de Metamod:Source (paso 2)
│   ├── sourcemod.vdf        " del repo
│   └── sourcemod/           " del repo
└── ...
```

Reinicia el servidor y en consola confirma:

```
sm version
```

Si responde con la versión de SourceMod, ya está enganchado correctamente sobre Metamod.

## 5. Compilar el plugin

El archivo principal es `anticheat_core.sp` — incluye a todos los demás módulos vía `#include`, así que compilarlo a él genera el `.smx` completo.

Dentro de la carpeta `anticheat/` (donde clonaste el repo, no necesariamente donde está el servidor):

```bash
# Git Bash
./addons/sourcemod/scripting/spcomp.exe anticheat_core.sp -o anticheat_core.smx
```

```powershell
# PowerShell
.\addons\sourcemod\scripting\spcomp.exe anticheat_core.sp -o anticheat_core.smx
```

Una compilación sana termina así — un warning es normal y ya existía antes, no es un error tuyo:

```
Code size:         157040 bytes
anticheat_core.sp(32) : warning 204: symbol is assigned a value that is never used: "g_cvBanDuration"
1 Warning.
```

> **Si ves "Error"** en vez de solo warnings, el `.smx` no se generó — no lo copies al servidor.

## 6. Copiar el plugin compilado y activarlo

Copia el `anticheat_core.smx` recién compilado a:

```
left4dead2/addons/sourcemod/plugins/
```

Reinicia el servidor (o si ya estaba corriendo, en su consola):

```
sm plugins refresh
sm plugins list
```

Debe aparecer `anticheat_core` como `Running`.

## 7. Configurar el bot de Discord

El plugin y el bot se comunican por archivos JSON en una carpeta local del disco (`addons/sourcemod/data/anticheat_ipc/`) — **no por red**. Eso significa que el bot tiene que correr en la MISMA PC donde corre el servidor de L4D2, aunque siga publicando en el mismo servidor/canal de Discord de siempre.

El anti-cheat funciona sin esto — las detecciones y kicks automáticos ocurren igual solo con el plugin. El bot solo agrega la notificación con botones de Kick/Ban en Discord.

**Requisito:** [Node.js](https://nodejs.org/) (versión LTS) instalado en la PC.

1. Dentro del repo ya clonado:

   ```bash
   cd discord-bot
   npm install
   ```

2. Crea un archivo `.env` en `discord-bot/` (no viene en el repo — contiene el token del bot, es secreto). Pide el contenido por un canal privado, con este formato, ajustando solo `ANTICHEAT_IPC_DIR` a la ruta real del servidor en esta PC:

   ```
   DISCORD_BOT_TOKEN=<el mismo token que ya usamos>
   DISCORD_CHANNEL_ID=<el mismo canal de siempre>
   DISCORD_ADMIN_ROLE_ID=<el mismo rol de admin de siempre>
   ANTICHEAT_IPC_DIR=<ruta local a left4dead2\addons\sourcemod\data\anticheat_ipc>
   ```

   Como el token, canal y rol son los mismos de siempre, el bot sigue publicando en el mismo servidor de Discord donde ya estaban las alertas — solo cambia desde qué PC corre y qué carpeta de disco está leyendo.

3. Arráncalo:

   ```bash
   node bot.js
   ```

   Debe imprimir `[OK] Bot conectado como <nombre>#1234`. Déjalo corriendo mientras el servidor de L4D2 esté activo — si se cierra, las alertas se siguen generando pero nadie las publica en Discord hasta que se vuelva a levantar.

> **Nunca compartan el `.env` por el repo ni por chats públicos** — quien tenga el token puede controlar el bot completo.

## 8. Activar/desactivar el anti-cheat con un .bat

El script `anticheat_toggle.bat` (en la raíz del repo) prende/apaga el plugin sin tener que borrar ni recompilar nada, moviendo el archivo dentro/fuera de la carpeta `plugins` — SourceMod solo carga lo que encuentra ahí.

Ábrelo con doble clic. Muestra un menú:

```
============================================
  Anti-Cheat L4D2 - Activar / Desactivar
============================================

Estado actual: ACTIVADO

  [1] Activar el anti-cheat
  [2] Desactivar el anti-cheat
  [3] Ver estado
  [4] Salir
```

- **Desactivar** renombra `anticheat_core.smx` → `anticheat_core.smx.disabled`.
- **Activar** hace lo inverso.

En ambos casos el cambio en disco no toma efecto hasta que se lo pidas al servidor. En su consola (o la del juego si es listen server, tecla `~`), según lo que hayas elegido:

```
sm plugins unload anticheat_core   " después de desactivar
sm plugins refresh                 " después de activar
```

> **Antes de usarlo la primera vez**, abre `anticheat_toggle.bat` con un editor de texto y ajusta `PLUGINS_DIR` a la ruta real de tu instalación de L4D2 — la que trae por defecto es de ejemplo, no la tuya.

## 9. Mantenerlo actualizado

Cuando salgan cambios nuevos al anti-cheat (nuevos detectores, ajustes, fixes), solo necesitas repetir los pasos 3, 5 y 6 — no hace falta reinstalar Metamod ni SourceMod de nuevo:

```bash
cd anticheat
git pull
./addons/sourcemod/scripting/spcomp.exe anticheat_core.sp -o anticheat_core.smx
```

Y copiar el `.smx` resultante a tu carpeta `plugins/`, seguido de `sm plugins refresh`.

---

Módulos activos ahora mismo: aim (headshot ratio, psilent, autoshoot, fov lock), bhop, bhop2, integrity, nolerp, osac, correlation, evidence, target acquisition, variance profiling, shot decision — más el bot de Discord para alertas de kick (mismo servidor/canal de Discord de siempre, corriendo ahora desde la nueva PC).
