---
layout: post
title: "How Does Spring WebFlux Support Kotlin Coroutines? (feat. Context)"
date: 2026-09-28 20:00:00 +0900
categories: [Backend, Spring]
tags: [webflux, coroutine, kotlin, spring, reactor, context]
---

## In Coming

We have covered the basic concepts of coroutines before.

Now it is time to take that coroutine knowledge and connect it to Spring WebFlux.

In this post I want to walk through the code and find the exact points where WebFlux hooks coroutines in.

If you are not yet comfortable with coroutines, the post below is a good place to start.

> [\[Kotlin\] Coroutine - 2. CoroutineScope & Context & Dispatcher](https://huisam.tistory.com/entry/coroutine2)

## Spring WebFlux

Spring WebFlux is built on Reactor's philosophy, and its goal is to combine that with Spring's own technology to provide an interface for asynchronous servers.

> [Spring Framework - WebFlux Overview](https://docs.spring.io/spring-framework/reference/web/webflux/new-framework.html)

Because of that, every piece of asynchronous processing is driven through Reactor's `Mono` / `Flux` interfaces.

The consequence is that to build and develop an asynchronous server, you had to learn the fairly complicated `Mono` / `Flux` interfaces, which are themselves built on the Observer pattern at the root of Reactor.

For the many Spring developers who were used to MVC, that became a big hurdle and a real obstacle.

Especially for a newcomer coming from MVC, picking up Reactor for the first time took a lot of time and effort 😭

![Reactor marble diagram](/assets/images/2026-09-28/reactor-marble.png)
_Can you tell at a glance how this chain of interfaces unfolds over time?_

Over time, though, Kotlin — a JVM-based language — arrived and brought an asynchronous interface called coroutines. Since then we have been seeing moves in Spring to combine Reactor with coroutines and offer an asynchronous server built on the coroutine philosophy.

In particular, from Spring Boot 3.x (= Spring Core 6.x) onward, there is even a `CoWebFilter` interface.

```kotlin
abstract class CoWebFilter : WebFilter {

	final override fun filter(exchange: ServerWebExchange, chain: WebFilterChain): Mono<Void> {
		return mono(Dispatchers.Unconfined) {
			filter(exchange, object : CoWebFilterChain {
				override suspend fun filter(exchange: ServerWebExchange) {
					return chain.filter(exchange).cast(Unit.javaClass).awaitSingleOrNull() ?: Unit
				}
			})}.then()
	}

	protected abstract suspend fun filter(exchange: ServerWebExchange, chain: CoWebFilterChain)

}

interface CoWebFilterChain {

	suspend fun filter(exchange: ServerWebExchange)

}
```

On top of that, Spring Boot already manages the version of Kotlin coroutines officially, as part of its own dependency management.

![Spring Boot managed coroutine version](/assets/images/2026-09-28/spring-boot-coroutine-version.png)

> [Spring Boot - Dependency Versions](https://docs.spring.io/spring-boot/docs/current/reference/html/dependency-versions.html)

Given all of this, it is fair to say Spring is putting real effort into integrating Kotlin's libraries.

So in the end, if you are already a developer who is fluent in Kotlin, I do not think there is much reason to learn Reactor's philosophy just to adopt an asynchronous server.

With that in mind, let's get into how WebFlux actually integrates coroutines.

## Where Exactly Do WebFlux and Coroutines Meet?

Let's find out together with an example controller.

```kotlin
@RestController
@RequestMapping("/api/v1/coroutine")
class CoroutineController {
    @GetMapping("/hello")
    suspend fun hello(
        @RequestParam(required = false) param: String?
    ): String {
        return "Hello client: ${param ?: "default"}"
    }
}
```

This is a simple controller that declares a `suspend` function so it can take API requests.

In WebFlux, an HTTP request flows in this order:

1. `org.springframework.web.server.WebFilter`
2. `org.springframework.web.reactive.DispatcherHandler`
3. `org.springframework.web.reactive.HandlerAdapter`

Let's take a look at the last stage of the request, `RequestMappingHandlerAdapter`, which is an implementation of `HandlerAdapter`.

![RequestMappingHandlerAdapter](/assets/images/2026-09-28/request-mapping-handler-adapter.png)

Based on the coroutine handler it received from the `DispatcherHandler`, it fetches the `invocableMethod` and runs it.

If you follow the `invoke` method down, you run into the function below.

![Checking for a suspending function](/assets/images/2026-09-28/invoke-suspending-check.png)
_Found it!! Coroutine_

It checks whether the invoke target method is a `suspend` function, and if it is, it calls a separate invoke method.

If you decompile a `suspend` function, you will see that a `Continuation` object gets passed as the last parameter of the function, which is how each call site declares its suspension points.

Follow `invokeSuspendingFunction` further and you eventually reach the code below.

This is the final join point we were looking for!

![Mono to coroutine conversion](/assets/images/2026-09-28/mono-to-coroutine.png)

The heart of it is this code, where `Mono` is converted into a coroutine.

```java
Mono<Object> mono = MonoKt.mono(context, (scope, continuation) ->
    KCallables.callSuspend(function, getSuspendedFunctionArgs(method, target, args), continuation))
        .filter(result -> !Objects.equals(result, Unit.INSTANCE))
        .onErrorMap(InvocationTargetException.class, InvocationTargetException::getTargetException);
```

In other words, this is what lets you move from a `Mono` / `Flux` based interface over to a coroutine interface.

```kotlin
public fun <T> mono(
    context: CoroutineContext = EmptyCoroutineContext,
    block: suspend CoroutineScope.() -> T?
): Mono<T> {
    require(context[Job] === null) { "Mono context cannot contain job in it." +
            "Its lifecycle should be managed via Disposable handle. Had $context" }
    return monoInternal(GlobalScope, context, block)
}

private fun <T> monoInternal(
    scope: CoroutineScope, // support for legacy mono in scope
    context: CoroutineContext,
    block: suspend CoroutineScope.() -> T?
): Mono<T> = Mono.create { sink ->
    val reactorContext = context.extendReactorContext(sink.currentContext())
    val newContext = scope.newCoroutineContext(context + reactorContext)
    val coroutine = MonoCoroutine(newContext, sink)
    sink.onDispose(coroutine)
    coroutine.start(CoroutineStart.DEFAULT, coroutine, block)
}

/**
 * Updates the Reactor context in this [CoroutineContext], adding (or possibly replacing) some values.
 */
internal fun CoroutineContext.extendReactorContext(extensions: ContextView): CoroutineContext =
    (this[ReactorContext]?.context?.putAll(extensions) ?: extensions).asCoroutineContext()
```

It even converts the `Context` managed by Reactor into a `CoroutineContext` so it can be stored there.

Which means the objects managed on the Reactor side can be converted into objects on the coroutine side and carried over.

All the secrets are out.

We now understand the principle behind how an HTTP request comes in through the `Mono` / `Flux` based Reactor interface and ends up on a coroutine-based interface.

So shall we check one more time that the `Context` I mentioned at the end really does get carried across?

## Passing Data from Reactor Context to Coroutine Context

First, let's create a custom `WebFilter` that produces some context data on the Reactor side.

```kotlin
@Component
class ContextFilter : WebFilter {
    override fun filter(exchange: ServerWebExchange, chain: WebFilterChain): Mono<Void> {
        return chain.filter(exchange)
            .contextWrite { it.put("key", "test value") }
    }
}
```

Before running the filter chain, this creates and sets a key-value pair on the `ReactorContext` object.

Now, past all the conversion steps above, let's write code in the `RestController` that reaches the `CoroutineContext`.

```kotlin
import kotlinx.coroutines.reactor.ReactorContext

@RestController
@RequestMapping("/api/v1/coroutine")
class CoroutineController {
    @GetMapping("/hello")
    suspend fun hello(
        @RequestParam(required = false) param: String?
    ): String {
        coroutineContext[ReactorContext]?.context
        return "Hello client: ${param ?: "default"}"
    }
}
```

`ReactorContext` showing up out of nowhere may feel a bit random.

But the `ReactorContext` in the code above is a `CoroutineContext` that lives on the coroutine side.

```kotlin
public class ReactorContext(public val context: Context) : AbstractCoroutineContextElement(ReactorContext) {

    // `Context.of` is zero-cost if the argument is a `Context`
    public constructor(contextView: ContextView): this(Context.of(contextView))

    public companion object Key : CoroutineContext.Key<ReactorContext>

    override fun toString(): String = context.toString()
}
```

A `CoroutineContext` lets you reach each individual `CoroutineContext` by its `Key`.

In particular, unless you declare and use an independent `CoroutineContext`, the `CoroutineContext` being managed keeps propagating.

Alright, let's set a breakpoint and take a closer look.

![ReactorContext inside coroutineContext](/assets/images/2026-09-28/combined-context-debug.png)
_ReactorContext is held inside coroutineContext as a CombinedContext!!_

We could see that the key and value of the `reactor.util.context.Context` we set earlier in the `WebFilter` made it in nicely on the `CoroutineContext` side.

At this point, developers coming from MVC-based synchronous servers might have a question.

Why does an asynchronous server pass data on an object (`Context`) basis rather than on a thread basis?

The flow of the asynchronous model is about not pinning a thread and having it wait when there is idle time, but instead moving back and forth across multiple threads so that system resources are used to the fullest.

This connects to the concept of concurrency as well. For concurrency, take a look at the post below!

> [\[Kotlin\] Coroutine - 1. What is concurrency in coroutines?](https://huisam.tistory.com/entry/coroutine1)

This applies to asynchronous servers as a common mechanism.

If you are going to run an asynchronous server, it is very important to step outside of the fixed-thread way of thinking.

## Wrapping Up

So we looked at how Spring WebFlux provides a coroutine-based interface.

The Spring side is doing real development work to provide coroutine interfaces, and the technology keeps moving forward.

If you want to run an asynchronous server, how about gradually taking on coroutine-based Spring WebFlux?

## Reference

> [Spring Framework - WebFlux Overview](https://docs.spring.io/spring-framework/reference/web/webflux/new-framework.html)

> [Spring Boot - Dependency Versions](https://docs.spring.io/spring-boot/docs/current/reference/html/dependency-versions.html)

> [kotlinx.coroutines - Reactor integration](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-reactor/)
