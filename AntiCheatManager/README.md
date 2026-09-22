# AntiCheat L4D2 Manager

## Requisitos
- Windows 10 o Windows 11 (64 bits).
- .NET 10 (o .NET 8, según el runtime de tu equipo).
- El servidor de Left 4 Dead 2 con MetaMod:Source y SourceMod previamente instalados.

## Uso del Manager
1. Ejecuta el archivo `AntiCheatManager.exe`.
2. La aplicación buscará automáticamente la ruta de instalación de Left 4 Dead 2 a través de Steam. Si no la encuentra, haz clic en **Buscar Manualmente** y selecciona la carpeta `Left 4 Dead 2`.
3. Para instalar el Anti-Cheat, haz clic en **Instalar Anti-Cheat**. Esto copiará los archivos necesarios de `addons` y `cfg` de forma segura.
4. Para activar o desactivar el Anti-Cheat, utiliza el botón **ACTIVAR / DESACTIVAR ANTI-CHEAT**. Esto renombra internamente el archivo `.smx` a `.smx.disabled`.
5. Si quieres ver los registros del Anti-Cheat, haz clic en **Ver Logs**.

## Estructura Portable
Este `.exe` es *single-file* (un solo archivo) y *framework-dependent* (requiere que tengas .NET instalado en tu sistema para mantener un peso muy reducido). Se recomienda que lo mantengas junto a la carpeta `addons/` para que la instalación encuentre los archivos origen de forma automática.

## Compilación del .exe (Para Desarrolladores)
Si deseas modificar el Manager y volver a generar el ejecutable, abre una terminal en la carpeta `AntiCheatManager` y ejecuta:

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true
```

El ejecutable se generará en:
`AntiCheatManager\bin\Release\net10.0-windows\win-x64\publish\AntiCheatManager.exe`

