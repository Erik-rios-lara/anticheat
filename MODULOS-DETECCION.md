# Módulos de detección — AntiCheat L4D2

Este documento explica **qué hace cada módulo de detección**, cómo funciona técnicamente, y qué tipo de trampa detecta. El sistema combina 5 módulos independientes en un único **Risk Score (0-100)** evaluado cada 10 segundos por jugador.

```
Risk = (Aim×42% + Bhop×22% + Integrity×11% + NoLerp×10% + OSAC×15%) × Multiplicador de Correlación
```

(El módulo Bhop-2 no tiene peso propio: su puntaje se combina con el de Bhop tomando el máximo de ambos.)

Cada módulo produce su propia puntuación 0-100 de forma totalmente independiente — ninguno depende de los demás para funcionar. Esto es deliberado: un cheat puede evadir un módulo pero rara vez evade los 5 a la vez, y cuando **un solo módulo** llega a 60/100 por sí solo (`STRONG_MODULE_THRESHOLD`), eso ya es evidencia suficiente para expulsar al jugador aunque el Risk total combinado no llegue al umbral. **Este gate usa siempre el score individual de cada módulo, nunca el Risk ya multiplicado por correlación** — la correlación acelera qué tan rápido se junta evidencia ya confirmada, pero nunca sustituye la necesidad de que algún módulo confirme su propia evidencia primero.

Archivo fuente de cada módulo entre paréntesis.

---

## 1. Aim (`anticheat_aim.sp`) — peso 42%

El módulo más grande: combina **4 vías de detección distintas**, cada una mirando una señal diferente de aimbot/silent-aim. El score final de Aim es el **máximo** de las 4 (no la suma) — basta con que una sola vía dé evidencia fuerte. Además se combina (también por máximo) con el módulo Target Acquisition Analysis descrito más abajo.

Filtro común a todas las vías: solo se evalúan disparos/ángulos contra **Infectados Especiales** (Smoker, Hunter, Boomer, Tank, etc. — no Comunes) y a una distancia mínima de 200 unidades, para no confundir el combate cuerpo a cuerpo legítimo (caótico por naturaleza) con evidencia de trampa.

### Vía 1 — Headshot Snap + Consistencia
**Qué detecta:** el salto angular justo antes de un headshot a un Infectado Especial, evaluado por qué tan *consistente* es ese salto a lo largo de varios disparos.

**Por qué funciona:** el servidor nunca puede saber si tu mira "de verdad" apuntaba a la cabeza o si un aimbot la corrigió — ambos casos producen el mismo dato final. Pero sí puede medir *cómo cambió* el ángulo entre el tick anterior y el del disparo. Un humano que hace un flick de pánico varía mucho el tamaño de ese salto de un disparo a otro; un script que autoajusta a la cabeza produce saltos de tamaño casi idéntico, una y otra vez (desviación estándar baja).

**Umbral:** salto ≥2.0°, se necesitan ≥5 disparos calificados, consistencia (desviación estándar) por debajo de 4.0° para puntuar alto.

### Vía 2 — Angle Repeat (técnica de StAC-tf2)
**Qué detecta:** un salto angular aislado mientras se dispara — ruido, SALTO, ruido, ruido — en 5 ticks consecutivos, sin requerir que sea headshot ni siquiera que impacte.

**Por qué funciona:** un humano apuntando, incluso al "trabar" la mira sobre un objetivo, siempre tiene un poco de temblor de mano justo antes y después del ajuste. Un script que salta directo al objetivo y se queda perfectamente quieto produce un patrón muy específico: casi cero movimiento → un salto grande → casi cero movimiento otra vez. Es más difícil de evadir que un simple umbral de tamaño de salto, porque agregar "ruido" deliberado para camuflarlo arruina la puntería o reproduce el mismo patrón detectable.

**Umbral:** ruido <0.5°, salto >10°, se necesitan ≥5 eventos.

### Vía 3 — Cmdnum Spike (técnica de StAC-tf2)
**Qué detecta:** el número de comando (`cmdnum`) del cliente saltando varios valores de golpe en el mismo tick que se dispara.

**Por qué funciona:** esto es completamente independiente de los ángulos de la mira — algunos cheats no tocan el mouse en absoluto, sino que manipulan el contador de secuencia de comandos para forzar un "disparo perfecto" que se salta el patrón de dispersión de balas (bullet spread) que el servidor aplicaría normalmente. Es justo el mecanismo detrás de "el recoil/dispersión del arma no se dispersa" al hacer trampa.

**Umbral:** salto ≥12 en tick de disparo (≥32 fuera de disparo, para tolerar jitter de spawn/carga), se necesitan ≥3 eventos.

