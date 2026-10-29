package bench.backend;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Имитация медленного внешнего сервиса (БД / внешний API).
 * Построен на WebFlux/Netty, чтобы сам бэкенд никогда не был узким местом:
 * тысячи одновременных "ожиданий" ему почти ничего не стоят.
 */
@SpringBootApplication
public class BackendApplication {
    public static void main(String[] args) {
        SpringApplication.run(BackendApplication.class, args);
    }
}
