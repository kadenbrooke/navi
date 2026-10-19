// REST fetch helper for the local Omnigent API. Keep the retry bounded: it is
// best-effort transport resilience, not a claim about the root cause. The
// daemon's sustained-outage self-heal is the recovery path for process-wide
// HTTP/WS failures.

const RETRYABLE_CODES = new Set([
  "ECONNABORTED",
  "ECONNREFUSED",
  "ECONNRESET",
  "EHOSTUNREACH",
  "ENETUNREACH",
  "EPIPE",
  "ETIMEDOUT",
  "UND_ERR_CONNECT_TIMEOUT",
  "UND_ERR_SOCKET",
]);

const RETRY_DELAY_MS = 50;

function causeText(error) {
  const cause = error?.cause;
  if (!cause) return "";
  const code = cause.code ? `${cause.code}: ` : "";
  const message = cause.message || String(cause);
  return `${code}${message}`;
}

export function formatOmnigentFetchError(error, url, { method = "GET" } = {}) {
  const message = error?.message || String(error);
  const cause = causeText(error);
  const detail = cause && !message.includes(cause) ? `${message}; cause: ${cause}` : message;
  const request = `[${method} ${url}]`;
  return detail.includes(request) ? detail : `${detail} ${request}`;
}

function isRetryable(error) {
  if (error?.name === "AbortError") return false;
  const code = error?.cause?.code || error?.code;
  return RETRYABLE_CODES.has(code) || (error?.message === "fetch failed" && !code);
}

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Fetch and decode one Omnigent JSON response.
 *
 * The one retry is a bounded best-effort for a transport error between request
 * creation and response headers; it is not evidence that the daemon's HTTP
 * runtime is healthy. Non-2xx responses are not retried and retain their HTTP
 * status in the error.
 */
export async function fetchOmnigentJson(url, timeoutMs, { fetchImpl = fetch } = {}) {
  let lastError;
  const timeout = Number(timeoutMs);
  if (!Number.isFinite(timeout) || timeout <= 0) {
    const error = new Error(`omnigent fetch timeout: timeoutMs must be > 0 (got ${timeoutMs})`);
    throw new Error(formatOmnigentFetchError(error, url), { cause: error });
  }
  const deadline = Date.now() + (Number.isFinite(timeout) ? Math.max(0, timeout) : 0);
  for (let attempt = 0; attempt < 2; attempt++) {
    const remaining = deadline - Date.now();
    if (remaining <= 0) break;
    const ctl = new AbortController();
    const timer = setTimeout(() => ctl.abort(), remaining);
    try {
      const res = await fetchImpl(url, {
        signal: ctl.signal,
        headers: { accept: "application/json", connection: "close" },
      });
      if (!res.ok) throw new Error(`omnigent HTTP ${res.status} ${res.statusText || ""}`.trim());
      return await res.json();
    } catch (error) {
      lastError = error;
      if (attempt === 0 && isRetryable(error)) {
        const delay = Math.min(RETRY_DELAY_MS, Math.max(0, deadline - Date.now()));
        if (delay <= 0) break;
        await wait(delay);
        continue;
      }
      throw new Error(formatOmnigentFetchError(error, url), { cause: error });
    } finally {
      clearTimeout(timer);
    }
  }
  throw new Error(formatOmnigentFetchError(lastError, url), { cause: lastError });
}
