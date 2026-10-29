package bench.mvc;

/** Ответ имитируемого внешнего сервиса. */
public record BackendReply(long delayMs, long serverTime) {}
