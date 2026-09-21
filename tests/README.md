# Simulador de regresiones

Ejecuta desde la raíz del repositorio:

```powershell
.\tests\anti-cheat-simulator.ps1
```

El simulador lee pesos y umbrales directamente de `anticheat_core.sp` y los
parámetros de correlación de `anticheat_correlation.sp`. Después ejecuta los
casos en `tests/scenarios.json` y devuelve un código distinto de cero si uno
no coincide con el resultado esperado. Esto permite incluirlo en CI más
adelante.

Cada evaluación inyecta el score que ya habría producido cada detector. El
simulador verifica la lógica compartida de producción: máximo de submódulos de
Aim/Bhop, suma ponderada, correlación, nivel de evidencia y confirmaciones
antes de expulsar. Los nombres aceptados para los submódulos de Aim son
`targetAcq`, `aimVariance`, `shotDecision`, `aimDrift`, `tracking`,
`aimHoneypot` y `klDivergence`; para Bhop son `bhop2` y `bhopVariance`.

No simula `OnPlayerRunCmd`, entidades, armas ni hooks de L4D2. Esos detectores
dependen del motor y deben probarse en un servidor de pruebas con telemetría o
replays reales. Este límite es intencional: inventar física del motor en
PowerShell daría una falsa sensación de cobertura.

Para añadir una regresión, agrega un escenario con una o más `evaluations`.
Los eventos opcionales (`detector`, `age`, `severity`) permiten probar la
ventana de correlación. El objeto `expected` valida el `risk`, `level` y
`action` de la última evaluación.
