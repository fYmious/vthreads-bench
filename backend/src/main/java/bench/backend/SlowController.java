package bench.backend;

import java.time.Duration;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import reactor.core.publisher.Mono;

@RestController
public class SlowController {

    public record Reply(long delayMs, long serverTime) {}

    /** Отвечает через ms миллисекунд, не занимая ни одного потока на время ожидания. */
    @GetMapping("/slow")
    public Mono<Reply> slow(@RequestParam(defaultValue = "100") long ms) {
        return Mono.fromSupplier(() -> new Reply(ms, System.currentTimeMillis()))
                .delaySubscription(Duration.ofMillis(ms));
    }
}
