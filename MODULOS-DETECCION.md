# Módulos de detección — AntiCheat L4D2

Este documento explica **qué hace cada módulo de detección**, cómo funciona técnicamente, y qué tipo de trampa detecta. El sistema combina 6 módulos con peso propio en un único **Risk Score (0-100)** evaluado cada 10 segundos por jugador.

```
Risk = (Aim×40% + Bhop×21% + Integrity×11% + NoLerp×10% + OSAC×14% + Macro×4%) × Multiplicador de Correlación
```

(Los módulos Bhop-2, Target Acquisition, Variance Profiling, Shot Decision, Aim Drift y Tracking no tienen peso propio: cada uno se combina tomando el máximo con el módulo Aim o Bhop al que pertenece conceptualmente. Speedhack y Noclip se combinan con Integrity de la misma forma.)

**Nota:** el módulo de WallHack fue removido del proyecto deliberadamente y no forma parte del sistema actual — todo lo documentado aquí abajo es detección de comportamiento de puntería, movimiento, disparo o integridad de paquetes, nunca de visión a través de geometría.

Cada módulo produce su propia puntuación 0-100 de forma totalmente independiente — ninguno depende de los demás para funcionar. Esto es deliberado: un cheat puede evadir un módulo pero rara vez evade los 6 a la vez, y cuando **un solo módulo** llega a 60/100 por sí solo (`STRONG_MODULE_THRESHOLD`), eso ya es evidencia suficiente para expulsar al jugador aunque el Risk total combinado no llegue al umbral. **Este gate usa siempre el score individual de cada módulo, nunca el Risk ya multiplicado por correlación** — la correlación acelera qué tan rápido se junta evidencia ya confirmada, pero nunca sustituye la necesidad de que algún módulo confirme su propia evidencia primero.

Archivo fuente de cada módulo entre paréntesis.

---

## 1. Aim (`anticheat_aim.sp`) — peso 40%

El módulo más grande. Por decisión deliberada del proyecto, **el score final de Aim (`Aim_GetScore`) solo se calcula a partir de patrones sobre el disparo/la bala en sí** — no sobre movimiento genérico de mira. Es el **máximo** de 5 vías activas. Además se combina (también por máximo) con Target Acquisition, Variance Profiling, Shot Decision, Aim Drift y Tracking, descritos más abajo.

Cinco vías más antiguas (Headshot Snap+Consistencia, Angle Repeat, Cmdnum Spike, Aimlock, No-Recoil) **siguen ejecutándose y siguen reportando al motor de correlación cruzada**, pero ya no contribuyen directamente al score de este módulo — quedan documentadas al final de esta sección.

Filtro común a todas las vías activas: solo se evalúan disparos/ángulos contra **Infectados Especiales** (Smoker, Hunter, Boomer, Tank, etc. — no Comunes) y a una distancia mínima de 200 unidades, para no confundir el combate cuerpo a cuerpo legítimo (caótico por naturaleza) con evidencia de trampa.

### Vía 1 — Headshot Ratio
**Qué detecta:** de todos los disparos que un jugador impacta sobre un Infectado Especial (cabeza o cuerpo), qué fracción son headshot.

**Por qué funciona:** incluso un jugador muy bueno mezcla impactos de cuerpo/extremidades a lo largo de una muestra real — retroceso, movimiento, pánico. Un ratio pegado cerca del 100% sostenido en muchos disparos es la firma de un aimbot corrigiendo cada tiro a la cabeza sin importar dónde apuntaba realmente el crosshair.

**Umbral:** ≥8 disparos calificados, ratio de headshot ≥95% sostenido.

### Vía 2 — Psilent (técnica de StAC-tf2)
**Qué detecta:** la mira salta al objetivo por exactamente **un tick** y regresa casi exactamente al ángulo anterior, en el mismo tick en que se dispara.

**Por qué funciona:** es la firma de un cheat de silent-aim que "engancha" el disparo al blanco por un instante para que el motor registre el hit, y revierte la mira visible inmediatamente después para que el jugador no vea el salto. Se mide comparando 3 ticks consecutivos: si el más antiguo y el más nuevo coinciden casi exactamente (≤0.1°) mientras el del medio saltó ≥5° y coincide con el tick del disparo, es evidencia casi irrefutable — un humano no puede restaurar el ángulo exacto anterior tras una corrección real.