### Vía 4 — Aimlock (técnica de Lilac / Little-Anti-Cheat)
**Qué detecta:** convergencia angular sostenida hacia un Infectado Especial a lo largo de varios ticks — sin necesidad de que llegue a disparar.

**Por qué funciona:** mide cuánto ángulo le queda al jugador para apuntar exactamente al objetivo, tick a tick. Un humano cierra esa distancia de forma gradual y con ruido. Un script que "engancha" el objetivo colapsa el ángulo restante casi instantáneamente (a ≤10% del ángulo del tick anterior) mientras además produjo un salto grande (≥20°) para llegar ahí — algo que un humano cerrando esa distancia tan rápido no puede producir porque no le queda ángulo "sobrante" que colapsar. Debe sostenerse 7 ticks seguidos (~0.1s) para contar, evitando falsos positivos de un solo tick suelto.

**Umbral:** convergencia ≤10% del delta anterior + salto ≥20°, sostenido ≥7 ticks, se necesitan ≥2 eventos confirmados.

---

## 1b. Target Acquisition Analysis (`anticheat_targetacq.sp`) — se combina con Aim (máximo)

Aimlock (Vía 4) mide una sola transición tick-a-tick: "¿el ángulo restante se colapsó mucho justo después de un salto grande?". Este módulo mira la **sesión completa** de adquisición — desde que un Infectado Especial se convierte en el objetivo relevante más cercano hasta que el jugador dispara o lo pierde de vista — y analiza toda la trayectoria, no solo un instante.

### Cómo funciona

Cada tick mientras hay una "sesión" abierta contra un objetivo, se registra el error angular respecto a ese objetivo. Al cerrar la sesión (por disparo, cambio de objetivo, o timeout de 2s) se reduce a tres métricas: **tiempo de adquisición** (desde que se abrió la sesión hasta que el error cayó bajo 5°), **si terminó en disparo**, y **ratio de monotonicidad** (qué fracción de los ticks tuvo el error angular estrictamente decreciente respecto al anterior).

En vez de puntuar una sola sesión, el sistema acumula un historial de hasta 24 sesiones cerradas por jugador y analiza la **distribución** completa:

- **Consistencia del tiempo de adquisición** — se mide con el coeficiente de variación (desviación estándar / media), no la desviación cruda, para que sea comparable sin importar si el jugador tarda 80ms o 400ms en promedio. Un humano, incluso muy bueno o con sensibilidad alta, muestra variación real de una sesión a otra porque la reacción + control de mouse no es una función de latencia fija. Un script converge en una banda de tiempo estrecha y repetible sin importar la distancia o el ángulo del objetivo.
- **Monotonicidad sostenida** — una sola sesión con reducción de error suave y monótona no es rara (un humano rastreando bien lo hace a veces). Que **muchas sesiones independientes** muestren consistentemente alta monotonicidad es lo que produce un asistente de puntería tipo PID programado, y lo que el rastreo humano guiado por overshoot/corrección casi nunca produce por casualidad en una muestra grande.

**Importante — ninguna señal es prueba por sí sola:** el diseño exige que **ambas** métricas (timing Y monotonicidad) muestren algo simultáneamente; se combinan con media geométrica en vez de promedio simple, así que una señal fuerte en un solo eje no puede cargar sola el score. Esto es deliberado: la ausencia de errores humanos, por sí sola, nunca cuenta como evidencia — solo la combinación de ambas irregularidades estadísticas sostenidas en el tiempo.

**Umbral:** se necesitan ≥6 sesiones cerradas y "alcanzadas" (llegaron a estar sobre el objetivo) antes de puntuar. Coeficiente de variación del tiempo <0.35 y monotonicidad media ≥70% para empezar a puntuar.

**Rendimiento:** solo corre para jugadores en nivel de vigilancia ≥1 (igual que Aimlock/TriggerBot) — un jugador limpio nunca paga este costo.

---

## 1c. Statistical Consistency / Variance Profiling — Aim (`anticheat_variance.sp`) — se combina con Aim (máximo)

Todos los demás detectores comparan contra un **umbral global fijo** (ej. "salto ≥2°"). Este módulo hace algo distinto: construye un perfil propio de **cada jugador** a través de varios encuentros independientes y pregunta si su propia varianza colapsa de una forma que la variabilidad humana natural no podría producir por casualidad. El objetivo explícito **no es detectar a un jugador bueno**, sino detectar comportamiento artificialmente repetitivo a través de suficientes muestras.

### Cómo funciona

Mientras el jugador rastrea al mismo Infectado Especial de forma continua (un "bloque de encuentro"), se mide la velocidad angular en cada tick y se acumula su media y varianza internas usando el algoritmo de Welford (sin guardar cada muestra cruda). Al cerrar el bloque — porque cambió de objetivo, lo perdió, o pasaron ≥1.5s sin verlo — se guarda solo ese bloque: su velocidad angular media y su desviación estándar interna.

