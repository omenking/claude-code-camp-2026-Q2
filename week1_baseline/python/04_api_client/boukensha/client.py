import json
import socket
import ssl
import time
import urllib.error
import urllib.request

from .errors import ApiError


class Client:
    RETRYABLE_STATUS_CODES = {408, 409, 429, 500, 502, 503, 504}
    TRANSIENT_ERRORS = (
        urllib.error.URLError,
        TimeoutError,
        ConnectionError,
        ssl.SSLError,
        EOFError,
        socket.gaierror,
    )
    MAX_RETRIES = 3
    BASE_RETRY_DELAY = 0.5

    def __init__(self, builder):
        self.builder = builder

    def call(self, max_output_tokens=1024):
        url = self.builder.url()
        headers = self.builder.headers()
        body = json.dumps(
            self.builder.to_api_payload(max_output_tokens=max_output_tokens)
        ).encode("utf-8")

        attempts = 0
        status = None
        response_body = None

        while True:
            attempts += 1
            request = urllib.request.Request(url, data=body, headers=headers, method="POST")

            try:
                with urllib.request.urlopen(request) as response:
                    status = response.status
                    response_body = response.read()
            except urllib.error.HTTPError as e:
                status = e.code
                response_body = e.read()
            except self.TRANSIENT_ERRORS as e:
                if attempts > self.MAX_RETRIES:
                    raise ApiError(
                        f"API request failed after {attempts} attempts: {type(e).__name__}: {e}"
                    )
                time.sleep(self._retry_delay(attempts))
                continue

            if self._retryable_response(status) and attempts <= self.MAX_RETRIES:
                time.sleep(self._retry_delay(attempts))
                continue

            break

        if not (200 <= status < 300):
            plural = "" if attempts == 1 else "s"
            raise ApiError(
                f"API request failed after {attempts} attempt{plural} "
                f"({status}): {response_body.decode('utf-8', errors='replace')}"
            )

        return json.loads(response_body)

    def _retryable_response(self, status):
        return status in self.RETRYABLE_STATUS_CODES

    def _retry_delay(self, attempt):
        return self.BASE_RETRY_DELAY * (2 ** (attempt - 1))