**Umbral:** ≥1 evento confirmado ya cuenta como evidencia fuerte (severidad base 60, sube con cada repetición).

### Vía 3 — Autoshoot (técnica de Little-Anti-Cheat)
**Qué detecta:** el botón de disparo (`IN_ATTACK`) se mantiene presionado por **1 tick o menos** antes de soltarse.

**Por qué funciona:** un clic físico real de mouse nunca dura solo un tick de servidor — incluso el clic más rápido humano se sostiene 2-3+ ticks. Un disparo generado programáticamente (sin un dedo real presionando el botón) puede pulsar el botón exactamente un tick.

**Umbral:** ≥3 eventos recientes (un solo caso puede ser un tap genuinamente rápido o un artefacto de red).

### Vía 4 — FOV Lock
**Qué detecta:** la mira reacciona (salta) hacia un objetivo siempre al mismo "radio de entrada" angular, sin importar la dirección desde la que apareció el objetivo.

**Por qué funciona:** muchos aimbots públicos (investigado directamente en el código fuente de un aimbot real de SourceMod) usan un cono de FOV circular fijo alrededor del crosshair — en cuanto un objetivo entra en ese radio, la mira se ajusta, sin importar si vino de arriba, abajo, izquierda o derecha. Un humano reacciona a distancias angulares muy variables según cuándo notó al objetivo; un radio de entrada con desviación estándar muy baja a través de muchos encuentros independientes es la firma de ese cono fijo.

**Umbral:** ≥6 snaps confirmados con desviación estándar del radio de entrada <2.5°.

### Vía 5 — No-Spread
**Qué detecta:** a lo largo de muchos disparos individuales (no ráfagas) a distancia real, el error angular entre la vista y el punto de impacto se mantiene sospechosamente ajustado.

**Por qué funciona:** reconstruir el RNG exacto del motor Source para predecir el spread disparo-por-disparo no es viable en SourcePawn puro, así que esto mide la huella estadística en su lugar. Toda arma hitscan tiene dispersión/inexactitud real que crece con movimiento y disparo sostenido; un cheat de no-spread (investigado en el código fuente real de un cheat público) cancela esa dispersión antes de que el disparo salga del cliente, así que el impacto cae casi exactamente sobre la línea apuntada casi siempre — la dispersión que debería haber simplemente no está.

**Umbral:** ≥10 disparos individuales (con al menos 0.3s entre cada uno) a ≥300 unidades, ≥85% de ellos con error ≤1.2°.

### Vías retiradas del score de Aim (siguen alimentando correlación)

Estas 5 vías fueron el diseño original del módulo, pero por decisión del proyecto ya no contribuyen a `Aim_GetScore` — el módulo pasó a enfocarse exclusivamente en el patrón de disparo/bala. Siguen ejecutándose y reportando eventos al motor de correlación cruzada, por si coinciden en el tiempo con otro detector.

- **Headshot Snap + Consistencia** — salto angular justo antes de un headshot, evaluado por consistencia entre disparos (desviación estándar del tamaño del salto).
- **Angle Repeat** (técnica de StAC-tf2) — salto angular aislado flanqueado de quietud casi total, mientras se dispara.
- **Cmdnum Spike** (técnica de StAC-tf2) — el `cmdnum` del cliente saltando varios valores de golpe en el tick de disparo.
- **Aimlock** (técnica de Lilac / Little-Anti-Cheat) — convergencia angular sostenida hacia un objetivo a lo largo de varios ticks, sin necesidad de disparo.
- **No-Recoil** — durante una ráfaga sostenida de disparo, el pitch de la vista se mantiene prácticamente plano (sin el salto vertical de retroceso esperado) en ≥85% de los ticks de una ráfaga de ≥18 ticks (~0.6s).

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

## 1d. Shot Decision Analysis (`anticheat_shotdecision.sp`) — se combina con Aim (máximo)

Target Acquisition mide cuánto tarda la adquisición. TriggerBot (dentro de OSAC) mide el instante del cruce al disparo. Ninguno de los dos correlaciona ese tiempo contra el **contexto** del disparo — qué arma se sostenía, a qué distancia estaba el objetivo. Este módulo cierra ese hueco: toma el tiempo de adquisición que Target Acquisition ya midió para la sesión que terminó en un disparo, y lo combina con el arma y la distancia de ese disparo específico.

