---
layout: post
title: "Why do SocketException: Connection reset and ClientAbortException happen?"
date: 2026-08-05 18:00:00 +0900
categories: [Backend, Network]
tags: [network, tcp, socket-exception, connection-reset, broken-pipe, kotlin]
---

## In Coming

As MSA has become the norm, we end up operating a variety of domain servers in order to work through complex business requirements.

The more domain servers there are, the more network communication grows along with them.

And with that growth comes a whole family of network-related exceptions. But *analyzing a network error and reasoning about all the situations that could have produced it* is genuinely hard.

That's why we usually design our APIs to support [**idempotency**](/posts/spring-idempotency).

Still, some of us are stuck with legacy code that never adopted idempotency, or in a situation where an idempotent design simply isn't feasible.

In those cases there's no way around it — we have to analyze our way through. So let's take a quick look at the kinds of network errors that show up in the Java and Kotlin world.

The two items I want to introduce today are **SocketException: Connection reset** and **ClientAbortException: broken pipe**, but the deep dive will focus on **SocketException: Connection reset**.

## Network Exception

Why does **SocketException: Connection reset** occur?

Why does **ClientAbortException: broken pipe** occur?

And what is the difference between the two?

- **SocketException: Connection reset** — the exception raised on the **client** side when the connection is forcibly terminated by the remote server. This typically corresponds to the case where the **server** has sent a **TCP RST packet**.
  - The remote server application crashed
  - The remote server is not listening on that port
  - A network configuration error
  - The connection went idle and the server decided to close it
  - ...
- **ClientAbortException: broken pipe** — the exception raised on the **server** side when the connection is forcibly cut by the **client** while the response was being written.
  - The client application crashed or exited
  - The user (client) navigated away from the web page before the server responded
  - The client closed the connection before the server responded
  - ...

Beyond these, the situations that can trigger the exceptions above are *enormously* varied.

Today I want to understand **SocketException: Connection reset**.

And to understand that, we first need to understand the TCP RST scenarios.

## TCP RST

So what on earth is TCP RST?

![TCP RST](/assets/images/2026-08-05/tcp-rst.png)

Put simply, it's a flag sent in order to **forcibly close a TCP connection from the server side**.

TCP fundamentally drives communication through a mutual conversation, so TCP RST is the server telling the client:

"I have nothing more to say to you. Goodbye." — a notification followed by an immediate halt.

The scenarios in which TCP RST occurs are extremely diverse.

So what are the scenarios that can produce a TCP RST?

### Scenario 1

![Scenario 1](/assets/images/2026-08-05/scenario1.png)

The scenario above is the client raising an RST because a SYN segment was delayed and the ACK was misinterpreted.

The client expected a 201 ACK for its 200 SYN, but a 91 ACK arrived instead — so the client raises an RST before the connection is established.

Fortunately, since this all happened before the connection was established, we can read it as nothing being aborted.

### Scenario 2

![Scenario 2](/assets/images/2026-08-05/scenario2.png)

In this scenario TCP A has crashed. It sent a 200 SYN, but seeing an ACK of 150 come back, the client sends an RST packet to the server.

Here TCP B is the side that meets an abort, and the response it had been writing is forcibly halted.

After that the request for SYN 200 is made again, and TCP B goes through the process of returning the ACK for 200.

### Scenario 3

![Scenario 3](/assets/images/2026-08-05/scenario3.png)

This case is much the same. TCP A was in a crashed state and cannot recognize the 150 ACK,

so it sends an RST toward TCP B, and TCP B meets an abort.

### Scenario 4

![Scenario 4](/assets/images/2026-08-05/scenario4.png)

In this case the two sides ended up with mismatched seq and ack during the establish process.

Just like Scenario 1, the client sends an RST and then proceeds through the process of establishing the connection again.

Summarizing all of the scenarios, RST really does occur in many different ways.

- It can occur during the establish process, before the connection is made
- It can occur while data is being written
- The case where the client or server forcibly closes the connection
- ...

Of the scenarios above, let's look more closely at what the forcible-close case actually looks like.

## Connection close RST

![Connection close](/assets/images/2026-08-05/connection-close.png)

Normally, connection close means exchanging **FIN packets** and then calling close — that's TCP's termination process.

However, there are cases that terminate forcibly without going through that FIN exchange, and we can experiment with this via the **Linger** option (enabled, with a 0-second timeout).

> The Linger option controls how unsent data is handled when a TCP socket is closed. It's easiest to think of it as a policy setting for what to do with data still sitting in the socket buffer. The default is off, which guarantees that remaining data is always transmitted.

At that point, if the server aborts the connection immediately, the client never received a FIN packet — yet it does recognize that the connection has been terminated.

So the client recognizes the RST and raises **SocketException: Connection reset**.

Let's try reproducing **SocketException: Connection reset** without setting the Linger option ourselves.

The key point seems to be that the server halts immediately.

### A scenario that reproduces Connection Reset

Please recognize that this reproduction is **one** of the scenarios in which **SocketException: Connection reset** occurs. Really!

Create the controller code below on server2, and have server1 call it with a 10-second delay.

```kotlin
@RestController
@RequestMapping("/delay")
class DelayController {
    @GetMapping("/time")
    fun delay(
        @RequestParam t: Long
    ): DelayTimeDto {
        Thread.sleep(t)

        return DelayTimeDto("Delayed by $t ms.")
    }
}
```

While calling the API above, let's apply the following arbitrary interference.

- In the middle of server1's call to server2, suddenly shut down server2.
- Because server2 abruptly calls `socket.close`, server1 receives a connection reset as its response.

Based on that process, let's analyze the TCP flow through Wireshark.

server1: port 8080

![server1 wireshark](/assets/images/2026-08-05/server1-wireshark.png)

server2: port 8081

![server2 wireshark](/assets/images/2026-08-05/server2-wireshark.png)

- The 3-way handshake establishes the connection based on seq 0, ack 1.
- server1 sends its request based on seq 1, and recognizes via PSH that it is to receive data.
- server2 halts suddenly and sends an RST for seq 1 to server1.

In the end server2 terminates abruptly, and the exception log on server1 is printed as follows.

![Exception log](/assets/images/2026-08-05/exception-log.png)

## Conclusion

So the **SocketException: Connection reset** that occurs on the client is entirely triggered from the server side.

As the reproduction scenario shows, it is hard to conclude whether the server processed the request correctly or not — that depends on which RST scenario occurred.

When **SocketException: Connection reset** happens, the one action you can directly take is to ask the counterpart server for confirmation and diagnose the network error path together.

- Whether there is an error in the network configuration
- Whether the application died arbitrarily, or was in the middle of a deployment
- Whether the RST was forced by another network element (such as a firewall)

## Reference

> [Orderly Versus Abort Connection release in java](https://docs.oracle.com/javase/8/docs/technotes/guides/net/articles/connection_release.html)

> [Connection Reset](https://yangbongsoo.gitbook.io/study/connection_reset)

> [TCP: Differences Between FIN and RST](https://www.baeldung.com/cs/tcp-fin-vs-rst)
