---
layout: post
title: "Virtual Thread and Kotlin Coroutine - Same Problem, Different Goals"
date: 2026-09-17 20:00:00 +0900
categories: [Backend, Java]
tags: [virtual-thread, coroutine, kotlin, java21, concurrency, project-loom]
---

## In Coming

With Java 21 landing as an LTS release, **Virtual Thread** has been getting a lot of attention — so let's talk about it.

A Virtual Thread runs *on top of* a Platform thread. When I/O blocking happens, it moves its suspension point onto the heap so that the underlying carrier thread can go do other work during the time that would otherwise be spent waiting. In other words, it is a lightweight thread.

That is exactly why the Java world got so excited about it. In a classic thread-per-request application server, a thread stuck on I/O blocking does nothing at all and still cannot pick up another task — and that becomes the bottleneck. Virtual Thread attacks that problem directly.

Let's see what makes it so compelling.

## Virtual Thread

### Goal

First we need to understand what Virtual Thread is actually *for*.

Understanding the goal matters a lot, because the goal is what decides the direction the technology develops in.

Here are the goals of Project Loom, the project that produced Virtual Thread:

1. Enable server applications written in the simple thread-per-request style to scale with near-optimal hardware utilization
2. Enable existing (legacy) code that uses the `java.lang.Thread` API to adopt virtual threads with minimal change
3. Enable easy troubleshooting, debugging, and profiling of virtual threads with existing JDK tools

As the goals say, the aim is to make it easy to adopt Virtual Thread in a thread-per-request application server that is *already* in production, without a big change to the way you already write code.

It is not delivered through some brand-new API — it delivers as much capability as possible while keeping backward compatibility cheap.

### Example

Let's walk through an example.

Suppose we have logic that creates a thread pool and processes tasks through it:

```kotlin
fun main() {
    val executors = Executors.newFixedThreadPool(10)

    val elapsed = measureTimeMillis {
        val futures = (1..100).map {
            executors.submit {
                Thread.sleep(500)
            }
        }
        futures.forEach { it.get() }
    }

    println("took $elapsed ms")
}
```

The pool has 10 threads, we submit 100 tasks, and each task takes 500ms.

So how long does the whole thing take?

![Platform thread - 5100ms](/assets/images/2026-09-17/platform-thread-result.png)
_Platform thread - 5100ms_

Even by back-of-the-envelope math, it takes about 5 seconds.

Now, as the goals promised, let's switch it over to Virtual Thread and see what changes:

```kotlin
fun main() {
    val executors = Executors.newVirtualThreadPerTaskExecutor()

    val elapsed = measureTimeMillis {
        val futures = (1..100).map {
            executors.submit {
                Thread.sleep(500)
            }
        }
        futures.forEach { it.get() }
    }

    println("took $elapsed ms")
}
```

A very small change — we just use `Executors.newVirtualThreadPerTaskExecutor()` so the tasks run on virtual threads.

And the result is, surprisingly...

![Virtual thread - 540ms](/assets/images/2026-09-17/virtual-thread-result.png)
_Virtual thread - 540ms_

It takes roughly as long as *a single task* takes.

Why?

### Principle

![Virtual thread architecture](/assets/images/2026-09-17/virtual-thread-architecture.webp)
_Virtual thread architecture_

A Virtual Thread runs on top of a Platform thread.

But when it enters a blocked state, it gets mounted onto the heap — stored temporarily — and the carrier thread is told to go run other tasks instead.

So in the example above, no matter how many tasks we process, the blocked threads all pile up their data on the heap, and total processing time stays the same.

![Thread states](/assets/images/2026-09-17/thread-state.png)
_Thread states_

Because the waiting for I/O is parked on the heap and resumed later, the Platform threads you were given (the threads of the ForkJoinPool) keep processing work without sitting idle.

### Limit

That said, even this very appealing heap-mounting behavior has its limits:

- Running inside a native method
- Running inside a `synchronized` section

![Mount limitations](/assets/images/2026-09-17/mount-limit.png)

Inside native methods and `synchronized` sections, mounting cannot happen.

Why? Because both of them end up in a situation where they have no choice but to **pin** the platform thread.

In other words, they are implemented in a way that forces the thread to stay fixed in place.

Both features are implemented at the JVM level, so this is not something that can be handled at the Java language level.

![How synchronized works](/assets/images/2026-09-17/synchronized-mechanism.png)
_How synchronized works_

For example, `synchronized` is implemented as a monitor-object-based operation that blocks the thread — so it is not an area the language level can reach into.

These limitations exist, but I suspect Virtual Thread was designed with the current trend in mind: places with heavy I/O blocking, and especially today's MSA (microservice architecture) style systems where communication with external servers keeps increasing.

