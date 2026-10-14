---
layout: post
title: "JVM and Garbage Collection - G1GC vs ZGC"
date: 2026-10-14 20:00:00 +0900
categories: [Backend, Java]
tags: [java, jvm, garbage-collection, g1gc, zgc, heap, performance]
---

## Java Memory

If you write Java, this is the kind of basic-but-not-really-basic knowledge you have to get
through at some point 📝

### JVM

Explaining everything from scratch is not the point I want to make here, so I'll just touch on
the important bits.

The overall structure of the JVM looks like this.

![The overall structure of the JVM](/assets/images/2026-10-14/jvm-structure.png)
_JVM_

To be precise, I only want to talk about the JVM's **Heap**.

We've all been developing for a while now, so let me introduce a picture most of you will find
familiar.

![Heap layout before JDK 1.7](/assets/images/2026-10-14/heap-before-jdk7.png)
_Heap before JDK 1.7_

The picture above is the heap memory layout from before JDK 1.7.

- **Eden**: where most newly created objects live
- **S0, S1**: where the objects that survived one GC in the Eden area end up
- **Old Memory**: where the objects that keep surviving repeated GCs in the Young Generation go.
  An object moves here once it has been referenced enough times to reach the Age required to
  graduate into the Old area.
- **Perm**: where class/method meta information and static variables / constants are stored

A huge amount of the Garbage Collection material we know (the kind scattered all over the
internet 🚯) is written on top of exactly these assumptions.

But is that still true today?

![Heap layout after JVM 1.8](/assets/images/2026-10-14/heap-after-jdk8.png)
_After JVM 1.8_

Precisely speaking, the Perm area was replaced by **Metaspace**.

What else changed?

| Category | Perm | Metaspace |
| --- | --- | --- |
| Stored information | class meta / method meta / static variables, constants | class meta / method meta |
| Management point | heap tuning + a separate Perm area | dynamically adjusted in the native area |
| GC | Full GC | Full GC |
| Memory options | `-XX:PermSize` / `-XX:MaxPermSize` | `-XX:MetaspaceSize` / `-XX:MaxMetaspaceSize` |

The single most important point is that the Perm area moved out of the heap and into the
**native** area.

One of the biggest characteristics of the native area is that its size is not forced by the JVM —
it can make the fullest possible use of the memory resources available to the process.

So if you suspect a memory leak in code that drives a `ClassLoader`, that is because you never
set a maximum memory limit.

Anyway, I don't really want to talk about the JVM itself — I just wanted to say *this is what the
heap looks like*. So let me touch only on the parts worth touching.

Then how on earth does GC actually work?

## Garbage Collection

### What is Garbage Collection?

Put simply:

- it is the work of reclaiming memory that keeps piling up once an object becomes
  unreachable
- every thread except the one running the GC stops working = **stop the world**

So GC tuning, as we usually understand it, means reducing that stop-the-world time.

The heap area is broadly made up of two parts:

- **Young Generation**: the area where most objects get collected. When objects disappear from
  this area, a **Minor GC** happens.
- **Old Generation**: allocated larger than the Young area, but collected less often. This one is
  called a **Full GC**.

Because of that, a Full GC inevitably has a long stop-the-world time — the memory is large and
there is simply a lot to process.

There are many algorithms that exist to handle GC of the Old area differently.

- **Serial GC**: walks the heap from the front, keeps only what is alive (Sweep), and then
  compacts the objects so they sit contiguously. It is basically the Mark-Sweep-Compaction
  algorithm. Serial GC is the right fit when you have little memory and few CPU cores
  (single-threaded).
- **Parallel GC**: the multi-threaded version of Serial GC.
- **Parallel Old GC**: differs from Parallel GC in that it identifies objects through
  Mark-Summary-Compaction. The Summary step is the work of identifying live objects across the
  areas that the GC already went through.
- **Concurrent Mark & Sweep GC (CMS GC)**: unlike the other collectors, CMS GC does not perform
  compaction.
  - *Initial Mark*: find only the live objects closest to the class loader
  - *Concurrent Mark*: from the objects confirmed alive above, check the objects they reference
  - *Remark*: check the objects that were newly added or whose references were cut in the step
    above
  - *Concurrent Sweep*: clean up the garbage

## G1 (Garbage First) GC

I left G1GC without its own explanation above — because, honestly, today I came all this way to
talk about G1GC, the one most widely used, and about the new GC being built for the future 😃

### G1GC

G1GC works with a very different mechanism.

It's best to forget for a moment the Young-area and Old-area GC described above.

G1GC became the official GC algorithm from JDK 11, and it appeared to provide a solution suited
to large memory as hardware kept advancing.

With G1GC:

- the Eden, Survivor and Old areas mentioned earlier still exist, but they are **not fixed in
  size**
- the entire heap memory area is divided into chunks of a certain size called **Regions**
- depending on the state of a Region, that Region's role (Eden, Survivor, Old) changes
  dynamically
- a Region's size defaults to (total heap memory) / 2048

Drawn as a picture, that explanation probably looks like this.

![G1GC heap layout divided into regions](/assets/images/2026-10-14/g1gc-heap.png)
_G1GC Heap_

Oh — there are some new areas in there.

- **Humongous**: space for storing large objects that exceed 50% of the Region size
- **Available/Unused**: Regions that are not in use yet

G1GC has a Minor GC too. In that process the surviving objects are moved into a Survivor Region,
and the Eden area is returned to the pool as Available Regions.

On the other hand, G1GC has a process similar to a Full GC called the **Concurrent Cycle**, which
runs once the heap occupancy exceeds the value set by IHOP
(`InitiatingHeapOccupancyPercent`).

![The phases of a G1GC concurrent cycle](/assets/images/2026-10-14/g1gc-process.png)
_The G1GC process_

