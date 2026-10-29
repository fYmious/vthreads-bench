package bench.mvc;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

/**
 * Один и тот же код запускается в двух режимах (профили Spring):
 *  - platform: Tomcat с пулом платформенных потоков;
 *  - virtual:  Tomcat, где каждый запрос обрабатывается в виртуальном потоке.
 * Отличие только в конфигурации, поэтому сравнение честное.
 */
@SpringBootApplication
public class MvcApplication {
    public static void main(String[] args) {
        SpringApplication.run(MvcApplication.class, args);
    }
}
