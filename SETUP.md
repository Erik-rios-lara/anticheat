# Poner el anti-cheat a correr en otra PC

Guía para clonar el plugin, compilarlo con SourceMod, y subirlo al mismo servidor de L4D2 que ya estamos usando. Pensada para alguien que va a tocar el código, no solo jugar.

Repositorio: https://github.com/Erik-rios-lara/anticheat

## 1. Requisitos

Dos cosas hacen falta antes de tocar código: Git para bajar el repositorio, y el compilador de SourcePawn (`spcomp`) para convertir el `.sp` en el `.smx` que SourceMod realmente ejecuta. El compilador ya viene incluido dentro del propio repo, así que no hay que instalar SourceMod completo en esta PC — solo Git.

- **Git** — https://git-scm.com/downloads, instalación por defecto sirve.
- **Un editor de texto/código** — VS Code recomendado, con la extensión `SourcePawn` del marketplace para resaltado de sintaxis.

No hace falta instalar un servidor de L4D2 local ni SourceMod completo en esta PC — el servidor real ya está corriendo donde siempre, solo vamos a compilar aquí y subir el archivo resultante ahí.

## 2. Clonar el repositorio

El repo es público, así que no necesitas que te invite como colaborador para clonarlo y compilar en tu máquina. Abre una terminal donde quieras guardar el proyecto y corre:

```bash
# Windows (PowerShell o Git Bash), en la carpeta donde quieras el proyecto
git clone https://github.com/Erik-rios-lara/anticheat.git
cd anticheat
```

Esto trae los 20+ archivos `.sp` del anti-cheat (aim, bhop, integrity, correlation, evidence, etc.), el compilador `spcomp.exe`, y el bot de Discord en `discord-bot/`.

## 3. Compilar el plugin

El archivo principal es `anticheat_core.sp` — incluye a todos los demás módulos vía `#include`, así que compilarlo a él genera el `.smx` completo.

Dentro de la carpeta `anticheat/`:

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

> **Si ves "Error"** en vez de solo warnings, el `.smx` no se generó — no lo subas al servidor. Pega el error completo en el chat del equipo antes de continuar.

## 4. Subir el .smx al servidor compartido

Como vamos a usar el mismo servidor de L4D2 que ya tenemos, este paso es copiar el archivo compilado a la carpeta de plugins de ese servidor — reemplazando el que ya está ahí.

| Archivo | Destino en el servidor |
|---|---|
| `anticheat_core.smx` | `addons/sourcemod/plugins/` |

Cómo llega el archivo hasta ahí depende de cómo esté hosteado el servidor — pide el acceso (SFTP, panel del host, o carpeta compartida si corre en una PC) y comparte los datos de conexión exactos por un canal privado, no en el repo.

> **Coordinen antes de subir** — si los dos compilan y suben al mismo tiempo, uno pisa el cambio del otro sin que se note hasta que algo se comporta raro en partida.

## 5. Recargar el plugin sin reiniciar el servidor

Con el `.smx` nuevo ya en su carpeta, en la consola del servidor (o vía RCON):

```
sm plugins reload anticheat_core
```

Confirma que tomó el cambio:

```
sm plugins list
```

Debe aparecer `anticheat_core` como `Running`. Si el servidor está vacío, reiniciar el mapa (`changelevel` al mapa actual) también sirve, pero normalmente no hace falta.

## 6. Flujo de trabajo día a día

Para que los cambios de ambos no se pisen, la rutina normal es:

1. Antes de editar: `git pull` para traer lo último que el otro subió.
2. Edita el/los archivo(s) `.sp` que correspondan al módulo que estás tocando.
3. Compila local (paso 3) y revisa que no salgan errores nuevos.
4. `git add`, `git commit -m "..."`, `git push` — así el otro ve tu cambio en el historial.
5. Solo entonces sube el `.smx` compilado al servidor y recarga (pasos 4-5).

El `.smx` compilado nunca se sube a GitHub (está en `.gitignore`) — cada quien compila su propia copia desde el mismo código fuente, así el repo se queda solo con lo que de verdad importa versionar: el `.sp`.

---

Módulos activos ahora mismo: aim (headshot ratio, psilent, autoshoot, fov lock), bhop, bhop2, integrity, nolerp, osac, correlation, evidence, target acquisition, variance profiling, shot decision — más el bot de Discord para alertas de kick. Cualquier duda de un módulo específico, pregunten en el chat antes de tocarlo a ciegas.
