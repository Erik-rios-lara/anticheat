# L4D2 Anti-Cheat Scanner

**L4D2 Anti-Cheat Scanner** es una herramienta de análisis forense y detección heurística diseñada específicamente para **Left 4 Dead 2** en plataformas **Windows 10/11 (64-bit)**.

La herramienta opera exclusivamente en modo **Solo Lectura** (Read-Only), sin modificar la memoria ni alterar archivos del sistema ni del juego.

---

## Características Principales

1. **Detección Automática de Left 4 Dead 2**:
   - Inspección del registro de Windows y parseo de `libraryfolders.vdf` de Steam.
2. **Análisis de Procesos Activos (`ProcessScanner`)**:
   - Detección de procesos ejecutándose en directorios inusuales (`%TEMP%`, `%APPDATA%`, `%LOCALAPPDATA%`).
   - Verificación de firmas digitales Authenticode y Publishers.
   - Detección de imitación de nombres de procesos del sistema (`svchost.exe`, `lsass.exe`, `csrss.exe`).
3. **Análisis de Módulos y DLLs en Vivo (`ModuleScanner`)**:
   - Inspección de librerías enlazadas al juego en tiempo real.
4. **Análisis de Memoria (`MemoryScanner`)**:
   - Inspección de permisos de memoria (`VirtualQueryEx`).
   - Identificación de regiones RWX (Read/Write/Execute) y memoria ejecutable privada (indicadores de inyección/shellcode/manual mapping).
5. **Análisis del Sistema de Archivos del Juego (`FileScanner`)**:
   - Detección de archivos ocultos o de sistema dentro de la carpeta del juego.
   - Identificación de plugins `.ASI` y ejecutables desconocidos en la raíz o carpetas `bin`.
6. **Sistema de Hashes e Indicadores (`HashScanner`)**:
   - Cálculo de hashes SHA-256 de binarios.
   - Comparación contra base de datos `data/indicators.json` y `data/whitelist.json`.
7. **Mecanismos de Persistencia (`PersistenceScanner`)**:
   - Lectura de claves `Run` del registro (`HKCU`/`HKLM`) y carpeta de inicio automático (`Startup`).
8. **Motor de Riesgo y Reportes Automáticos (`RiskEngine`, `JsonReporter`, `HtmlReporter`)**:
   - Puntuación acumulativa de riesgo.
   - Clasificación por niveles: `INFO`, `SUSPICIOUS`, `HIGH_RISK`, `CRITICAL`.
   - Generación automática de reportes detallados en formato `.json` y `.html` dentro de `./reports/`.

---

## Estructura del Proyecto

```
L4D2AntiCheatScanner/
├── Program.cs                      # CLI & Entrypoint
├── Core/
│   ├── Scanner.cs                  # Orquestador del escaneo
│   ├── ScanContext.cs              # Contexto global
│   └── SignatureChecker.cs         # Verificación de firmas Authenticode
├── Modules/
│   ├── SteamLocator.cs             # Localizador de Steam y L4D2
│   ├── ProcessScanner.cs           # Escaneo de procesos activos
│   ├── ModuleScanner.cs            # Escaneo de DLLs cargadas
│   ├── MemoryScanner.cs            # Escaneo de regiones de memoria
│   ├── FileScanner.cs              # Escaneo del sistema de archivos
│   ├── PersistenceScanner.cs       # Escaneo de registros de inicio
│   └── HashScanner.cs              # Verificación SHA-256
├── Evidence/
│   ├── Finding.cs                  # Modelo de hallazgo
│   ├── EvidenceLevel.cs            # Enum de severidades
│   └── RiskEngine.cs               # Motor de puntuación y riesgo
├── Indicators/
│   ├── IndicatorLoader.cs          # Cargador de indicators.json
│   ├── WhitelistLoader.cs          # Cargador de whitelist.json
│   └── Models/
├── Report/
│   ├── ReportData.cs               # Estructura del reporte
│   ├── JsonReporter.cs             # Exportador JSON
│   └── HtmlReporter.cs             # Exportador HTML
├── data/
│   ├── indicators.json             # Base de indicadores actualizable
│   └── whitelist.json              # Lista blanca de firmas/rutas
└── reports/                        # Directorio generado de reportes
```

---

## Comandos y Uso CLI

```powershell
# Mostrar ayuda
.\L4D2AntiCheatScanner.exe --help

# Escaneo Rápido (Procesos, DLLs, Temp y Persistencia)
.\L4D2AntiCheatScanner.exe --fast

# Escaneo Completo del Juego (Incluye carpeta L4D2, DLLs y Memoria)
.\L4D2AntiCheatScanner.exe --game

# Escaneo Profundo (Analiza profundamente carpetas y sistema)
.\L4D2AntiCheatScanner.exe --deep
```

---

## Compilación y Publicación

### Requisitos de Desarrollo
- SDK de .NET 8 o .NET 10 en Windows x64.

### Generar Ejecutable Portable
Para compilar la versión portable `Release`:

```powershell
dotnet publish -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o publish
```

El ejecutable resultante estará en la carpeta `publish/L4D2AntiCheatScanner.exe`.

---

## Aviso de Exención de Responsabilidad

> ⚠️ **Nota:** Los resultados producidos por este escáner se basan en heurísticas y análisis técnico de indicadores. No constituyen por sí solos una prueba absoluta e irrebatible de cheating, sino evidencias circunstanciales para análisis forense.

