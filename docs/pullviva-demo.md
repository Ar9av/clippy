# Retry policy

Failed API calls are retried up to 3 times with exponential backoff: 1s, 2s, 4s.
Only network errors and HTTP 429 or 503 responses are retried; other 4xx errors fail immediately.
Each retry reuses the same idempotency key so the server can discard duplicate requests.
After the final attempt the error is shown to the user instead of being swallowed.