- **Initial Mark**: find the Survivor Regions referenced by objects living in Old Regions (STW)
- **Root Region Scan**: scan the Survivor objects found above
- **Concurrent Mark**: scan the whole heap, and exclude from the later phases any Region where no
  GC candidate object was found
- **Remark**: stop the application (STW) and finally identify the objects to exclude from
  collection
- **Cleanup**: stop the application (STW) and remove the unused objects in the Regions that hold
  the fewest live objects
- **Copy**: for Regions that were GC candidates but were not fully emptied during Cleanup, copy
  the surviving objects into new (Available/Unused) Regions, performing compaction

For Old areas holding very few live objects, it logs `[GC pause(mixed)]` and lets them be
collected when the Young GC runs.

### Tuning Points

Hmm 😮 — I understand how it works, but what exactly am I supposed to change?

Before changing anything, always turn on **performance testing + logging options** first.

Enabling logs with `-Xlog:gc*:gc.log` and sending them to a file would be a good move!

And the purpose of tuning should be to minimize the time GC takes.

- `-XX:InitiatingHeapOccupancyPercent`: adjusts the IHOP percentage (the lower threshold at which
  marking starts)
- `-XX:G1HeapRegionSize`: the size of a single Region (default is (max heap) / 2048)
- `-XX:G1ReservePercent=10`: reserve memory (as a percentage) always kept free to reduce the risk
  of space overflow
- `-XX:G1HeapWastePercent=10`: the percentage of heap space you are willing to waste

There are really a *lot* more than these. It's best to look up what you need when you need it.

But please never forget that GC tuning is the very last resort, after you have tried everything
else.

With JDK 11, G1GC is what you get as the default GC algorithm if you pass no particular option.

What's even more exciting is that the next GC is already being prepared alongside the JDK version
bumps.

## New Feature(...)

So which GC algorithm is being actively developed right now ❓

**ZGC**.

### ZGC

ZGC became production-ready right at JDK 15 — an algorithm for collecting garbage efficiently on
somewhat larger memory (8MB ~ 16TB).

As the developers put it, ZGC does not remove stop-the-world pauses entirely: the collector still
needs pauses when marking starts, when marking ends, and when relocation starts — but those
pauses are usually just a few milliseconds.

In other words, it was built to keep STW time as small as possible (under 10ms) on both small and
large heaps!

It really does take an STW only during the marking phases in order to cut that time down.

Its memory structure is quite similar to G1GC's.

![ZGC heap layout](/assets/images/2026-10-14/zgc-heap.png)
_ZGC Heap_

Pretty interesting, right?

You can see that each Region has a very simple structure.

The core of ZGC comes down to two major algorithms: **Colored Pointers** and **Load Barriers**.

![Colored pointers using bits of a 64-bit pointer for marking](/assets/images/2026-10-14/colored-pointers.png)
_Colored Pointers_

You can see that it uses the 64 bits of the pointer variable that points at an object to do the
marking.

- **Finalizable**: garbage objects referenced only through a finalizer
- **Remapped**: a mark used to decide whether an object has been relocated
- **Marked 1 / 0**: live objects

Because of this, ZGC can only be used on a 64-bit operating system.

![Load barriers updating references during concurrent relocation](/assets/images/2026-10-14/load-barriers.png)
_Load Barriers_

Next up is Load Barriers.

Unlike G1GC, ZGC relocates memory **without an STW** — based on the bits mentioned above!

While doing so, it checks the Remap Mark and the Relocation Set and updates the references and
marks accordingly.

So ZGC ends up following a flow like this:

- **Mark Start (STW)**: mark the objects pointed to by ZGC's roots
- **Concurrent Mark/Remap**: walk the object references and mark every object
- **Mark End (STW)**: mark the objects that newly arrived
- **Concurrent Prepare for Relocate**: find the areas to be relocated and put them in the
  Relocation Set
- **Relocate Start (STW)**: relocate and update all root references
- **Concurrent Relocate**: then relocate every object and fix up references using Load Barriers

The difference from G1GC is exactly this: the key is marking and managing objects through the
pointer itself!

According to the developers, the ultimate goal of ZGC is to keep each STW time under 10ms no
matter what heap memory size it is given.

### Performance Comparison

As you can tell from the explanation above, ZGC is a GC approach that suits large memory very
well.

So to gain a lot of performance from it, the bigger the memory the better, right?

![STW pause time comparison between ZGC and G1GC](/assets/images/2026-10-14/zgc-vs-g1gc-performance.jpg)
_ZGC vs G1GC pause times_

The test environment above measured performance on a 128G heap with an Intel Xeon E5-2690 2.9GHz,
16-core machine.

In the worst case, the difference in STW time compared to G1GC is nearly 1000x!

Maybe the day ZGC replaces G1GC isn't that far off 😄

## Wrapping Up

Hardware keeps advancing over time, and so does software.

Keeping an eye on it ✏️ and staying curious seems to matter.

## Reference

> [JVM에 대해 알아보자](https://iann.tistory.com/17)

> [Naver D2 - Garbage Collection](https://d2.naver.com/helloworld/1329)

> [JVM이란? JVM 메모리구조](https://coding-start.tistory.com/205)

> [Java의 GC는 어떻게 동작하나?](https://mirinae312.github.io/develop/2018/06/04/jvm_gc.html)

> [JVM Garbage Collection](https://renuevo.github.io/java/garbage-collection/)

> [Oracle - G1GC](https://www.oracle.com/technical-resources/articles/java/g1gc.html)

> [Getting started with Z Garbage Collector in Java 11](https://hub.packtpub.com/getting-started-with-z-garbage-collectorzgc-in-java-11-tutorial/)
