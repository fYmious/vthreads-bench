package bench.mvc;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

@RestController
public class WorkController {

    public record Result(int calls, long checksum) {}

    private final RestClient backend;

    public WorkController(RestClient backend) {
        this.backend = backend;
    }

    /**
     * I/O-bound сценарий: calls последовательных обращений к медленному сервису
     * (каждое занимает ms миллисекунд). Код линейный и блокирующий.
     */
    @GetMapping("/work")
    public Result work(@RequestParam(defaultValue = "100") long ms,
                       @RequestParam(defaultValue = "1") int calls) {
        long checksum = 0;
        for (int i = 0; i < calls; i++) {
            BackendReply reply = backend.get()
                    .uri("/slow?ms={ms}", ms)
                    .retrieve()
                    .body(BackendReply.class);
            checksum += reply.delayMs();
        }
        return new Result(calls, checksum);
    }

    /** Проверка: в каком потоке реально обрабатывается запрос. */
    @GetMapping("/whoami")
    public String whoami() {
        Thread t = Thread.currentThread();
        return (t.isVirtual() ? "virtual: " : "platform: ") + t;
    }
}
