# Manual de instalación y uso del AntiCheat — Left 4 Dead 2

Guía paso a paso para instalar, configurar y administrar el sistema anti-trampas en un servidor de L4D2. Pensada para alguien que recibe el plugin por primera vez y no tiene contexto previo.

**Basado en:** SourceMod 1.12 + extensión RIPExt
**Tiempo estimado de instalación:** ~15 minutos
**Requiere:** MetaMod:Source + SourceMod ya instalados

---

## Contenido

1. [Qué es y cómo funciona](#1-qué-es-y-cómo-funciona)
2. [Requisitos previos](#2-requisitos-previos)
3. [Instalación de archivos](#3-instalación-de-archivos)
4. [Configurar el webhook de Discord](#4-configurar-el-webhook-de-discord)
5. [Dar permisos de administrador](#5-dar-permisos-de-administrador)
6. [Primer arranque y verificación](#6-primer-arranque-y-verificación)
7. [Comandos del día a día](#7-comandos-del-día-a-día)
8. [El menú visual en el juego](#8-el-menú-visual-en-el-juego)
9. [Cómo interpreta el riesgo](#9-cómo-interpreta-el-riesgo)
10. [Solución de problemas comunes](#10-solución-de-problemas-comunes)

---

## 1. Qué es y cómo funciona

Este plugin observa a cada jugador humano en el equipo de supervivientes y calcula, cada **10 segundos**, un puntaje de riesgo de 0 a 100 combinando **4 módulos de detección independientes**:

| Módulo     | Peso    | Qué mira |
|------------|---------|----------|
| Aim        | 50%     | Aimbot / silent-aim (4 técnicas distintas combinadas) |
| Bhop       | 25%     | Bunny-hop automatizado / scripts de salto |
| Integrity  | 13%     | Paquetes de red manipulados o imposibles |
| NoLerp     | 12%     | Interpolación del cliente trucada para mejorar la puntería |

Cada módulo produce su propio puntaje 0-100 de forma totalmente independiente. El detalle técnico completo de cómo funciona cada uno — qué mide, por qué funciona, y con qué umbrales — está en **[MODULOS-DETECCION.md](MODULOS-DETECCION.md)**, incluido en este paquete.

Cuando el riesgo combinado cruza un umbral, el sistema notifica en el chat del servidor, registra el evento en un log, y opcionalmente envía una alerta a un canal de Discord. Si el riesgo es muy alto de forma sostenida (o si un solo módulo por sí solo da evidencia muy fuerte), el sistema **expulsa (kick)** automáticamente al jugador de la partida — no lo banea permanentemente, para dejar la decisión final de un baneo en manos de un administrador humano.

> **Nota:** No es un anti-cheat de kernel. No detecta el software del cheat en sí — analiza el *comportamiento* resultante (precisión imposible, disparos a través de paredes, saltos perfectos). Es complementario a VAC, no un reemplazo.

> **Nota sobre el host:** en un listen server (partida hospedada localmente, no un servidor dedicado), SourceMod da acceso de administrador automático al jugador con índice de cliente 1 — casi siempre el anfitrión. Esto significa que **el host nunca puede ser auto-baneado**, sin importar la configuración de `admins_simple.ini`. Los demás jugadores que se conecten sí son detectados y baneados normalmente.

---

## 2. Requisitos previos

Antes de copiar un solo archivo, la persona que reciba el servidor necesita tener instalado:

- **Left 4 Dead 2 Dedicated Server** (vía SteamCMD o la copia de Steam del juego, como listen server).
- **MetaMod:Source** instalado en `left4dead2/addons/`. Descarga: https://www.sourcemm.net/downloads.php?branch=stable
- **SourceMod 1.12** instalado sobre MetaMod. Descarga: https://www.sourcemod.net/downloads.php

Si estos tres ya están funcionando (por ejemplo, si ves el mensaje `[SM] Listing N plugins` al escribir `sm plugins list` en la consola del juego), puedes saltar directo al paso 3.

---

## 3. Instalación de archivos

El paquete que se entrega ya trae todo compilado. Solo hay que copiar carpetas — no hace falta compilar nada de nuevo.

### 3.1 — Copiar todo el contenido de `addons/`

Copia la carpeta `addons/` completa del paquete recibido dentro de:

```
...\Left 4 Dead 2\left4dead2\addons\
```

Esto instala en un solo paso:

- El plugin `anticheat_core.smx` (y los demás módulos ya compilados dentro de él) en `addons/sourcemod/plugins/`.
- La extensión **RIPExt** (`rip.ext.dll`) en `addons/sourcemod/extensions/` — es la que envía los mensajes a Discord.
- El certificado `ca-bundle.crt` que RIPExt necesita para conectarse por HTTPS.

### 3.2 — Copiar la configuración

Copia también la carpeta `cfg/` del paquete a:

```
...\Left 4 Dead 2\left4dead2\cfg\
```

Esto coloca el archivo `cfg/sourcemod/anticheat.cfg`, donde vive la configuración editable (webhook de Discord, duración de baneos, etc. — se explica en el paso 4).

> **Atención:** Si algo de esto ya existe en el servidor, no sobrescribas a ciegas. En particular, si ya hay un `admins_simple.ini` con administradores configurados, no lo reemplaces — mejor fusiona el contenido a mano (ver paso 5).

---

## 4. Configurar el webhook de Discord

Las alertas de riesgo pueden enviarse automáticamente a un canal de Discord como embeds. Esto es opcional pero muy recomendable — así no hay que estar mirando la consola del servidor todo el tiempo.

### 4.1 — Crear el webhook en Discord

1. En Discord, entra a **Configuración del canal → Integraciones → Webhooks → Nuevo webhook**.
2. Ponle un nombre (ej. "AntiCheat L4D2") y copia la **URL del webhook**.

### 4.2 — Pegar la URL en la configuración

Abre `left4dead2/cfg/sourcemod/anticheat.cfg` con un editor de texto y reemplaza la URL de ejemplo:

```
// Anti-cheat configuration
sm_ac_discord_webhook "https://discord.com/api/webhooks/TU_ID_AQUI/TU_TOKEN_AQUI"
sm_ac_discord_enabled "1"
sm_ac_ban_duration "60"
sm_ac_admin_immunity "1"
```

| ConVar | Qué controla | Valor por defecto |
|---|---|---|
| `sm_ac_discord_webhook` | La URL del webhook. Vacío = Discord desactivado. | (vacío) |
| `sm_ac_discord_enabled` | Interruptor general de las notificaciones a Discord. | 1 |
| `sm_ac_ban_duration` | Minutos que dura el baneo automático. 0 = permanente. | 60 |
| `sm_ac_admin_immunity` | Si está en 1, los admins nunca son baneados automáticamente. | 1 |

> **Importante:** Trata la URL del webhook como una contraseña. Cualquiera que la tenga puede publicar mensajes falsos en ese canal. No la compartas ni la subas a un repositorio público. Si alguna vez se filtra, bórrala desde Discord y crea una nueva.

### 4.3 — Probarlo

Una vez el servidor esté corriendo (ver paso 6), entra a una partida y escribe en la consola del juego:

```
sm_testdiscord
```

Debería llegar un embed amarillo de prueba al canal configurado en pocos segundos.

### 4.4 — (Opcional) Bot de Discord con botones Kick / Ban

Además del webhook (solo notifica), existe un bot opcional que publica cada detección con botones **Kick**, **Ban 1 hora**, **Ban permanente** e **Ignorar** directamente en el mensaje de Discord — sin tener que entrar al juego para actuar.

Requiere crear tu propia aplicación de bot en Discord (gratis, ~10 min) y tener [Node.js](https://nodejs.org) instalado. La carpeta `discord-bot/` incluye el archivo `CONFIGURAR-BOT.txt` con la guía paso a paso completa.

Una vez configurado, el bot se abre y se cierra solo junto con el anti-cheat: al elegir **[1] Hospedar servidor** en el `.bat`, el bot arranca en una ventana aparte; al elegir **[2] Jugar en VAC**, se cierra.

> **Cómo funciona por dentro:** el plugin escribe un archivo por cada detección, el bot lo lee y publica el mensaje; cuando alguien presiona un botón, el bot escribe la decisión de vuelta a un archivo que el plugin revisa cada 3 segundos y ejecuta. Todo por archivos compartidos en disco — sin RCON, sin puertos abiertos. Por eso el bot **debe correr en la misma PC** que el servidor de L4D2.
>
> Solo el dueño del servidor de Discord y quienes tengan el rol configurado (`DISCORD_ADMIN_ROLE_ID`) pueden usar los botones.

---

## 5. Dar permisos de administrador

Para usar los comandos de administración (ver, banear, recargar) hace falta que la SteamID de la persona esté en la lista de admins de SourceMod. El anti-cheat no gestiona esto por su cuenta — usa el sistema estándar de SourceMod.

### 5.1 — Conseguir la SteamID

Se necesita el formato clásico `STEAM_0:X:XXXXXXX`. Se puede obtener a partir del link de perfil de Steam (`steamcommunity.com/profiles/76561...`) con cualquier conversor de SteamID64, o pidiéndole a la persona que escriba `status` en su propia consola mientras está conectada al servidor.

### 5.2 — Agregarla al archivo de admins

Edita `addons/sourcemod/configs/admins_simple.ini` y agrega una línea por cada administrador:

```
// --- AntiCheat Admin ---
"STEAM_0:0:XXXXXXXX"    "99:z"    // admite todos los permisos
"STEAM_0:1:XXXXXXXX"    "99:z"    // segundo admin
```

El flag `z` es "root": acceso total. El número antes de los dos puntos (`99`) es la inmunidad — con el valor más alto, nadie puede afectar a este admin.

> **Atención:** No dejes placeholders sin completar como `"STEAM_ID_LAN"` — no es una SteamID válida y ese admin nunca tendrá acceso real en una partida online. Tampoco agregues reglas de acceso por IP local (`!127.0.0.1`) salvo que sea estrictamente necesario: dan admin total a cualquiera conectado desde esa máquina, sin pedir SteamID.

### 5.3 — Aplicar el cambio

No hace falta reiniciar el servidor. En la consola del juego:

```
sm reload admins
```

---

## 6. Primer arranque y verificación

Arranca el servidor normalmente y entra a una partida. Una vez dentro, con la consola abierta (tecla `~`), verifica en orden:

### 6.1 — El plugin cargó

```
sm plugins list
```

`anticheat_core.smx` debe aparecer en la lista, sin la palabra `Error` al lado.

### 6.2 — La extensión de Discord cargó

```
sm exts list
```

Debe aparecer **"REST in Pawn"** en la lista.

### 6.3 — Prueba end-to-end

```
sm_testdiscord
```

Confirma que llega el mensaje de prueba al canal de Discord. Si algo falla aquí, revisa la sección de [solución de problemas](#10-solución-de-problemas-comunes).

> **Nota:** Cada vez que se reemplace un archivo `.dll` de extensión (como `rip.ext.dll`), hay que cerrar el juego por completo y reabrirlo — las extensiones no se recargan en caliente como los plugins. Un archivo `.smx` de plugin sí se puede recargar sin cerrar el juego.

---

## 7. Comandos del día a día

Todos requieren permisos de admin (flag `generic` como mínimo). Cada comando tiene una versión larga y un alias corto — ambos hacen lo mismo.

| Comando | Descripción |
|---|---|
| `sm_ac_view` / `sm_acv <jugador>` | Muestra el desglose de riesgo de un jugador: Aim, Bhop, Integrity, NoLerp y el total. |
| `sm_ac_reload` / `sm_acr` | Reinicia los contadores de detección de todos los jugadores activos. Útil tras cambiar la configuración. |
| `sm_ac_clearlog` / `sm_acc` | Borra el archivo de log del anti-cheat. |
| `sm_testdiscord` / `sm_act` | Envía un mensaje de prueba al webhook de Discord configurado. |
| `sm_ac_banhistory` / `sm_acbh` | Envía los últimos 15 baneos registrados (de cualquier origen: anti-cheat, `sm_ban`, votebans) a Discord en un embed. Requiere permiso `ban`. |
| `sm_unban <steamid\|ip>` | Quita un baneo. Comando nativo de SourceMod (no del anti-cheat), ya disponible. Requiere permiso `unban`. |
| `sm_ac` | Abre el menú visual con la lista de comandos y jugadores (ver paso 8). |
| `sm_admin` | Abre el menú de administración estándar de SourceMod (Kick / Ban / Slay / Votos de todos los plugins instalados). |

### Quitar un baneo

Para desbanear a alguien, usa el comando nativo de SourceMod con la SteamID en formato `STEAM_0:X:XXXXXXX` (el mismo formato que en `admins_simple.ini`):

```
sm_unban STEAM_0:0:XXXXXXXX
```

Si el baneo fue por IP, pasa la IP en su lugar:

```
sm_unban 123.45.67.89
```

Si no recuerdas la SteamID exacta a desbanear, puedes revisarla en `left4dead2\cfg\banned_user.cfg`, o si el baneo se aplicó después de instalar esta versión, con `sm_ac_banhistory`.

### Historial de baneos

El anti-cheat guarda su **propio** historial de baneos y desbaneos — captura automáticamente *cualquier* baneo aplicado en el servidor (no solo los suyos: también `sm_ban` manual y votebans), porque el archivo nativo de Source (`banned_user.cfg`) solo guarda la SteamID y la duración, sin nombre, razón ni quién lo aplicó. Cada `sm_unban` también se reporta a Discord automáticamente en el momento.

Cada evento queda en:

```
left4dead2\logs\anticheat\banlog.log
```

con fecha, jugador, SteamID, duración, admin y razón. Usa `sm_ac_banhistory` para reenviar los últimos 15 baneos a Discord bajo demanda.

> **Importante:** este historial solo cubre eventos aplicados **desde que se instaló esta versión en adelante**. Los baneos anteriores no se pueden recuperar con este nivel de detalle.

### Dónde queda el registro de riesgo

Cada evaluación de riesgo se anota en:

```
left4dead2\logs\anticheat\anticheat.log
```

Nota: esta ruta cuelga de la carpeta del juego (`left4dead2/`), no de `addons/sourcemod/` — es fácil buscarlo en el lugar equivocado.

---

## 8. El menú visual en el juego

Escribiendo `sm_ac` o el atajo de chat `!admin` se abre un menú con tres secciones:

- **Comandos de jugador** → lista de jugadores activos con un indicador de riesgo junto al nombre.
- **Comandos de servidor** → probar Discord, recargar módulos, limpiar el log.
- **Comandos de votación** → informativo; este anti-cheat no vota baneos, los aplica un admin directamente.

Al entrar a la lista de jugadores, cada nombre lleva un indicador de riesgo:

| Indicador | Significado |
|---|---|
| `[OK]` | Normal |
| `[~ ]` | Sospecha leve |
| `[! ]` | Sospecha alta |
| `[!!]` | Riesgo crítico |

Al seleccionar un jugador se abre su ficha con el desglose de los 4 módulos de detección (Aim, Bhop, Integrity, NoLerp), y accesos directos para **Expulsar**, **Banear 1 hora** o **Banear permanente** — estas tres son acciones manuales que decide el admin; la acción automática del sistema (ver sección 9) solo expulsa, nunca banea por sí sola.

---

## 9. Cómo interpreta el riesgo

El puntaje combinado (0-100) dispara distintas acciones según el umbral:

| Riesgo | Acción | Notifica en |
|---|---|---|
| 15+ | Aviso de "comportamiento sospechoso" en el chat | Chat del servidor, Discord (nota) |
| 35+ | Aviso de "alta sospecha" en el chat | Chat del servidor, Discord (aviso) |
| 50+ | Candidato a expulsión automática (ver nota abajo) | Chat del servidor, Discord, log |

Llegar a 50+ no expulsa de inmediato. El sistema exige que **al menos uno de los 5 módulos individuales** (Aim, Bhop, Integrity, NoLerp u OSAC) alcance por sí solo un puntaje de 60/100 o más — cada módulo ya requiere evidencia sostenida y específica antes de subir tanto, así que esto evita que la *suma* de varios detectores levemente sospechosos, sin ninguno concluyente, termine en una expulsión injusta. Además exige **tres evaluaciones consecutivas** en ese rango antes de actuar.

> **Nota de rendimiento:** los detectores más costosos (Aimlock y TriggerBot, que buscan al Infectado Especial más cercano en cada tick) **no corren para jugadores limpios**. Solo se activan cuando un jugador ya generó sospecha con los detectores ligeros, y su frecuencia sube con el nivel de sospecha (visible en el menú de admin como "vigilancia: nivel N"). Un jugador limpio no genera ninguna carga extra de CPU.

La acción automática es **expulsar de la partida (kick)**, no banear — la decisión de un baneo permanente queda siempre en manos de un administrador humano, usando el menú (sección 8) o `sm_ban`.

Los admins con `sm_ac_admin_immunity 1` nunca son expulsados automáticamente, sin importar su puntaje (pero sí generan una nota en Discord, para que quede registro).

> Para el detalle técnico de qué mide cada módulo y por qué, ver **[MODULOS-DETECCION.md](MODULOS-DETECCION.md)**.

---

## 10. Solución de problemas comunes

### Los botones de Discord (Kick/Ban) nunca hacen nada, sin errores visibles

Si acabas de instalar o actualizar el plugin y usaste `sm plugins unload` + `sm plugins load` para aplicarlo, es posible que el temporizador interno que revisa las acciones de Discord no quede correctamente enganchado — es una particularidad conocida de SourceMod con la recarga en caliente de plugins, no un error de configuración. **Solución:** cierra el juego por completo y vuelve a abrirlo (o cambia de mapa) en vez de usar `unload`/`load` después de tocar este plugin.

### "Unknown command" al escribir sm_testdiscord u otro comando

El plugin no está cargado. Revisa `sm plugins list` — si no aparece `anticheat_core.smx`, confirma que el archivo está en `addons/sourcemod/plugins/` de la instalación que realmente arranca el servidor (es fácil tener dos instalaciones de L4D2 y editar la que no se usa).

### "There is a global plugin loading lock in effect"

SourceMod está a mitad de un ciclo de carga. Espera unos segundos y reintenta, o simplemente cambia de mapa:

```
changelevel <nombre_del_mapa_actual>
```

### El comando corre sin error, pero el mensaje nunca llega a Discord

1. Confirma que `sm_ac_discord_webhook` tiene la URL real (no vacía) en `anticheat.cfg`.
2. Confirma que **"REST in Pawn"** aparece en `sm exts list`. Si no aparece, falta el archivo `rip.ext.dll` en `addons/sourcemod/extensions/`, o el juego no se reinició después de instalarlo.
3. Revisa `left4dead2/logs/anticheat/anticheat.log` — cada intento de envío deja una línea con el resultado exacto (éxito o el código de error HTTP). Si no hay **ninguna** línea `[Discord]`, la función crasheó antes de llegar a intentar el envío — revisa `addons/sourcemod/logs/errors_*.log` para ver el error exacto.
4. Si acabas de recargar el plugin (`sm plugins load`), espera unos segundos antes de probar `sm_testdiscord` — el archivo `anticheat.cfg` tarda un instante en aplicarse tras la carga.

> **Nota técnica:** Este plugin usa la extensión **RIPExt** para hablar con Discord, no SteamWorks. SteamWorks es conocida en la comunidad de SourceMod por no completar su ciclo de callback HTTP en muchas configuraciones de servidor — si alguna vez se ve una versión del plugin que mencione SteamWorks para esto, es una versión vieja y hay que actualizarla.

### Un admin nuevo no tiene acceso a los comandos

Verifica que su SteamID esté en `admins_simple.ini` en el formato correcto (`STEAM_0:X:XXXXXXX`, nunca un texto de relleno), y que se haya ejecutado `sm reload admins` después de editarlo.

### El anti-cheat parece "dormido", nunca marca a nadie

Es el comportamiento esperado en partidas cortas o con pocos jugadores: cada detector exige un mínimo de muestras (entre 8 y 40 según el módulo) antes de emitir cualquier puntaje distinto de cero, precisamente para evitar falsos positivos por poca evidencia. Deja pasar unos minutos de juego real antes de sospechar que algo está roto.

---

*Manual interno — AntiCheat L4D2 · Basado en SourceMod 1.12 + RIPExt*
