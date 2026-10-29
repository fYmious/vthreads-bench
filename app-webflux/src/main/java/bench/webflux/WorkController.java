package bench.webflux;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.core.publisher.Flux;
import reactor.core.publisher.Mono;

@RestController
public class WorkController {

    public record Result(int calls, long checksum) {}

    private final WebClient backend;

    public WorkController(WebClient backend) {
        this.backend = backend;
    }

    /**
     * Тот же сценарий, что и в app-mvc: calls последовательных обращений
     * к медленному сервису. concatMap сохраняет последовательность вызовов.
     */
    @GetMapping("/work")
    public Mono<Result> work(@RequestParam(defaultValue = "100") long ms,
                             @RequestParam(defaultValue = "1") int calls) {
        return Flux.range(0, calls)
                .concatMap(i -> backend.get()
                        .uri("/slow?ms={ms}", ms)
                        .retrieve()
                        .bodyToMono(BackendReply.class))
                .map(BackendReply::delayMs)
                .reduce(0L, Long::sum)
                .map(checksum -> new Result(calls, checksum));
    }

    @GetMapping("/whoami")
    public Mono<String> whoami() {
        return Mono.fromSupplier(() -> "reactive: " + Thread.currentThread());
    }
}