Con un historial de ≥6 bloques cerrados, se mide la **varianza entre bloques** (no dentro de uno):

- **Consistencia de la velocidad media** — encuentros distintos (distinta distancia, distinto movimiento relativo del objetivo, distinta arma) deberían producir dinámicas de rastreo distintas en un humano. Un bucle de control programado tiende a reproducir una velocidad media casi idéntica sin importar qué esté pasando realmente en cada encuentro.
- **Consistencia de la suavidad interna** — la desviación estándar *dentro* de cada bloque debería variar de un encuentro a otro también; que se mantenga casi igual siempre es la segunda señal.

Ambas se miden con coeficiente de variación (no varianza cruda) para ser independientes de la escala — no importa si el jugador rastrea rápido o lento en general, solo importa qué tan **consistente** es consigo mismo entre encuentros que no deberían parecerse.

**Umbral:** se necesitan ≥6 bloques de encuentro (mínimo 8 ticks cada uno). Coeficiente de variación de las medias <0.25 Y de las desviaciones estándar <0.30 — **ambos** deben cumplirse a la vez.

**Rendimiento:** igual que Target Acquisition, solo corre en vigilancia ≥1.

---

## 2. Bhop (`anticheat_bhop.sp`) — peso 22%

Detecta bunny-hop automatizado (scripts que saltan en el tick exacto de aterrizaje para no perder velocidad), combinando **3 métricas**.

### Métrica 1 — Ratio de saltos perfectos
Cada vez que el jugador aterriza, hay una ventana de 1 tick para volver a saltar sin perder momentum. Un humano acierta esa ventana ~30-60% de las veces; un script la acierta casi el 100%. Se necesitan ≥20 aterrizajes registrados antes de puntuar. Curva de puntuación:
- <40% de aciertos → 0 puntos (rango humano)
- 40-65% → puntuación baja-media
- 65-80% → muy sospechoso
- >80% → prácticamente confirmado como script

### Métrica 2 — Racha máxima
Una racha de ≥8 saltos perfectos consecutivos añade puntos extra (hasta +25) — los humanos rara vez sostienen más de 5 seguidos.

### Métrica 4 — Cadena de bhop perfecto SIN air-strafing
En Source engine no puedes mantener un bhop rápido sin hacer **air-strafing**: en cada salto tienes que barrer el mouse a izquierda/derecha sincronizado con las teclas A/D para ganar (o siquiera conservar) velocidad. Un bhopper con skill *siempre* lo hace — es mecánicamente obligatorio.

Un autohop mantiene la velocidad por ti. Alguien que lo usa pero no sabe hacer bhop **no hace air-strafing** — solo mueve el mouse para dirigirse hacia donde va, o casi no lo mueve. Así que: una cadena larga de saltos perfectos donde la mayoría **no tuvieron un air-strafe real** es la firma de "autohop, sin skill".

Un salto cuenta como "con air-strafe" cuando, durante su fase aérea: se mantuvo exactamente una de A/D presionada al menos el 40% de los ticks, Y el yaw giró en la dirección correspondiente (A→izquierda, D→derecha) al menos 3°. Si ≥70% de una cadena de ≥6 saltos perfectos no cumple esto → sospecha (score 55-100 según qué tan alta sea la proporción sin strafe).

### Métrica 3 — Honeypot de gravedad (técnica de StAC-tf2)
En cuanto la racha llega a 8 saltos perfectos consecutivos, el plugin **multiplica silenciosamente la gravedad del jugador** por un valor aleatorio entre 6.1x y 7.9x, sin avisar. El timing de un bunny-hopper humano está calibrado para la gravedad normal — el cambio de física rompe ese "feel" y falla el salto de inmediato. Un script, en cambio, reacciona solo a la bandera `FL_ONGROUND` del motor, no al *feel* del salto, así que sigue acertando perfecto incluso con la gravedad alterada. Si sobrevive 3 saltos perfectos bajo gravedad honeypot, el score se fuerza a 100 — evidencia prácticamente irrefutable, físicamente casi imposible de producir por un humano. Si falla un salto mientras el honeypot está activo, se le devuelve la gravedad normal sin penalización (así se comportaría alguien legítimo).

---

## 2a. Statistical Consistency / Variance Profiling — Bhop (`anticheat_variance.sp`) — se combina con Bhop (máximo)

Misma filosofía que la versión de Aim, aplicada al timing de salto. En vez de solo clasificar cada salto como "perfecto" o no, mide el **tiempo real en milisegundos** entre aterrizar y presionar salto — incluyendo saltos tardíos, no solo los que caen en la ventana de 1 tick.

### Cómo funciona

