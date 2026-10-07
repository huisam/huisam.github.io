---
layout: post
title: "[Kotlin] Coroutine - 2. Digging into CoroutineScope, Context & Dispatcher"
date: 2026-10-06 20:00:00 +0900
categories: [Backend, Kotlin]
tags: [kotlin, coroutine, coroutinescope, coroutinecontext, dispatcher, concurrency]
---

## In Coming

The way a coroutine actually behaves still does not quite click, does it?

How on earth does it only *look* like things run at the same time?

How does a coroutine hop back and forth between threads while it gets work done?

How does a coroutine pull off this magic-looking concurrent processing?

To build that understanding we are going to walk through the code piece by piece.
Before we do, let's go over the elements a coroutine needs in order to run.

## The Building Blocks of a Coroutine

To see how those blocks fit together, let's create one simple coroutine.

```kotlin
CoroutineScope(Dispatchers.Default).launch {
    println("Starting in ${Thread.currentThread().name}")
    delay(500)
}.join()

public fun CoroutineScope(context: CoroutineContext): CoroutineScope =
    ContextScope(if (context[Job] != null) context else context + Job())
```

When we create a coroutine, we can see that we use a `CoroutineScope` and a `Dispatcher` to
specify a `CoroutineContext`.

Let's look at what each of these terms means and what their interfaces look like.

### CoroutineScope

`CoroutineScope` means the *scope* of a coroutine. Think of it as the overall scope that shares
the coroutine's lifecycle.

```kotlin
public interface CoroutineScope {
    /**
     * The context of this scope.
     * Context is encapsulated by the scope and used for implementation of coroutine builders that are extensions on the scope.
     * Accessing this property in general code is not recommended for any purposes except accessing the [Job] instance for advanced usages.
     *
     * By convention, should contain an instance of a [job][Job] to enforce structured concurrency.
     */
    public val coroutineContext: CoroutineContext
}
```

Because of that, the only property on the interface is a single `CoroutineContext` field.

In other words, among the elements that manage a coroutine, this is the interface with the
widest scope.

![CoroutineScope is the widest-scoped interface](/assets/images/2026-10-06/coroutine-scope-hierarchy.png)
_CoroutineScope is the interface with the widest scope_

### CoroutineContext

To put it simply, a `CoroutineContext` is the *set* of things that make up a coroutine.

```kotlin
public interface CoroutineContext {

    public operator fun <E : Element> get(key: Key<E>): E?

    public fun <R> fold(initial: R, operation: (R, Element) -> R): R

    public operator fun plus(context: CoroutineContext): CoroutineContext =
        if (context === EmptyCoroutineContext) this else // fast path -- avoid lambda creation
            context.fold(this) { acc, element ->
                val removed = acc.minusKey(element.key)
                if (removed === EmptyCoroutineContext) element else {
                    // make sure interceptor is always last in the context (and thus is fast to get when present)
                    val interceptor = removed[ContinuationInterceptor]
                    if (interceptor == null) CombinedContext(removed, element) else {
                        val left = removed.minusKey(ContinuationInterceptor)
                        if (left === EmptyCoroutineContext) CombinedContext(element, interceptor) else
                            CombinedContext(CombinedContext(left, element), interceptor)
                    }
                }
            }

    public fun minusKey(key: Key<*>): CoroutineContext

    public interface Key<E : Element>
}
```

Looking at the functions the interface provides, a `CoroutineContext` is composed of `Element`s,
and each `Element` can be added or pulled back out through `get` or `fold`.

On top of that, by `plus`-ing or `minus`-ing another `CoroutineContext` you can merge or remove a
specific `Element`.

So you can understand a `CoroutineContext` as the persistent context of a coroutine.

Among the elements that make up such a context, there is an implementation called the
`Dispatcher`.

### Dispatcher

The `Dispatcher` is responsible for deciding **how** the coroutine's tasks get distributed for
execution.

To be precise, it is the `Interceptor` that makes a coroutine suspend or resume its work — but
that part comes later.

```kotlin
public abstract class CoroutineDispatcher :
    AbstractCoroutineContextElement(ContinuationInterceptor), ContinuationInterceptor {

    /** @suppress */
    @ExperimentalStdlibApi
    public companion object Key : AbstractCoroutineContextKey<ContinuationInterceptor, CoroutineDispatcher>(
        ContinuationInterceptor,
        { it as? CoroutineDispatcher })

    public open fun isDispatchNeeded(context: CoroutineContext): Boolean = true

    public abstract fun dispatch(context: CoroutineContext, block: Runnable)

    @InternalCoroutinesApi
    public open fun dispatchYield(context: CoroutineContext, block: Runnable): Unit = dispatch(context, block)

    public final override fun <T> interceptContinuation(continuation: Continuation<T>): Continuation<T> =
        DispatchedContinuation(this, continuation)

    public final override fun releaseInterceptedContinuation(continuation: Continuation<*>) {
        val dispatched = continuation as DispatchedContinuation<*>
        dispatched.release()
    }
}
```