### Por qué el contexto importa

El tiempo de decisión de un humano **no es un número fijo** — depende del arma (una ráfaga con SMG se decide distinto que alinear un solo disparo de rifle de precisión) y de la distancia (un objetivo cercano es más urgente pero más fácil de acertar; uno lejano exige más cuidado). Un script de enganche-y-disparo típicamente no modela nada de esto: converge y dispara con un ritmo similar sin importar qué arma tiene equipada o qué tan lejos está el objetivo.

### Cómo funciona

Cada disparo calificado (con una sesión de adquisición real detrás, no una suposición) se clasifica en un "bucket" según **clase de arma** (precisión: rifle de caza, francotirador, Desert Eagle, Magnum — vs. rápida: todo lo demás) y **banda de distancia** (cerca <300u, media, lejos ≥700u) — 6 combinaciones posibles. Con al menos 2 buckets distintos poblados (≥4 disparos cada uno), se compara el **tiempo de decisión promedio entre buckets**.

Se mide con coeficiente de variación de las medias de los buckets respecto al promedio general — un humano normalmente cambia su timing en más de 20-30% entre un disparo rápido de cerca y uno de precisión lejano. Que el timing se mantenga sospechosamente plano a través de contextos que deberían producir comportamiento distinto es la señal: un script "ciego al contexto".

**Umbral:** ≥2 buckets con ≥4 disparos cada uno. Coeficiente de variación entre buckets por debajo de 0.20 para empezar a puntuar.

**Rendimiento:** no agrega ningún costo por tick — solo se evalúa en el momento del disparo (`Hook_TraceAttack`, ya se ejecuta para cada impacto) y reutiliza el tiempo que Target Acquisition ya calculó.

---

## 1e. Aim Drift (`anticheat_aimdrift.sp`) — se combina con Aim (máximo)