Los saltos se agrupan en **secuencias** (cadenas continuas, igual que el concepto de racha del módulo Bhop). Dentro de cada secuencia se acumula la media y varianza del tiempo de reacción salto-a-salto. Al cerrar la secuencia (por inactividad prolongada), se guarda su desviación estándar interna.

Con ≥5 secuencias cerradas, se mide la **desviación estándar entre secuencias distintas**. Aquí se usa la desviación absoluta (no coeficiente de variación) porque los valores ya están acotados a un rango estrecho de 0-15ms por definición de "ventana perfecta" — un humano que acierta esa ventana repetidamente todavía tiene jitter de unos pocos milisegundos de una secuencia a otra (cansancio, distracción, qué tan bien "se sintió" cada salto en particular). Un temporizador programado produce un jitter casi nulo entre secuencias completamente distintas (terreno distinto, punto distinto del mapa).

**Umbral:** ≥5 secuencias de ≥5 saltos cada una. Desviación estándar entre secuencias por debajo de 3ms para empezar a puntuar.

**Rendimiento:** corre para todos los jugadores cada tick — es aritmética barata, sin búsqueda de objetivo ni trigonometría, igual que el resto del módulo Bhop original.

---

## 2b. Bhop-2 (`anticheat_bhop2.sp`) — sin peso propio (se combina con Bhop)

