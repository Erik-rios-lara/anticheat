@echo off
REM anticheat_toggle.bat - Activa/desactiva el plugin anti-cheat moviendo
REM anticheat_core.smx dentro/fuera de la carpeta de plugins de SourceMod.
REM
REM Ajusta PLUGINS_DIR si tu servidor de L4D2 esta instalado en otra ruta.
setlocal

set PLUGINS_DIR=E:\SteamLibrary\steamapps\common\Left 4 Dead 2\left4dead2\addons\sourcemod\plugins
set ACTIVE_FILE=%PLUGINS_DIR%\anticheat_core.smx
set DISABLED_FILE=%PLUGINS_DIR%\anticheat_core.smx.disabled

:menu
cls
echo ============================================
echo   Anti-Cheat L4D2 - Activar / Desactivar
echo ============================================
echo.
if exist "%ACTIVE_FILE%" (
    echo Estado actual: ACTIVADO
) else if exist "%DISABLED_FILE%" (
    echo Estado actual: DESACTIVADO
) else (
    echo Estado actual: NO ENCONTRADO ^(revisa PLUGINS_DIR en este .bat^)
)
echo.
echo   [1] Activar el anti-cheat
echo   [2] Desactivar el anti-cheat
echo   [3] Ver estado
echo   [4] Salir
echo.
set /p opcion="Elige una opcion: "

if "%opcion%"=="1" goto activar
if "%opcion%"=="2" goto desactivar
if "%opcion%"=="3" goto menu
if "%opcion%"=="4" goto fin
goto menu

:activar
if exist "%ACTIVE_FILE%" (
    echo.
    echo El anti-cheat ya esta activado.
) else if exist "%DISABLED_FILE%" (
    ren "%DISABLED_FILE%" anticheat_core.smx
    echo.
    echo Anti-cheat activado.
    echo IMPORTANTE: en la consola del juego ^(tecla ~^) escribe:
    echo     sm plugins refresh
    echo para que el servidor lo cargue sin reiniciar el mapa.
) else (
    echo.
    echo No se encontro ni anticheat_core.smx ni anticheat_core.smx.disabled
    echo Revisa la ruta PLUGINS_DIR configurada en este .bat.
)
echo.
pause
goto menu

:desactivar
if exist "%DISABLED_FILE%" (
    echo.
    echo El anti-cheat ya esta desactivado.
) else if exist "%ACTIVE_FILE%" (
    ren "%ACTIVE_FILE%" anticheat_core.smx.disabled
    echo.
    echo Anti-cheat desactivado.
    echo IMPORTANTE: en la consola del juego ^(tecla ~^) escribe:
    echo     sm plugins unload anticheat_core
    echo para descargarlo sin reiniciar el mapa.
) else (
    echo.
    echo No se encontro ni anticheat_core.smx ni anticheat_core.smx.disabled
    echo Revisa la ruta PLUGINS_DIR configurada en este .bat.
)
echo.
pause
goto menu

:fin
endlocal
