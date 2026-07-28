---
layout: post
title: "Implementing Idempotent HTTP APIs with the Idempotency-Key Header"
date: 2026-04-12 21:07:00 +0900
categories: [Developer, Spring]
tags: [spring, kotlin, http, idempotency, resilience]
---

## Introduction

As systems grow larger, communication between different backend services
becomes more frequent and more complex — and with more network calls comes
a higher chance of network failures. These failures can stem from many
causes: brief network blips, client-side connection timeouts, packet loss,
and so on.

Digging into the root cause every single time is expensive, and even when
you find it, preventing recurrence is hard — because in many cases the fix
is simply **retrying the request**.

This is why designing idempotent HTTP APIs matters. Let's dive in.

## Terminology

Two concepts come up throughout this post:

- **Idempotency**: a property from math and computer science where applying
  an operation multiple times produces the same result as applying it once.
  f(f(x)) = f(x)
- **Resilience**: a system's ability to keep functioning, or recover
  quickly, in the face of external shocks or failures.

## Idempotency

With a non-idempotent HTTP API, a client that hits a timeout or an unstable
connection is left in an uncertain state. Was the resource created? Was it
updated? Did the server finish processing the request at all? Worse, the
client can't even tell whether it is *safe* to retry.

![Uncertain client state without idempotency](/assets/images/2026-07-28/idempotent-http.png)

That's why APIs that create, update, or delete resources should provide
idempotency — it gives clients a safe foundation for **retries** and makes
the whole system far more **resilient**.

So how do we design it?

## Architecture

There are several approaches, but this design follows the IETF draft:

[The Idempotency-Key HTTP Header Field](https://www.ietf.org/archive/id/draft-ietf-httpapi-idempotency-key-header-01.html)

The draft defines an optional `Idempotency-Key` HTTP header. The core of
the design is distinguishing the following cases:

1. **First request** — process normally, return HTTP 200, and persist both
   the request and response in a repository (adding a TTL makes operations
   much easier).
2. **Second request** — same `Idempotency-Key` and same request body, with
   a stored result on the server: return the stored response.
3. **Duplicate request** — same `Idempotency-Key` arrives again within a
   short window (i.e., the first one is still processing): return HTTP 409
   to signal it's already in progress.
4. **Invalid request** — same `Idempotency-Key` but a *different* request
   body: return HTTP 422 to signal the request can't be processed.
5. **Invalid request** — the header violates length constraints: return
   HTTP 400.

Case 2 is the important one — it's what lets clients retry easily. Case 3
tells the client to back off a bit longer before retrying. Case 4 guards
against client implementation mistakes and tampering.

![API spec example](/assets/images/2026-07-28/api_spec.png)

In Spring, this can be implemented as a servlet filter. The core flow looks
like this (abridged — full source linked below):

```kotlin
@Component
class IdempotentHttpWebMvcFilter(
    private val registry: IdempotentHttpWebMvcRegistry,
    private val repository: IdempotentHttpRepository,
) : OncePerRequestFilter(), OrderedFilter {

    override fun doFilterInternal(
        request: HttpServletRequest,
        response: HttpServletResponse,
        filterChain: FilterChain
    ) {
        val key = request.getHeader(IdempotencyHeader.IDEMPOTENCY_KEY)
        when {
            key == null -> filterChain.doFilter(request, response)
            key.isBlank() || key.length > 100 ->
                response.reject(HttpStatus.BAD_REQUEST)          // case 5
            registry.notRegistered(request.method, request.requestURI) ->
                response.reject(HttpStatus.BAD_REQUEST)
            else -> processIdempotentHttp(/* ... */)
        }
    }

    private fun processIdempotentHttp(/* ... */) {
        val existing = repository.findByIdOrNull(idempotentHttpId)
        when {
            existing == null ->
                doFilterAndRecord(/* ... */)                     // case 1
            existing.isDifferentRequest(currentRequest) ->
                response.reject(HttpStatus.UNPROCESSABLE_ENTITY) // case 4
            existing.response == null ->
                response.reject(HttpStatus.CONFLICT)             // case 3
            else ->
                response.replay(existing.response)               // case 2
        }
    }
}
```

One implementation detail worth noting: if saving the response fails after
the request was processed, reliable idempotency can no longer be
guaranteed — so the record itself should be deleted to avoid incorrectly
returning 409 on the next retry.

For the repository, pick a store that supports TTL. Redis is my
recommendation: key-value commands make concurrency control simple, and
it's fast to implement.

Full source code is available here:

[GitHub - huisam/spring-idempotency](https://github.com/huisam/spring-idempotency)

## Client configuration

How should clients configure the `Idempotency-Key` header and their retry
strategy?

For the header:

- Use a unique key per API request — UUID v4 is strongly recommended.
- On **HTTP 409**, the server is still processing; retry later with the
  **same** `Idempotency-Key`.
- The server records every outcome, success or failure. The goal is to
  remove uncertainty about "what did the client attempt, and what was the
  result?" To make a genuinely new attempt, use a new `Idempotency-Key`.

Recording failures includes *business* failures. For example, if a payment
API call fails because the card is expired, that failure response is
recorded too. The point of the `Idempotency-Key` is not to guarantee a
single success — it's to record the outcome of the operation, whatever
it was.

For retries:

- Too many retries, or retries at too short an interval, only make things
  worse for the server. Cap the retry count and use exponential backoff.
- Recommended defaults:
  - maxAttempts: 3
  - exponential backoff — initial delay: 2s, multiplier: 2

Exponential backoff reduces server load and avoids repeatedly hitting the
"still processing" response. Since processing time varies per API, publish
recommended values per API; for high-latency endpoints, just bump the
initial delay.

## Closing

Today we looked at idempotency and how to build idempotent APIs with the
`Idempotency-Key` HTTP header. It's an essential ingredient for running a
resilient system in an MSA environment — give it a try in your own
services.