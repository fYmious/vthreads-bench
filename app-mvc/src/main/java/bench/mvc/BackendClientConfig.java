package bench.mvc;

import java.net.http.HttpClient;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.client.JdkClientHttpRequestFactory;
import org.springframework.web.client.RestClient;

@Configuration
public class BackendClientConfig {

    /**
     * Блокирующий HTTP-клиент. HTTP/1.1 задан явно, чтобы не зависеть
     * от попыток апгрейда до HTTP/2 и сравнивать с WebClient в равных условиях.
     */
    @Bean
    RestClient backendClient(@Value("${bench.backend-url}") String backendUrl) {
        HttpClient http = HttpClient.newBuilder()
                .version(HttpClient.Version.HTTP_1_1)
                .build();
        return RestClient.builder()
                .baseUrl(backendUrl)
                .requestFactory(new JdkClientHttpRequestFactory(http))
                .build();
    }
}
