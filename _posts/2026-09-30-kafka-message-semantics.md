---
layout: post
title: "Apache Kafka Message Delivery Semantics - At Most Once, At Least Once & Exactly Once"
date: 2026-09-30 19:00:00 +0900
categories: [Stream, Kafka]
tags: [kafka, message-semantics, exactly-once, idempotence, offset-commit]
---

## In Coming

Over the last two posts we took apart the Kafka Consumer and the Kafka Producer:

- [Apache Kafka Consumer - A Deep Dive into HeartBeat & Rebalancing](/posts/kafka-consumer)
- [Apache Kafka Producer - Partitioning, Retries & Idempotence](/posts/kafka-producer)

Once you have studied both halves, all sorts of questions start piling up — but the most basic one is probably this: *so how does a message actually get delivered, and what strategy is Kafka using to deliver it?*

So this time let's put the two halves together and look at the delivery strategies Kafka can give you. This is what people usually mean by **Kafka Message Delivery Semantics**.

## Message Delivery Semantics

What delivery strategies are there? Let's start by pinning down the vocabulary.

| Term | Description |
| --- | --- |
| No guarantee | Nothing about delivery is guaranteed. A message the Producer sent may be lost, processed once, or processed many times by the Consumer |
| At most once | Delivery is processed *at best* once. To avoid any chance of duplication, the message may end up not being delivered at all |
| At least once | Delivery is processed *at least* once. The Consumer may process the message once, or many times |
| Exactly once | Delivery is guaranteed to be processed *exactly* once |

If Kafka Streams was your first taste of Kafka, you might be thinking "wasn't Kafka exactly-once from the start?" — it is not.

To see why, you have to look at how the message is sent on the Producer side and on the Consumer side.

### Producer Message Semantics

Let's start with how the Producer sends a message.

![Kafka Producer](/assets/images/2026-09-30/producer.png)
_Kafka Producer_

The Producer hands the message off to the Kafka Broker, and there is also the question of how the offset gets written into the storage that holds it. The policies split apart depending on how those two things line up.

The diagram frames it in terms of offset storage, but strictly speaking what is going on is the **ack exchange between the Producer and the Broker**.

**At most once** writes to offset storage, but the message can be dropped on its way to the Broker.

**At least once** guarantees the hand-off to the Broker, but the dedupe bookkeeping in offset storage can be lost.

No guarantee we can skip — nothing to look at there. :)

So how does exactly once work?

![Kafka Producer Exactly Once](/assets/images/2026-09-30/producer-exactly-once.png)
_Kafka Producer Exactly Once_

Exactly once means guaranteeing those two actions — **delivering to the Broker** and **writing to offset storage** — happen **atomically**.

Which raises the obvious question: how do you actually *pick* one of these strategies?

| Strategy | How |
| --- | --- |
| At most once | Do not allow the Producer any retry strategy, and let it guarantee it delivers exactly one time.<br>— I have never actually operated Kafka with this strategy, so I can't say much about it |
| At least once | Set the Producer's `acks = all`.<br>`acks = all` is the option that checks whether the Leader propagated the topic data to its Followers properly |
| Exactly once | Set the Producer's `acks = all`.<br>Set `enable.idempotence = true`.<br>The idempotence setting sends a **ProducerID (PID)** to the Broker so that it can dedupe the incoming records |

For the Producer's `acks` and `idempotence` settings, see the [previous post](/posts/kafka-producer). :)

### Consumer Message Semantics

The Producer's delivery semantics alone are already plenty, right? Well — we are not done. The Consumer side is a bit harder.

Let me start with a picture to make it easier.

![Consumer message delivery semantics](/assets/images/2026-09-30/consumer-semantics.png)
_Consumer message delivery semantics_

The Consumer's flow is actually very simple:

1. The Consumer reads messages starting from the last offset it remembers
2. It passes the messages it read to the application, which **processes** them
3. When processing finishes, it **commits** the offset

One trip around that cycle is what we call the Consumer having consumed the message.

By default it follows the "hand the message to the application, *then* commit" strategy — which is **at least once**.

So how do you get to exactly once?

![Consumer Exactly Once](/assets/images/2026-09-30/consumer-exactly-once-idea.png)
_Consumer Exactly Once_

To give away the conclusion up front: the answer is to **guarantee idempotence at the application layer**.

Let me walk through why, step by step.

There are two ways for a Consumer to read messages and commit the offset.

| Property | Description |
| --- | --- |
| `enable.auto.commit = true` | Commits the offsets of the polled records on a fixed interval (`auto.commit.interval.ms`, default 5 seconds) |
| `enable.auto.commit = false` | The application commits manually |

With `auto.commit = true`, the commit happens on its own, which means you can lose messages like this:

![Message lost on processing failure](/assets/images/2026-09-30/message-lost-auto-commit.png)
_Message lost on processing failure_

Thanks to the auto-commit policy, if the application's processing gets delayed and then fails, the offset has already been committed but the business logic for that message never ran.

This is Kafka following **at most once**.

With `auto.commit = false`, the commit is manual, which means you can end up processing a message twice:

![Message processed twice when the commit fails](/assets/images/2026-09-30/message-duplicate-manual-commit.png)
_Message processed twice when the commit fails_

This one comes from running the application's business logic *first* and committing the offset afterwards.

The business logic succeeds, but committing the offset fails because of a network issue. Next time around, the Consumer reads from the same offset — so the business logic runs again for a message it already handled.

That is Kafka following **at least once**.

So whether the Consumer prioritizes the commit or prioritizes the processing, neither choice buys you exactly once.

If anything, prioritizing the commit needs a safety net like a two-phase commit, and because that leans on Kafka transactions it can cost you performance.

Which is why, in practice, this usually gets solved in the message-handling business logic itself.

![Consumer Exactly Once](/assets/images/2026-09-30/consumer-exactly-once.png)
_Consumer Exactly Once_

The approach: turn on the Consumer's asynchronous commit with `auto.commit = true`, and keep the record of **what has been consumed in a DB**.

Do that, and a processing failure in the application can be retried safely.

What you are really doing is making sure the application's processing stage cannot get in the way of the Kafka Consumer behaving exactly-once.

Kafka Streams can support exactly once as a feature, but `spring-kafka` generally does not. For how Kafka Streams pulls it off, the Confluent write-up below is worth a read: [Enabling Exactly-Once in Kafka Streams](https://www.confluent.io/blog/enabling-exactly-once-kafka-streams/).

## Wrapping Up

That was a lot of material, so here is the short version:

- The things that determine your message semantics have to be looked at from **both** sides — Producer *and* Consumer
- On default settings, Kafka is **at least once** on the Producer side and **at most once** on the Consumer side
- To get exactly once, you need `idempotence` and the `acks` option on the Producer, and a DB recording what the Consumer has consumed

If I have a typo in here, or I've misunderstood something, feel free to leave a comment any time!

Thanks for reading. :)

## References

- [Processing guarantees in Kafka](https://medium.com/@andy.bryant/processing-guarantees-in-kafka-12dd2e30be0e)
- [Exactly-once Semantics are Possible: Here's How Kafka Does it](https://www.confluent.io/blog/exactly-once-semantics-are-possible-heres-how-apache-kafka-does-it/)
- [Apache Kafka documentation - Semantics](https://kafka.apache.org/documentation/#semantics)
