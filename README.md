# vthreads-bench

Тестовый стенд для сравнения трёх моделей конкурентности на I/O-bound нагрузке:
платформенные потоки, виртуальные потоки (Java 21+), реактивный подход (Spring WebFlux).

## Устройство

```
k6 ──► приложение (:8080) ──► backend (:8081, отвечает через ms миллисекунд)
```

| Модуль | Что это |
|---|---|
| `backend` | Имитация медленной БД/API: `GET /slow?ms=100`. Реактивный, сам не является узким местом |
| `app-mvc` | Spring MVC + Tomcat + блокирующий `RestClient`. Профили: `platform` и `virtual` |
| `app-webflux` | Тот же сценарий на WebFlux + `WebClient` |

Платформенный и виртуальный варианты - это **один и тот же код**, отличается только конфигурация.

Эндпоинт под нагрузкой: `GET /work?ms=100&calls=1` (calls последовательных обращений к backend по ms мс).
Вспомогательный: `GET /whoami` показывает тип потока, обрабатывающего запрос.

## Сборка

Нужны JDK 21+ и Maven.

```
mvn -q package -DskipTests
```

## Запуск (каждый вариант отдельно, порт 8080 один и тот же)

```
java -jar backend/target/backend-1.0.0.jar

java -jar app-mvc/target/app-mvc-1.0.0.jar --spring.profiles.active=platform
java -jar app-mvc/target/app-mvc-1.0.0.jar --spring.profiles.active=virtual
java -jar app-webflux/target/app-webflux-1.0.0.jar
```

Проверка, что режим применился: `curl localhost:8080/whoami`
(у виртуального варианта в ответе будет `virtual: VirtualThread[...]`).

## Нагрузка

```
k6 run -e VUS=500 -e DURATION=60s -e MS=100 -e CALLS=1 load/work.js
```