Through the `dispatch` method it throws a `Runnable` task around in whatever way the concrete
implementation defines, and that is how the coroutine's work gets executed.

If you look at the code of the Event Loop, one of the implementations that manage tasks:

```kotlin
public final override fun dispatch(context: CoroutineContext, block: Runnable) = enqueue(block)

public fun enqueue(task: Runnable) {
    if (enqueueImpl(task)) {
        // todo: we should unpark only when this delayed task became first in the queue
        unpark()
    } else {
        DefaultExecutor.enqueue(task)
    }
}
```

The `Dispatcher` really does nothing more than put the task into the Event Loop queue and call it
a day.

There is nothing else going on.

```kotlin
override fun processNextEvent(): Long {
    // unconfined events take priority
    if (processUnconfinedEvent()) return 0
    // queue all delayed tasks that are due to be executed
    val delayed = _delayed.value
    if (delayed != null && !delayed.isEmpty) {
        val now = nanoTime()
        while (true) {
            // make sure that moving from delayed to queue removes from delayed only after it is added to queue
            // to make sure that 'isEmpty' and `nextTime` that check both of them
            // do not transiently report that both delayed and queue are empty during move
            delayed.removeFirstIf {
                if (it.timeToExecute(now)) {
                    enqueueImpl(it)
                } else
                    false
            } ?: break // quit loop when nothing more to remove or enqueueImpl returns false on "isComplete"
        }
    }
    // then process one event from queue
    val task = dequeue()
    if (task != null) {
        task.run()
        return 0
    }
    return nextTime
}
```

Then the thread that manages the Event Loop dequeues the tasks one by one, pulls each one out and
runs it.

In other words, the `Dispatcher` has nothing to do with *how* a coroutine works — its only
responsibility is the distribution of tasks.

## So How Does a Coroutine Flow?

Pretty tough going, right?

Based on what we have learned so far, let's tidy this up one more time.

To make it easier to follow, let's keep going with a sample piece of code.

```kotlin
fun main() {
    println("Starting a coroutine block...")
    runBlocking {
        println(" Coroutine block started")
        launch {
            println("  1/ First coroutine start")
            delay(100)
            println("  1/ First coroutine end")
        }
        launch {
            println("  2/ Second coroutine start")
            delay(50)
            println("  2/ Second coroutine end")
        }
        println(" Two coroutines have been launched")
    }
    println("Back from the coroutine block")
}
```

This code creates an `EmptyCoroutineContext` via `runBlocking`, then creates and runs several
coroutines inside that scope.

As I mentioned last time, coroutines only *look* like they run at the same time. So what does the
output look like?

![Execution result](/assets/images/2026-10-06/coroutine-launch-result.png)
_Execution result_

Just as expected, we can see coroutine 1 and coroutine 2 starting at the same time.

What does that look like internally?

![How the coroutines flow](/assets/images/2026-10-06/coroutine-flow-diagram.png)
_The flow of execution_

Coroutine 1 is created, the default `Dispatcher` throws the task, and it is executed immediately.

The same goes for coroutine 2: it is created, the default `Dispatcher` throws the task, and it
runs immediately.

So the total elapsed time came out close to 100ms — the longest of the two delays!

But here a question comes up.

Coroutine 1 called `delay`, so how is coroutine 2 able to run right away?

The `Dispatcher` only threw the task somewhere — so how did it manage to work around the blocking
section?

I'll go deeper into how a coroutine really finds a suspension point, how it marks that point, and
how it knows to resume from there.

For that part, take a look at the post below 😄

> [\[Kotlin\] Coroutine - 6. Let's deep dive into suspend functions](https://huisam.tistory.com/entry/coroutine6)

## Wrapping Up

- `CoroutineScope` means the scope of a coroutine — the overall scope that shares the coroutine's lifecycle.
- `CoroutineContext` is the set of things that make up a coroutine.
- `Dispatcher` decides how the coroutine's tasks get distributed for execution.

## Reference

> [Kotlin Docs - Coroutine context and dispatchers](https://kotlinlang.org/docs/coroutine-context-and-dispatchers.html)

> [Understanding Kotlin Coroutines](https://silica.io/understanding-kotlin-coroutines/5/)