The Java world is moving forward like this — and meanwhile, on the same JVM, Kotlin already had a lot of attention on its `coroutine` API. So naturally, more and more people started comparing Java and Kotlin, and ended up comparing Virtual Thread with coroutines too.

But first we need to recognize that the two have *different purposes*.

## Kotlin Coroutine

### Goal

What is the goal of Kotlin coroutines?

1. Make it possible to utilize Kotlin coroutines as wrappers for different existing asynchronous APIs (such as Java NIO, different implementations of Futures, etc.)
2. No dependency on a particular implementation of Futures or such rich library
3. Cover equally the async/await use case and generator blocks

Surprisingly, the goal of coroutines is to wrap asynchronous APIs in Kotlin and provide an **abstraction over asynchrony**.

So we can see that the goal itself is different from Virtual Thread's.

### Principle

![Coroutine](/assets/images/2026-09-17/coroutine.png)
_Coroutine_

Here is a diagram that helps make sense of the various features coroutines provide.

As you can see, treat it as a picture for understanding that all of these are ways of asynchronous behavior abstracted at the *language* level.

For instance, features like `launch` and `async`-`await` process tasks while hopping across threads.

They are not really apples-to-apples, but let's compare them a bit more anyway:

| | Virtual Thread | Coroutine |
| --- | --- | --- |
| Implementation | Inside the VM | Inside the Kotlin compiler |
| Cost | yield cost: high<br>call cost: low | yield cost: low<br>suspend call cost: high |
| Memory | High | Low |

When a Virtual Thread yields (waits), it immediately puts things on heap memory, so its memory cost is inevitably expensive.

A coroutine, on the other hand, records the suspension point for a yield (wait) as *state*, so there is no memory usage of that kind — it spends more CPU instead.

### Example

So is there a way to bring Virtual Thread into coroutines?

As explained above, Virtual Thread is very effective at dealing with I/O blocking:

```kotlin
suspend fun main() {
    val dispatcher = Dispatchers.IO

    coroutineScope {
        val elapsed = measureTimeMillis {
            val jobs = (1..100_000).map {
                async(dispatcher) {
                    delay(500)
                }
            }
            awaitAll(*jobs.toTypedArray())
        }

        println("took $elapsed ms")
    }
}
```

For reference, you can think of `Dispatchers.IO` as a thread pool that creates and operates 64 Platform threads.

With 100,000 tasks that each take 500ms, the result is...!

![Dispatchers.IO - 1817ms](/assets/images/2026-09-17/dispatchers-io-result.png)
_Dispatchers.IO - 1817ms_

This time, let's build a dispatcher that runs on Virtual Threads instead:

```kotlin
suspend fun main() {
    val dispatcher = Executors.newVirtualThreadPerTaskExecutor().asCoroutineDispatcher()

    coroutineScope {
        val elapsed = measureTimeMillis {
            val jobs = (1..100_000).map {
                async(dispatcher) {
                    delay(500)
                }
            }
            awaitAll(*jobs.toTypedArray())
        }

        println("took $elapsed ms")
    }
}
```

And running it gives...!

![Virtual thread Dispatcher - 1028ms](/assets/images/2026-09-17/virtual-thread-dispatcher-result.png)
_Virtual thread Dispatcher - 1028ms_

Because it is lighter than a Platform thread, it shows better performance.

By the way, since coroutines are asynchronous by nature, the measured numbers can differ depending on the machine you run them on.

One more thing — coroutines are often described as properly embracing the **structured concurrency** concept:

![Structured concurrency](/assets/images/2026-09-17/structured-concurrency.png)

This is because `coroutineScope` fundamentally has two characteristics:

- Parent - Child hierarchy
- Cancellation and error handling

I have written before about exception handling in coroutines, so that might be a useful reference.

> [\[Kotlin\] Coroutine - 4. Exception handling in coroutines](https://huisam.tistory.com/entry/kotlin-coroutine-exception)

Of course, word is that Structured Concurrency also arrived in the Java world as a preview in Java 21.

I am curious to see how the two will differ.

## Wrapping Up

Today we looked at Virtual Thread, and at coroutines as well.

As technology keeps advancing in a world with more and more I/O, these feel like two sets of results from asking the same question: how do we squeeze out the maximum performance?

I am looking forward to what comes next, and I hope the day comes when Virtual Thread is productionized widely enough to be used as broadly as Kotlin coroutines are :)

## Reference

> [Coroutines and Loom behind the scenes by Roman Elizarov](https://www.youtube.com/watch?v=zluKcazgkV4)

> [OpenJDK - JEP 444: Virtual Threads](https://openjdk.org/jeps/444)

> [Kotlin - Coroutines basics](https://kotlinlang.org/docs/coroutines-basics.html)