(Técnica adaptada de [OSAntiCheat](https://github.com/Pintuzoft/OSAntiCheat), su detector `AimDriftDetector` en CS2.)

A diferencia de todos los demás módulos de Aim, este no compara contra un umbral fijo ni contra el propio historial del jugador — compara al jugador contra **el resto del lobby, en vivo**, usando un test estadístico real (z-test de dos proporciones, el mismo tipo que se usa para preguntar "¿esta moneda es realmente más justa que aquella?" comparando dos muestras).

### Cómo funciona

Mientras la mira de un jugador está "enganchada" (dentro de 15° del Infectado Especial más cercano), cada tick es un **"paso"**: o bien redujo el error angular restante respecto al tick anterior, o no lo hizo. Se acumula, por jugador, cuántos pasos dio (`N`) y cuántos de ellos redujeron el error (`B`) — y en paralelo se acumula el mismo conteo agregado de **todos los demás jugadores del servidor combinados**, como línea base ("el resto del lobby").

Con al menos 500 pasos propios del jugador y 3.000 pasos acumulados del resto del lobby, se calcula:

```
p1 = B_jugador / N_jugador          (tasa de éxito del sospechoso)
p0 = B_resto / N_resto              (tasa de éxito del resto del lobby)
z  = (p1 - p0) / error_estándar_combinado
```

Si `z ≥ 3.0` (justo por encima del techo de 2.79 medido en la implementación original contra un corpus honesto real), se marca como evidencia. El umbral no es un número fijo: al comparar contra el mismo servidor, mismo mapa, mismo momento, se cancelan automáticamente factores de confusión como la geometría del mapa o "esta horda en particular es fácil de rastrear" — la línea base viene exactamente de las mismas condiciones.

**Umbral:** ≥500 pasos propios, ≥3.000 pasos del resto del lobby, z-score ≥3.0.

**Alcance:** la línea base se reinicia en cada cambio de mapa (`OnMapStart`), porque mezclar muestras de mapas con geometría distinta sesgaría lo que cuenta como "normal". Con muy pocos jugadores conectados el detector se abstiene por completo hasta juntar suficiente muestra del resto del lobby — es intencional, evita comparar contra una línea base poco confiable.

---

## 1f. Tracking Kinematics (`anticheat_tracking.sp`) — se combina con Aim (máximo)

(Fundamentado en investigación de control motor humano — teoría de trayectoria de jerk mínimo — y en cómo FACEIT describe públicamente su sistema Human Input Detection: juzgar *cómo* apunta un jugador, no solo umbrales fijos.)

Ningún otro módulo mide la **forma** cinemática completa de una trayectoria de seguimiento sostenido — Aimlock mide una sola transición, Target Acquisition mide tiempo y monotonicidad de la sesión completa. Este módulo mide tres propiedades de la *forma* del recorrido angular, basadas en cómo se mueve realmente un brazo humano.

### Cómo funciona

Se abre una "sesión de tracking" (mismo concepto que Target Acquisition, pero un módulo independiente) mientras el jugador sigue al mismo Infectado Especial. Al cerrar la sesión (llegó a estar sobre el objetivo), se calculan tres métricas de forma:

1. **Straightness (rectitud)** — distancia angular directa ÷ longitud real del trayecto recorrido. La mano humana divaga y se corrige; un script que converge por el camino más corto empuja este valor hacia 1.0.
2. **Critical Points (puntos críticos)** — cuántas veces cambia de signo la velocidad de cierre del error durante la sesión. Un alcance humano real se descompone en un movimiento principal más 1-3 sub-correcciones (2-4 puntos críticos); un script que calcula una sola convergencia limpia produce exactamente 1.
3. **Velocity Asymmetry (asimetría de velocidad)** — en qué punto de la sesión (como fracción del total de ticks) ocurrió el tick de cierre de error más rápido. Un alcance humano acelera rápido al inicio y desacelera de forma más gradual hacia el final (curva asimétrica, pico temprano); un seguimiento sintético tiende a converger de forma más simétrica (pico cerca de la mitad).

**Importante — exige acuerdo entre métricas:** se requiere que **al menos 2 de las 3 métricas** caigan en la zona sospechosa al mismo tiempo antes de confiar en un score alto; si solo una lo hace, el score se reduce a la mitad. Cada métrica por separado tiene su propia tasa de falso positivo en la población legítima, pero que coincidan de forma independiente es una evidencia mucho más fuerte.

**Umbral:** ≥6 sesiones cerradas y alcanzadas. Straightness promedio ≥0.92, o critical points promedio ≤1, o pico de velocidad entre el 42%-58% de la sesión (demasiado simétrico) — con al menos 2 de los 3 cumpliéndose a la vez para el score completo.

**Rendimiento:** igual que Target Acquisition/Variance/Aim Drift, solo corre en nivel de vigilancia ≥1.

---

## 2. Bhop (`anticheat_bhop.sp`) — peso 21%

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

### Métrica 5 — Static Turn Rate (técnica de Oryx-AC)
**Qué detecta:** durante el vuelo aéreo, el jugador gira la mira por exactamente el ángulo matemáticamente óptimo para maximizar la ganancia de velocidad (`asin(30/velocidad)`, derivado de la fórmula de aceleración aérea del motor Source), tick tras tick, de forma sostenida.

**Por qué funciona:** un humano que persigue la velocidad máxima de bhop se *acerca* a ese óptimo por sensación, pero nunca lo clava turno tras turno — su delta real tiene ruido natural. Un script de air-strafe automático calcula el mismo ángulo óptimo cada tick y gira exactamente eso, así que su delta se queda "pegado" al óptimo con una tolerancia mínima (0.35°) de forma sostenida.

**Umbral:** velocidad entre 100-2560 u/s, ≥10 ticks consecutivos dentro de tolerancia del óptimo.

### Métrica 6 — Strafe-Key Sync / "BASH" (técnica de Oryx-AC)
**Qué detecta:** cuántos ticks pasan entre que una tecla de strafe (A/D) cambia de estado y que la vista realmente gira en la dirección correspondiente.

**Por qué funciona:** la mano de un humano tiene latencia real y variable entre presionar la tecla y que el giro del mouse la siga — nunca es el mismo tick exacto cada vez. Un script de silent-strafe/auto-sync gira la vista en el mismo tick exacto en que cambia el estado de la tecla, cada vez, porque ambos están controlados por el mismo código.

**Umbral:** ≥18 transiciones de tecla judgeadas, ≥80% de ellas con sincronización perfecta (gap de 0 ticks).

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

Cuatro chequeos de **integridad del paquete/estado**, no de comportamiento — verifican si lo que el cliente reporta es siquiera físicamente/estructuralmente posible de producir por un cliente legítimo. Casi cero falsos positivos por construcción, así que pesan fuerte en cuanto se disparan. El score del módulo es el máximo de los cuatro sub-chequeos.

### Fake Angles (técnica de StAC-tf2)
**Qué detecta:** ángulo de pitch fuera de ±89° o de roll fuera de ±50°.

**Por qué funciona:** son límites físicos que el propio código de entrada del cliente aplica antes de construir el comando — un cliente real jamás puede enviar ángulos fuera de ese rango. Algunos cheats rudimentarios (herramientas de ESP/aim antiguas que tocan los ángulos de vista directamente) se saltan ese límite.

**Umbral:** ≥3 eventos.

### Invalid Usercmd (técnica de StAC-tf2)
**Qué detecta:** `cmdnum` o `tickcount` negativos, o el bitmask de botones usando bits que el juego nunca activa (≥ bit 26, ya que `IN_ATTACK3` es la bandera real más alta en 1<<25).

**Por qué funciona:** indica un comando hecho a mano o corrupto, no uno que produjo el cliente real — otra capa de detección totalmente distinta a analizar comportamiento, ataca directamente la manipulación del paquete.

**Umbral:** ≥3 eventos.

### Speedhack (técnica de SMAC)
**Qué detecta:** el cliente enviando más comandos por segundo de los que el tiempo real de servidor permite — manipulación de timescale o inyección de comandos.

**Por qué funciona:** un sistema de "crédito de ticks": el tiempo real transcurrido en el servidor recarga un balance de crédito a la tasa exacta del tickrate (más un pequeño margen de jitter), y cada `usercmd` procesado gasta un crédito. Un cliente legítimo nunca puede mandar más comandos de los que el tickrate permite — eso es literalmente lo que define el tickrate. Un cheat de timescale hace que el balance se agote de forma sostenida. Se exige además latencia estable entre chequeos, para no confundir un pico de ping (que legítimamente puede liberar una ráfaga de comandos acumulados) con manipulación real.

**Umbral:** balance negativo durante ≥30 chequeos consecutivos (cada uno cada 0.1s) con latencia estable (variación ≤5ms).

### Noclip
**Qué detecta:** la posición del jugador cruza geometría sólida entre un tick y el siguiente.

**Por qué funciona:** se traza un rayo en línea recta entre la posición del tick anterior y la actual contra `MASK_PLAYERSOLID`. La propia resolución de colisiones del motor nunca permite que un cliente legítimo produzca un trayecto que atraviese un sólido — si el rayo impacta algo en el medio, es estructuralmente imposible. Se excluye movimiento por encima de 900 u/s (empujones de Charger, lanzamientos de Hunter, etc., que producen saltos legítimos de posición grandes) para no confundir esos casos con noclip real.

**Umbral:** 1 trayecto confirmado atravesando geometría sólida ya es evidencia (`STRONG_MODULE_THRESHOLD`-level por construcción).

---

## 4. NoLerp (`anticheat_nolerp.sp`) — peso 10%

**Qué detecta:** el cliente configurando su interpolación (`cl_interp`) por debajo del mínimo físicamente posible dado su `cl_interp_ratio` y `cl_updaterate`.

**Por qué funciona:** algunos cheats bajan la interpolación del cliente a 0ms (o menos del mínimo real) para quitarle el "colchón" de suavizado a la posición percibida de los objetivos — esto hace que los aimbots de snap/flick sean notablemente más precisos, porque reaccionan a la posición más reciente sin demora. A diferencia de todos los demás módulos, este **no analiza comportamiento tick a tick** — simplemente le pregunta al cliente su configuración cada 5 segundos vía `QueryClientConVar` y la compara contra el mínimo calculado (`cl_interp_ratio / cl_updaterate`, con 5% de margen para redondeo). Por eso es casi cero falsos positivos: es solo lectura de configuración, no un patrón estadístico.

**Umbral:** interp reportado <95% del mínimo físico calculado, se necesitan ≥3 confirmaciones (para que un glitch de consulta puntual no dispare el módulo solo).

---

## 5. OSAC (`anticheat_osac.sp`) — peso 14%

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

## 6. Macro (`anticheat_macro.sp`) — peso 4%

A diferencia de todos los demás módulos, este **no mira aim ni movimiento en absoluto**. Detecta macros/scripts genéricos automatizando cualquier tecla de acción del juego — curar, dar pastillas, empujar, recargar — sin que el jugador esté intentando hacer aimbot ni bhop.

### Cómo funciona

Rastrea la duración de pulsación (en ticks) de tres botones de acción sin relación con puntería: `IN_USE` (curar/interactuar), `IN_RELOAD`, `IN_ATTACK2` (empujón). Para cada botón, guarda un historial de las últimas 20 duraciones de pulsación y busca la duración más frecuente (la moda). Si una fracción muy alta de las pulsaciones recientes coincide casi exactamente con esa moda, es la firma de un macro: la mano humana varía cuánto sostiene una tecla de una pulsación a otra (reacción, intención, cansancio); un macro de teclado (AHK, script, mouse/teclado con macros) reproduce la misma duración exacta una y otra vez porque está temporizado por código, no por un impulso nervioso.

**Umbral:** ≥12 pulsaciones calificadas (≥2 ticks de duración) por botón, ≥85% de ellas coincidiendo con la duración modal.

**Por qué pesa menos que los demás:** a diferencia de los chequeos "logic breach" (estructuralmente imposibles), un agrupamiento de duración muy ajustado es una señal estadística real pero más suave — por eso Macro tiene un peso pequeño y deliberado (4%) en el Risk Score, contribuye pero nunca lo domina por sí solo.

---

## Motor de correlación entre detectores (`anticheat_correlation.sp`)

Los scores de los módulos con peso propio solo se *sumaban* con pesos fijos — un módulo mostrando sospecha leve y tres módulos independientes disparando en el mismo instante producían el mismo tipo de resultado, solo con distinta magnitud. El motor de correlación agrega una capa encima de eso, **sin tocar la lógica interna de ningún detector existente**.

### Cómo funciona

**30 sub-detectores distintos** (todas las vías descritas en este documento, incluyendo las que ya no contribuyen directamente al score de su módulo padre) reportan al motor de correlación el instante exacto en que registran un evento crudo — el mismo momento en que ya escribían en su propio historial interno, sin cambiar cuándo ni por qué disparan. Cada reporte lleva: qué detector fue, cuándo, y qué tan severo fue ese evento puntual (0-100).

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
- **Severity** (0-100) — el peor score individual de los módulos con peso propio (Aim, Bhop, Integrity, NoLerp, OSAC), **sin** el multiplicador de correlación — mide qué tan grave es la peor pieza de evidencia por sí sola.
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
| ≥15 (`SCORE_THRESHOLD_NOTE`) | Solo se registra en el log del servidor (no hay chat ni Discord) |
| ≥35 (`SCORE_THRESHOLD_WARN`) | Solo se registra en el log del servidor (no hay chat ni Discord) |
| ≥50 (`SCORE_THRESHOLD_BAN`) **y** algún módulo individual ≥60 (`STRONG_MODULE_THRESHOLD`) | Expulsión (kick) automática, tras 1 confirmación (si la evidencia es de nivel VIOLATION) o 3 confirmaciones consecutivas (~20-30s sostenidos) en cualquier otro caso |

**Nota:** las notificaciones automáticas de "jugador sospechoso" (chat in-game y Discord) fueron removidas deliberadamente por decisión del proyecto — la única alerta visible ahora es justo antes del kick real, para no saturar el canal con avisos de comportamiento que todavía no cruzó el umbral de expulsión. Un admin puede seguir consultando el riesgo de cualquier jugador en cualquier momento con `sm_ac_view <jugador>` o el menú in-game.

Los admins con el flag `sm_ac_immunity` (o ADMFLAG_GENERIC) son inmunes a la expulsión automática, pero igual generan una nota en el log para que quede registro.

---

## Créditos de técnicas externas

Varias vías de detección están inspiradas o adaptadas de anti-cheats de código abierto de la comunidad, de investigación académica, o de la observación directa de cheats/aimbots reales, investigados e integrados durante el desarrollo de este proyecto:

- **[StAC-tf2](https://github.com/sapphonie/StAC-tf2)** (Steph's Anti-Cheat, para TF2) — Angle Repeat, Cmdnum Spike, Fake Angles, Invalid Usercmd, honeypot de gravedad en bhop, Psilent (snap-and-back de 1 tick).
- **[SMAC](https://github.com/srcdslab/sm-plugin-SMAC)** (SourceMod Anti-Cheat) — filtro de distancia mínima, decaimiento temporal de evidencia, forward `OnCheatDetected`, chequeo `IsClientInKickQueue`, sistema de crédito de ticks para Speedhack.
- **[Lilac / Little-Anti-Cheat](https://github.com/J-Tanzanite/Little-Anti-Cheat)** — Aimlock (convergencia angular), NoLerp, Autoshoot (duración de clic).
- **[OSAntiCheat](https://github.com/Pintuzoft/OSAntiCheat)** (CS2, estadístico) — módulo OSAC completo: Bone-lock, Silent Aim (trayectoria), TriggerBot, KillBurst, SpinBot; además Aim Drift (z-test de dos proporciones contra la línea base del lobby en vivo).
- **[AntiBhopCheat](https://github.com/srcdslab/sm-plugin-AntiBhopCheat)** — módulo Bhop-2: hyperscroll (presiones por tick) y heurística compuesta de salto scripted.
- **[Oryx-AC](https://github.com/shavitush/Oryx-AC)** — Static Turn Rate (ángulo óptimo de air-strafe) y Strafe-Key Sync/BASH (correlación tecla-a-giro) en Bhop.
- **[Franc1sco/aimbot](https://github.com/Franc1sco/aimbot)** (implementación de referencia de un aimbot real de SourceMod) — diseño de FOV Lock, inspirado directamente en cómo ese aimbot implementa su propio cono de FOV circular.
- **[SimpleRealistic/styles-cheat-csgo-source](https://github.com/SimpleRealistic/styles-cheat-csgo-source)** (cheat real de CS:GO, módulo `NoSpread.cpp`) — diseño de No-Spread, inspirado en cómo ese cheat cancela el spread del motor antes del disparo.
- **Investigación en control motor humano** (teoría de trayectoria de jerk mínimo, biometría de movimiento de mouse) y **FACEIT Human Input Detection** (metodología pública de juzgar comportamiento sobre umbrales fijos) — fundamento de Tracking Kinematics.

Todas las implementaciones fueron reescritas desde cero para este proyecto, adaptadas específicamente a Left 4 Dead 2 (equipos, `m_zombieClass`, Infectados Especiales) y calibradas con datos reales de pruebas en este servidor.

---

## Historial de mejoras

El sistema creció por rondas sucesivas de investigación de anti-cheats de código abierto, papers académicos, y cheats reales. Resumen cronológico (de más antiguo a más reciente):

1. **Diseño base** — Aim (Headshot Snap + Consistencia) y Bhop (ratio de saltos perfectos, racha máxima).
2. **Ronda StAC-tf2 / Lilac** — Cmdnum Spike, Fake Angles, Invalid Usercmd (módulo Integrity nuevo), honeypot de gravedad en Bhop, Aimlock, NoLerp (módulo nuevo).
3. **Ronda OSAntiCheat / AntiBhopCheat** — módulo OSAC completo (Bone-lock, Silent Aim, TriggerBot, KillBurst, SpinBot), módulo Bhop-2 (hyperscroll + heurística compuesta).
4. **Métrica 4 de Bhop** — cadena de bhop perfecto sin air-strafing real.
5. **Remoción de WallHack** — el módulo de WallHack fue removido completamente del proyecto por decisión explícita; el sistema no detecta visión a través de geometría.
6. **Reenfoque de Aim a "solo balas"** — por pedido explícito del proyecto, el score de Aim se limitó a patrones sobre el disparo/la bala en sí. Se agregaron Headshot Ratio, Psilent, Autoshoot, FOV Lock. Las vías originales (Snap, Angle Repeat, Cmdnum Spike, Aimlock, No-Recoil) pasaron a alimentar solo el motor de correlación.
7. **Ronda "balas agresivas"** — investigación en GitHub de StAC-tf2 y Little-Anti-Cheat: No-Recoil (retroceso suprimido), y refuerzo del alcance de Psilent/Autoshoot ya mencionados arriba.
8. **Ronda Oryx-AC / cheats reales** — Static Turn Rate y Strafe-Key Sync en Bhop (Oryx-AC); No-Spread en Aim, inspirado en un cheat real de CS:GO.
9. **Ronda "categorías nuevas"** — Speedhack y Noclip (módulo Integrity, técnica de SMAC y trazado de colisión estándar), y el módulo Macro completamente nuevo (detección genérica de teclas con timing de script, sin relación con aim/movimiento).
10. **Ronda anti-cheats famosos** — Aim Drift (z-test de dos proporciones contra la línea base del lobby en vivo, técnica de OSAntiCheat/CS2) y el módulo Tracking Kinematics completo (straightness, critical points, velocity asymmetry — fundamentado en investigación de control motor humano y en cómo FACEIT describe su Human Input Detection).

**Total actual: 6 módulos con peso propio (Aim, Bhop, Integrity, NoLerp, OSAC, Macro) + 7 módulos que se combinan por máximo con alguno de los anteriores (Target Acquisition, Variance×2, Shot Decision, Aim Drift, Tracking, Bhop-2) = 30 sub-detectores individuales reportando al motor de correlación.**

---

## Rendimiento — detección escalonada por nivel de vigilancia

Para que un jugador limpio no pague el costo de los chequeos pesados, el sistema usa **niveles de vigilancia (0-3)** por jugador. Los chequeos baratos siempre corren cada tick; los caros (los que necesitan buscar el Infectado Especial más cercano cada tick: **Aimlock**, **TriggerBot**, **Target Acquisition**, **Variance (aim)**, **Aim Drift** y **Tracking**) solo se activan cuando el jugador ya generó evidencia con los baratos.

| Nivel | Se alcanza con | Qué corre |
|---|---|---|
| **0 — normal** (todos empiezan aquí) | — | Solo chequeos baratos: Angle Repeat, Cmdnum Spike, Headshot Snap, No-Recoil, Psilent, Autoshoot, Headshot Ratio, No-Spread, Integrity (incluye Speedhack, Noclip), Macro, Bhop (incluye Static Turn Rate, Strafe-Key Sync), Bhop-2, SpinBot, Bone-lock, Silent Aim, KillBurst. **Cero búsquedas de objetivo por tick.** |
| **1 — observado** | Risk ≥15 o cualquier módulo ≥15 | + Aimlock, FOV Lock y TriggerBot, muestreados 1 de cada 4 ticks; + Target Acquisition, Variance (aim), Aim Drift, Tracking, cada tick sin throttle |
| **2 — sospechoso** | Risk ≥30 o algún módulo ≥40 | Aimlock y TriggerBot 1 de cada 2 ticks |
| **3 — alta sospecha** | Risk ≥50 o algún módulo ≥60 | Aimlock y TriggerBot cada tick + evaluación de riesgo cada 5s en vez de 10s (llega antes al umbral de kick) |

El nivel **sube inmediatamente** cuando aparece evidencia y **baja despacio**: un nivel por cada 120 segundos sin evidencia nueva. Un jugador que hace trampa un rato y luego para vuelve a nivel 0 tras ~6 minutos.

Otras optimizaciones aplicadas:
- **Caché compartida de Infectados Especiales**: la lista de Especiales vivos se construye una sola vez por frame del juego, no una vez por cada detector por cada jugador.
- **Salida temprana**: si no hay ningún Infectado Especial vivo, los chequeos de objetivo ni siquiera arrancan.
- **Grabación de demos eliminada**: el sistema de evidencia en video (`record`/`stop` cada 2 minutos) causaba un tirón periódico y se quitó. Las alertas de Discord siguen llegando completas, sin el video adjunto.
- **Log silenciado en Risk bajo**: `Timer_Score` sigue evaluando a todos los jugadores cada 5-10s como siempre (necesario para que el nivel de vigilancia suba/baje correctamente), pero la línea `[Risk] ... => Risk N` solo se escribe en el log y la consola cuando `Risk >= 15` (`SCORE_THRESHOLD_NOTE`). Antes se escribía siempre, incluso en Risk 0, generando una línea por jugador cada 5-10 segundos sin ninguna utilidad — el log ahora solo contiene evaluaciones donde algún módulo ya produjo evidencia real.
