package bench.webflux;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.reactive.ReactorClientHttpConnector;
import org.springframework.web.reactive.function.client.WebClient;
import reactor.netty.http.client.HttpClient;
import reactor.netty.resources.ConnectionProvider;

@Configuration
public class WebClientConfig {

    /**
     * Размер пула соединений задан явно и по умолчанию большой,
     * чтобы он не ограничивал пропускную способность. Значение нужно
     * зафиксировать в описании методики эксперимента.
     */
    @Bean
    WebClient backendClient(@Value("${bench.backend-url}") String backendUrl,
                            @Value("${bench.pool-size:10000}") int poolSize) {
        ConnectionProvider provider = ConnectionProvider.builder("backend")
                .maxConnections(poolSize)
                .pendingAcquireMaxCount(poolSize * 4)
                .build();
        return WebClient.builder()
                .baseUrl(backendUrl)
                .clientConnector(new ReactorClientHttpConnector(HttpClient.create(provider)))
                .build();
    }
}
