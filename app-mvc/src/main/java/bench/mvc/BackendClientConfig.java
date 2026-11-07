package bench.mvc;

import org.apache.hc.client5.http.impl.classic.CloseableHttpClient;
import org.apache.hc.client5.http.impl.classic.HttpClients;
import org.apache.hc.client5.http.impl.io.PoolingHttpClientConnectionManager;
import org.apache.hc.client5.http.impl.io.PoolingHttpClientConnectionManagerBuilder;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.HttpComponentsClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

@Configuration
public class BackendClientConfig {
  

    /**
     * Блокирующий HTTP-клиент на Apache HttpClient 5.
     *
     * Запрос выполняется прямо в вызывающем потоке (платформенном или виртуальном),
     * без собственного пула потоков. Прежний вариант на java.net.http.HttpClient
     * по умолчанию заводил платформенный поток под каждый одновременный запрос,
     * из-за чего вариант с виртуальными потоками не был "чистым".
     *
     * Размер пула соединений задан явно и совпадает с WebClient в app-webflux
     * (параметр bench.pool-size), чтобы лимит соединений не влиял на сравнение.
     */
    @Bean
    RestClient backendClient(@Value("${bench.backend-url}") String backendUrl,
                             @Value("${bench.pool-size:10000}") int poolSize) {
        PoolingHttpClientConnectionManager connectionManager =
                PoolingHttpClientConnectionManagerBuilder.create()
                        .setMaxConnTotal(poolSize)
                        .setMaxConnPerRoute(poolSize)
                        .build();
        CloseableHttpClient http = HttpClients.custom()
                .setConnectionManager(connectionManager)
                .build();
        return RestClient.builder()
                .baseUrl(backendUrl)
                .requestFactory(new HttpComponentsClientHttpRequestFactory(http))
                .build();
    }
}