Segundo detector de bhop **totalmente independiente**, con el algoritmo de [AntiBhopCheat](https://github.com/srcdslab/sm-plugin-AntiBhopCheat). Mientras que el módulo Bhop mira *si* el salto aterrizó en el tick perfecto, éste mira *cómo se produjo la pulsación del salto*. El score final de Bhop es el máximo entre los dos módulos, así que actúan como corroboración mutua.

### Sub-chequeo 1 — Hyperscroll
Un bind `+jump` normal dispara el botón una vez por pulsación. Un script de scroll-wheel o un macro envía **muchos eventos `+jump` por tick** (10-20 por segundo). Si la relación presiones-por-tick llega a ≥0.85 con al menos 3 presiones en el salto, es spam de scroll — algo que un pulgar humano no hace.

### Sub-chequeo 2 — Salto "hack" compuesto
Marca un salto como scripted solo si cumple **las 3 condiciones a la vez**: gap al siguiente salto ≤1 tick + (gap >5 ticks O ≤2 presiones) + velocidad de salida ≥285 u/s. Un bunny-hopper humano no acierta las 3 simultáneamente y de forma repetida.

### Decisión
Se evalúa sobre una racha de saltos encadenados. Si una racha de ≥6 saltos es ≥90-95% saltos "hack" o ≥95% hyperscroll → score 100. También hay una evaluación de por vida (≥30 saltos totales, umbrales 75-80%) que es más lenta de disparar pero más difícil de discutir.

---

## 3. Integrity (`anticheat_integrity.sp`) — peso 11%

Dos chequeos de **integridad del paquete de red**, no de comportamiento — verifican si el `usercmd` que mandó el cliente es siquiera físicamente posible de producir por un cliente legítimo. Casi cero falsos positivos por construcción, así que pesan fuerte en cuanto se disparan. El score del módulo es el máximo de los dos sub-chequeos.

### Fake Angles (técnica de StAC-tf2)
**Qué detecta:** ángulo de pitch fuera de ±89° o de roll fuera de ±50°.

**Por qué funciona:** son límites físicos que el propio código de entrada del cliente aplica antes de construir el comando — un cliente real jamás puede enviar ángulos fuera de ese rango. Algunos cheats rudimentarios (herramientas de ESP/aim antiguas que tocan los ángulos de vista directamente) se saltan ese límite.

**Umbral:** ≥3 eventos.

### Invalid Usercmd (técnica de StAC-tf2)
**Qué detecta:** `cmdnum` o `tickcount` negativos, o el bitmask de botones usando bits que el juego nunca activa (≥ bit 26, ya que `IN_ATTACK3` es la bandera real más alta en 1<<25).

**Por qué funciona:** indica un comando hecho a mano o corrupto, no uno que produjo el cliente real — otra capa de detección totalmente distinta a analizar comportamiento, ataca directamente la manipulación del paquete.

**Umbral:** ≥3 eventos.

---

## 4. NoLerp (`anticheat_nolerp.sp`) — peso 10%

**Qué detecta:** el cliente configurando su interpolación (`cl_interp`) por debajo del mínimo físicamente posible dado su `cl_interp_ratio` y `cl_updaterate`.

**Por qué funciona:** algunos cheats bajan la interpolación del cliente a 0ms (o menos del mínimo real) para quitarle el "colchón" de suavizado a la posición percibida de los objetivos — esto hace que los aimbots de snap/flick sean notablemente más precisos, porque reaccionan a la posición más reciente sin demora. A diferencia de todos los demás módulos, este **no analiza comportamiento tick a tick** — simplemente le pregunta al cliente su configuración cada 5 segundos vía `QueryClientConVar` y la compara contra el mínimo calculado (`cl_interp_ratio / cl_updaterate`, con 5% de margen para redondeo). Por eso es casi cero falsos positivos: es solo lectura de configuración, no un patrón estadístico.

**Umbral:** interp reportado <95% del mínimo físico calculado, se necesitan ≥3 confirmaciones (para que un glitch de consulta puntual no dispare el módulo solo).

---

## 5. OSAC (`anticheat_osac.sp`) — peso 15%

Cinco detectores reimplementados de [OSAntiCheat](https://github.com/Pintuzoft/OSAntiCheat), un anti-cheat estadístico de CS2 cuyos umbrales fueron leídos de un archivo de 17.000 demos reales, no adivinados. Todos son de estilo **"logic breach"**: la población honesta *nunca* produce su firma, así que un patrón confirmado es casi certeza, no mera sospecha. Todos van filtrados (como el resto del sistema) a un superviviente disparando a un Infectado Especial. El score del módulo es el máximo de los cinco.

### Vía 1 — Bone-lock
**Qué detecta:** disparos que aterrizan repetidamente a **≤0.05° del centro de la cabeza** — por debajo de medio paso de cuantización angular del motor.

**Por qué funciona:** un humano, incluso un profesional, coloca sus tiros en una "joroba motora" de 1-2° alrededor del centro de la cabeza. Un aimbot que engancha el hueso ocupa un rango físico separado, a ≤0.05°, con varianza casi nula. En ~1,5 millones de disparos archivados, la población honesta jamás cayó en ese rango de forma repetida. Solo se cuenta el primer disparo de cada ráfaga, y la mira tiene que haber recorrido ≥2° desde el último lock para contar uno nuevo (un lock sostenido = un evento). **Umbral:** ≥3 locks distintos.

### Vía 2 — Silent Aim (trayectoria)
**Qué detecta:** una bala que **registra daño mientras la mira del jugador apuntaba a ≥10° de la posición de la víctima**.

**Por qué funciona:** el módulo Cmdnum Spike de Aim detecta el *método* de un silent-aim (salto de comando); esto detecta el *resultado imposible* directamente — daño aplicado sin que la mira estuviera cerca. Los abridores de ráfaga honestos llegaron como máximo a 8.0° en 3.486 muestras; cero por encima de 10°. **Umbral:** ≥3 disparos así.

### Vía 3 — TriggerBot
**Qué detecta:** un disparo hecho **menos de 90ms después de que la mira cruzó sobre un Infectado Especial**, siempre que el jugador estuviera moviendo activamente la mira hacia el objetivo (no un pre-apuntado estático).

**Por qué funciona:** el tiempo de reacción humano mínimo verificado es ~90ms; por debajo de 20ms es certeza matemática de trigger automático. Se camina hacia atrás por el historial de ángulos para encontrar el tick del "cruce" y se mide el tiempo hasta el disparo. Se exige un barrido de ≥5° en los ticks previos para descartar que el enemigo simplemente caminó hacia una mira quieta. **Umbral:** ≥4 eventos en 60 segundos.

### Vía 4 — KillBurst
**Qué detecta:** **≥4 headshots letales a Infectados Especiales distintos en 15 segundos**.

**Por qué funciona:** en L4D2 los Infectados Especiales casi siempre aparecen de golpe (Hunter saltando, Smoker desde atrás, Jockey desde un lado). Encadenar 4 headshots letales a Especiales distintos en 15s sin fallar es exactamente el patrón de aimbot + wallhack. En 17.000 demos, este patrón apareció 2 veces — ambas cheaters confirmados. **Umbral:** ≥4 víctimas distintas.

### Vía 5 — SpinBot
**Qué detecta:** una **velocidad de giro (yaw) sostenida imposible para una muñeca humana** — ≥1000°/s mantenida sin interrupción por ≥720° (dos vueltas completas).

**Por qué funciona:** un humano puede hacer un flick rápido durante un instante, pero no puede *sostener* >1000°/s de forma continua y en una sola dirección. Cualquier cambio de dirección o caída de velocidad rompe la cuenta. **Umbral:** ≥2 eventos (uno solo se descarta como fluke).

---

## Motor de correlación entre detectores (`anticheat_correlation.sp`)

Hasta ahora el sistema solo *sumaba* los scores de los 5 módulos con pesos fijos — un módulo mostrando sospecha leve y tres módulos independientes disparando en el mismo instante producían el mismo tipo de resultado, solo con distinta magnitud. El motor de correlación agrega una capa encima de eso, **sin tocar la lógica interna de ningún detector existente**.

### Cómo funciona

Cada sub-detector (los 13 descritos arriba: 4 de Aim, 1 de Bhop, 2 de Bhop-2, 2 de Integrity, 1 de NoLerp, 5 de OSAC) reporta al motor de correlación el instante exacto en que registra un evento crudo — el mismo momento en que ya escribía en su propio historial interno, sin cambiar cuándo ni por qué dispara. Cada reporte lleva: qué detector fue, cuándo, y qué tan severo fue ese evento puntual (0-100).

El motor busca, dentro de una ventana de **1.5 segundos**, la mayor cantidad de **detectores distintos** que dispararon cerca uno del otro. Si solo un detector repite su propia señal varias veces, eso ya está reflejado en el score de ese módulo — no aporta nada nuevo. Pero si, por ejemplo, en el mismo segundo y medio se registran un evento de Angle Repeat, un TriggerBot y un BoneLock, eso es una cadena de evidencia que ningún módulo por separado puede ver: "el objetivo se volvió relevante → la mira saltó → adquisición perfecta → disparo casi instantáneo → impacto imposible", exactamente el patrón que un cheat real produce y que un jugador legítimo casi nunca replica en una ventana tan corta.

### El multiplicador

`Correlation_GetMultiplier()` devuelve un factor entre **1.0x** (sin correlación, el caso normal) y **1.6x** (varios detectores independientes coincidiendo con alta severidad). Ese factor se multiplica sobre el Risk Score ya calculado — **nunca puede inventar riesgo de la nada**: 1.6× sobre un Risk de 0 sigue siendo 0. Solo amplifica evidencia que ya existe, haciendo que llegue más rápido a los umbrales de aviso/expulsión cuando viene de fuentes independientes.

### Por qué es seguro

- El gate que autoriza la expulsión automática (`STRONG_MODULE_THRESHOLD`) sigue mirando los scores **individuales sin multiplicar** de cada módulo — la correlación nunca puede sustituir la exigencia de que al menos un detector ya haya confirmado su propia evidencia por sí solo.
- Los eventos de "ruido esperable" (ej. cada headshot legítimo a un Especial) no se reportan al motor — solo se reporta cuando el propio detector ya decidió que el evento cruza su umbral interno, o en el caso de KillBurst, solo cuando el patrón de ráfaga ya está confirmado.
- El log de riesgo ahora incluye el multiplicador aplicado (`corr x1.35`) y, cuando hay correlación relevante, una línea `[Correlation]` describiendo qué detectores coincidieron y en qué ventana — visible también en `sm_ac_view` y en el menú in-game, para que un admin pueda auditar por qué el riesgo subió más rápido de lo esperado.

---

## Modelo de evidencia por niveles (`anticheat_evidence.sp`)

El Risk Score (0-100) sigue siendo un único número, pero mezclaba conceptos distintos: *qué tan fuerte* es la tendencia acumulada, *qué tan seguro* se puede estar de que es evidencia real y no ruido, *qué tan grave* es el peor indicio individual, y *cuánta* evidencia hay. Este módulo separa esos cuatro conceptos y clasifica cada evaluación en uno de 4 niveles, sin cambiar la matemática de ningún detector ni del Risk Score en sí.

### Los cuatro números

- **RiskScore** — el mismo 0-100 de siempre (suma ponderada × multiplicador de correlación).
- **Confidence** (0.0-1.0) — qué tan confiable es esta evaluación. Sube con la fuerza del peor módulo, con el multiplicador de correlación, y de forma extra si un módulo "logic breach" (Integrity, NoLerp, OSAC) disparó fuerte.
- **Severity** (0-100) — el peor score individual de los 5 módulos, **sin** el multiplicador de correlación — mide qué tan grave es la peor pieza de evidencia por sí sola.
- **EvidenceCount** — cuántos detectores independientes contribuyeron (viene directo del motor de correlación; mínimo 1).

### Los cuatro niveles

| Nivel | Cuándo se alcanza | Efecto práctico |
|---|---|---|
| **INFO** | Risk por debajo de 15 | Ninguno — ni siquiera se registra en el log |
| **STATISTICAL** | Risk ≥15 mediante un patrón repetido, sin corroboración de otros detectores | Se acumula riesgo normalmente; para expulsar exige las 3 confirmaciones consecutivas de siempre (~15-30s sostenidos) |
| **CORRELATED** | ≥2 detectores independientes coincidieron en la ventana de 1.5s del motor de correlación | Prioridad alta para revisión de admin; sigue exigiendo las 3 confirmaciones para actuar automáticamente |
| **VIOLATION** | Algún módulo "logic breach" (Fake Angles, Invalid Usercmd, NoLerp, BoneLock, SilentAim, SpinBot) alcanzó por sí solo el umbral de módulo fuerte (60/100) | **Solo exige 1 confirmación**, no 3 — son estados que un cliente legítimo no puede producir estructuralmente, no una tendencia de comportamiento que podría ser mala suerte repetida |

### Por qué esto es seguro

- El requisito de que **algún módulo individual llegue a 60/100** (`STRONG_MODULE_THRESHOLD`) sigue siendo obligatorio para todos los niveles antes de siquiera considerar una expulsión — el modelo de evidencia nunca se salta ese filtro, solo decide cuánto tiempo hay que sostener la evidencia una vez que ya lo pasó.
- Bajar las confirmaciones de 3 a 1 solo aplica a VIOLATION, que por diseño ya es la categoría de menor riesgo de falso positivo del sistema completo (violaciones de límites físicos del motor, no heurísticas estadísticas).
- El nivel, la confianza, la severidad y el conteo de evidencia se muestran en el log (`[Risk] ... [VIOLATION risk=82 conf=0.95 sev=90 evid=1]`), en `sm_ac_view`, y en el menú in-game, para que un admin entienda **por qué** el sistema decidió lo que decidió, no solo el número final.

---

## Resumen de acción según Risk Score

| Risk Score | Acción |
|---|---|
| ≥15 (`SCORE_THRESHOLD_NOTE`) | Aviso a admins en Discord + chat |
| ≥35 (`SCORE_THRESHOLD_WARN`) | Advertencia visible en chat a todo el servidor |
| ≥50 (`SCORE_THRESHOLD_BAN`) **y** algún módulo individual ≥60 (`STRONG_MODULE_THRESHOLD`) | Expulsión (kick) automática, tras 3 confirmaciones consecutivas (~30s sostenidos) |

Los admins con el flag `sm_ac_immunity` (o ADMFLAG_GENERIC) son inmunes a la expulsión automática, pero igual generan una nota en Discord para que quede registro.

---

## Créditos de técnicas externas

Varias vías de detección están inspiradas o adaptadas de anti-cheats de código abierto de la comunidad SourceMod, investigados e integrados durante el desarrollo de este proyecto:

- **[StAC-tf2](https://github.com/sapphonie/StAC-tf2)** (Steph's Anti-Cheat, para TF2) — Angle Repeat, Cmdnum Spike, Fake Angles, Invalid Usercmd, honeypot de gravedad en bhop.
- **[SMAC](https://github.com/srcdslab/sm-plugin-SMAC)** (SourceMod Anti-Cheat) — filtro de distancia mínima, decaimiento temporal de evidencia, forward `OnCheatDetected`, chequeo `IsClientInKickQueue`.
- **[Lilac / Little-Anti-Cheat](https://github.com/J-Tanzanite/Little-Anti-Cheat)** — Aimlock (convergencia angular), NoLerp.
- **[OSAntiCheat](https://github.com/Pintuzoft/OSAntiCheat)** (CS2, estadístico) — módulo OSAC completo: Bone-lock, Silent Aim (trayectoria), TriggerBot, KillBurst, SpinBot.
- **[AntiBhopCheat](https://github.com/srcdslab/sm-plugin-AntiBhopCheat)** — módulo Bhop-2: hyperscroll (presiones por tick) y heurística compuesta de salto scripted.

Todas las implementaciones fueron reescritas desde cero para este proyecto, adaptadas específicamente a Left 4 Dead 2 (equipos, `m_zombieClass`, Infectados Especiales) y calibradas con datos reales de pruebas en este servidor.

---

## Módulos y técnicas agregados en esta ronda de mejoras

Antes de esta ronda, el sistema ya contaba con el diseño base de Aim (Vía 1 — Headshot Snap + Consistencia) y Bhop (Métricas 1 y 2 — ratio de saltos perfectos y racha máxima). Las siguientes 6 técnicas se investigaron e integraron después, tras revisar anti-cheats de código abierto de la comunidad (StAC-tf2 y Lilac/Little-Anti-Cheat):

1. **Cmdnum Spike** (Aim, Vía 3) — detecta el "disparo sin dispersión" cuando el cliente salta el contador de comandos en el tick de disparo. Técnica de StAC-tf2.
2. **Fake Angles** (módulo Integrity nuevo) — detecta ángulos de vista fuera de los límites físicos que el propio cliente aplica. Técnica de StAC-tf2.
3. **Invalid Usercmd** (módulo Integrity nuevo) — detecta comandos con campos negativos o bits de botones imposibles, señal de paquete manipulado a mano. Técnica de StAC-tf2.
4. **Honeypot de gravedad** (Bhop, Métrica 3) — altera la gravedad del jugador tras una racha sospechosa de bhops perfectos; sobrevivirla es evidencia casi irrefutable. Técnica de StAC-tf2.
5. **Aimlock** (Aim, Vía 4) — mide la convergencia angular sostenida hacia un objetivo, sin depender de que llegue a disparar. Técnica de Lilac / Little-Anti-Cheat.
6. **NoLerp** (módulo nuevo completo) — consulta la interpolación configurada del cliente contra el mínimo físicamente posible. Técnica de Lilac / Little-Anti-Cheat.

### Segunda ronda — OSAntiCheat + AntiBhopCheat

Tras revisar dos anti-cheats más (OSAntiCheat, un sistema estadístico de CS2, y AntiBhopCheat), se agregaron:

7. **Módulo OSAC completo** (`anticheat_osac.sp`) — 5 detectores de estilo "logic breach" reimplementados de OSAntiCheat: **Bone-lock** (impacto ≤0.05° del centro de la cabeza), **Silent Aim por trayectoria** (daño con la mira a ≥10° de la víctima), **TriggerBot** (disparo <90ms tras cruzar el objetivo), **KillBurst** (≥4 headshots letales a Especiales en 15s), **SpinBot** (giro yaw ≥1000°/s sostenido).
8. **Módulo Bhop-2** (`anticheat_bhop2.sp`) — segundo detector de bhop independiente, algoritmo de AntiBhopCheat: **hyperscroll** (≥0.85 presiones de `+jump` por tick) y **heurística compuesta** (gap ≤1 tick + pocas presiones + velocidad ≥285). Se combina con el módulo Bhop tomando el máximo.

Con esto, el sistema quedó en **5 módulos con 16 técnicas combinadas** (Aim ×4, Bhop ×3, Bhop-2 ×2, Integrity ×2, NoLerp ×1, OSAC ×5), más el módulo Bhop-2 que corrobora a Bhop sin peso propio.

Después se agregó la Métrica 4 de Bhop (cadena perfecta sin air-strafing) y las 5 vías del módulo OSAC quedaron distribuidas — total actual: **17 técnicas**.

---

## Rendimiento — detección escalonada por nivel de vigilancia

Para que un jugador limpio no pague el costo de los chequeos pesados, el sistema usa **niveles de vigilancia (0-3)** por jugador. Los chequeos baratos siempre corren cada tick; los caros (los que necesitan buscar el Infectado Especial más cercano cada tick: **Aimlock** y **TriggerBot**) solo se activan cuando el jugador ya generó evidencia con los baratos.

| Nivel | Se alcanza con | Qué corre |
|---|---|---|
| **0 — normal** (todos empiezan aquí) | — | Solo chequeos baratos: Angle Repeat, Cmdnum Spike, Headshot Snap, Integrity, Bhop, Bhop-2, SpinBot, Bone-lock, Silent Aim, KillBurst. **Cero búsquedas de objetivo por tick.** |
| **1 — observado** | Risk ≥15 o cualquier módulo ≥15 | + Aimlock y TriggerBot, muestreados 1 de cada 4 ticks |
| **2 — sospechoso** | Risk ≥30 o algún módulo ≥40 | Aimlock y TriggerBot 1 de cada 2 ticks |
| **3 — alta sospecha** | Risk ≥50 o algún módulo ≥60 | Aimlock y TriggerBot cada tick + evaluación de riesgo cada 5s en vez de 10s (llega antes al umbral de kick) |

El nivel **sube inmediatamente** cuando aparece evidencia y **baja despacio**: un nivel por cada 120 segundos sin evidencia nueva. Un jugador que hace trampa un rato y luego para vuelve a nivel 0 tras ~6 minutos.

Otras optimizaciones aplicadas:
- **Caché compartida de Infectados Especiales**: la lista de Especiales vivos se construye una sola vez por frame del juego, no una vez por cada detector por cada jugador.
- **Salida temprana**: si no hay ningún Infectado Especial vivo, los chequeos de objetivo ni siquiera arrancan.
- **Grabación de demos eliminada**: el sistema de evidencia en video (`record`/`stop` cada 2 minutos) causaba un tirón periódico y se quitó. Las alertas de Discord siguen llegando completas, sin el video adjunto.
- **Log silenciado en Risk bajo**: `Timer_Score` sigue evaluando a todos los jugadores cada 5-10s como siempre (necesario para que el nivel de vigilancia suba/baje correctamente), pero la línea `[Risk] ... => Risk N` solo se escribe en el log y la consola cuando `Risk >= 15` (`SCORE_THRESHOLD_NOTE`). Antes se escribía siempre, incluso en Risk 0, generando una línea por jugador cada 5-10 segundos sin ninguna utilidad — el log ahora solo contiene evaluaciones donde algún módulo ya produjo evidencia real.
