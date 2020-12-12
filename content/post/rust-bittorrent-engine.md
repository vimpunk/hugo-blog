---
title: "Writing a BitTorrent engine in Rust"
date: 2020-12-12T21:39:04+02:00
draft: true
tags: [rust, bittorrent]
author: mandreyel
---

I am writing cratetorrent, a BitTorrent engine in Rust. This posts tells the
journey and insights gained.

<!--more-->

## Introduction

Growing up in Eastern Europe exposed me to torrent apps that to this day have a
big culture over there. I have always been curious how they worked, more so when
I got into programming.

Some years after, I thought, why not write one? I'd surely learn all
the details then, and some more. The result was a C++ engine, unfinished to this
day, that to my recollection worked some of the time, but mostly didn't.

Fast forward to 2020, I've since then made a switch to Rust and I was looking for
ways to level-up. A project would do. But which one? Finishing what I had
started sounded appealing, because I was already familiar with the domain, and
so I could focus entirely on Rust instead.

And thus was cratetorrent born. The name is a wordplay paying homage to the C++
[`libtorrent` library](https://github.com/arvidn/libtorrent). The code base and
its dev blog were the source of many lessons and "aha" moments. I suppose this
is a rather convoluted way of saying thanks.

## Introduction v2

Growing up, "torrenting" was a big thing around me. I was always curious how
they worked. So I wrote one. In C++. That didn't work out. Half-finished,
too unstable, not well tested. But more on that later.

Fast forward a few years. I got into Rust. I needed a familiar playground to
practice the language. I did what anyone would do in such a situation: I wrote
another torrent engine. It's torrent engine's all the way down.

Anyway, thus was cratetorrent born. The name is a wordplay on the C++
[`libtorrent` library](https://github.com/arvidn/libtorrent). Its code base and
dev blog were highly educational during my first attempt. This is my thanks.

## Torrent 101

So how do torrents work? It's all fairly simple, actually. At least on the
protocol level.

A brief overview of the BitTorrent V1 protocol follows. For those
familiar, feel free to skip to the next section.

### Who's in a torrent, anyway?

BitTorrent is a _mostly_ decentralized file-sharing protocol, it consists of
many symmetrical clients sharing content. Its advantage over downloading from
a single host is that the load is distributed among the _peers_ in the torrent
_swarm_, thereby increasing availability, scalability, and often download times,
too.

I say mostly decentralized, because in some cases it is necessary to contact
a central host that knows about the torrent in question and one that can also
give curious clients addresses of peers that have the torrent. These are called
_trackers_.[0] 

A torrent client initially contacts one or more trackers, gets some peers,
and then connects some of them, and downloads files.

TODO: insert pic

### Torrent is Lego

I trust you liked Lego as a child too, yes? Well, you'll like torrent too, as
downloading a torrent is all about asking your peers for _that very specific
piece you need to complete assembling your work_, so just like playing Lego with
your peers.

Let's try with more _Technical Accuracy™_.

A torrent archive may have one or more files. From the point of view of the wire
protocol they are all just one big continuous sequence of bytes.  Files are cut
up into equal sized _pieces_, usually some multiple of 16 KiB.  Pieces are
further cut up into 16 KiB _blocks_.[1]

TODO: insert pic

A tricky part here is that files are not padded and the last piece may thus be
smaller. Becuase of this pieces (and blocks) may not align with file boundaries:
when writing blocks to disk, the client has to correctly determine to which
files to write, potentially splitting some blocks across files. It's all really
quite painful when you're in there and implementing it.[2]

### The peer protocol

The meat of a torrent app.

- After two peers connect, they exchange handshakes[3] and tell each other which
  pieces they have.
- Then, one or both of them may tell the other that it can start to download
  from it.
- The peer determines whether the other has any pieces it itself doesn't have,
  and if so, picks such a piece and sends a request for a block in that
  piece.[4]
- The peer sends the block, the client saves it to disk.
- Repeat ad finem.

Is that it? This gets a "drastically oversimplified, but yes" for an answer.
A real implementation will be quite a bit more complex. Let's see how we can
improve it.

## Optimizations

(But no premature optimizations, pinky promise.)

### Download pipelining

The problem with the above approach of sequential requests is that it
doesn't utilize the connection's network link.

To do so, we try to estimate peer connection's [bandwidth-delay
product](https://en.wikipedia.org/wiki/Bandwidth-delay_product), for each peer
that the client has. This is the maximum amount of data that can be on the link
at any given time, i.e. the sent but not yet received bytes.

To get the best performance, we keep as many requests outstanding as would fill
the link's capacity. Hence requets pipelining.

A picture makes this explanation a lot more pleasant:

TODO: insert picture

### Slow start

The above suggests an interesting problem: what's the fastest way of arriving at
the link's capacity? Taking time to get to this optimum number costs the client
time.

It turns out that this is a solved problem and we just have to peek one layer
below in our conceptual network stack to find the answer.

When a TCP connection is set up, the protocol tries to find the right congestion
window size--a fancy way of saying "the number of bytes to send that doesn't choke
the remote host and everything else in between." The optimal size makes use of
the network capacity without overwhelming it. Our purposes are similar.

What TCP does is to set the congestion window size to some constant and for each
ACK (acknowledgement message) that it receives for segments it sends, it
increases the window size by one. So each time a volley of segments' ACKs are
received, the window is doubled, thereby quite aggressively ramping up the
window. The algorithm is called
[slow-start](https://en.wikipedia.org/wiki/TCP_congestion_control#Slow_start).

Something quite simmilar is implemented in cratetorrent. TCP stops growing the
window when the first timeout or dropped segment is detected. Cratetorrent
stops when the download rate isn't increasing much anymore.[5]

### End-game mode

I noticed that sometimes the last phase of a download got stutteringly slow.

This happens when the last pending pieces are picked up downloaded from slower
peers, which delays the completion of a download by a surprising amount.[6]

Similarly, this issue is also solved--mentioned in the spec, in fact. The last
pending pieces should be downloaded from all peers, on a "whoever sends it
first" basis, and the request to the slower peers are simply cancelled. This
wastes some data and bandwidth capacity, but saves us quite some time.

---

There are quite a few more such aspects but neither you or I have forever.
Let's move on.

## Architecture

Cratetorrent builds on [Tokio](https://github.com/tokio-rs/tokio), the de facto
async IO runtime in Rust. Each connection with a peer is spawned as
a [task](https://docs.rs/tokio/0.2.13/tokio/task) (essentially an application
level [green thread](https://en.wikipedia.org/wiki/Green_threads)), and so are
all other entities in the engine: the engine itself, torrents, and disk IO.

Since tasks may be run on separate threads by the runtime, some synchronization
is needed. For oft used entities traditional primitives, such as read-write
locks, were used, while commands sent between tasks used `mpsc`, or
multiple-producer single-consumer
[channels](https://docs.rs/tokio/0.2.16/tokio/sync/mpsc/).

This has worked quite well: the logically separate parts are neatly demarcated
at the task boundaries, while (mostly read-only) shared access to some objects
(e.g. shared information used by all peer sessions in the same torrent) ensured
good performance.

## How do I test this?

Was the first thing I asked myself before starting. The reason my younger self's
first stab at this fell apart is because I hadn't set up proper testing. I knew
better now.

Since I was planning to iterate in small steps, I knew I wouldn't have the full
feature set necessary to test cratetorrent against another cratetorrent instance
(requires ability to seed, or upload). Instead, I used existing torrent clients.

The details can be found in the [tests
directory](https://github.com/mandreyel/cratetorrent/tree/master/tests), but
here's the TL;DR:
- I used Docker to create a virtual LAN on my localhost in which I could spawn
  containers that acted as disparate hosts.
- This is great because it's easy to automate and reproduce.
- I took a well known torrent client, spawned some instances of it to act as
  seeds, and connected them with my cratetorrent client.

I set this up before writing any of the Rust code so that once I got rolling,
I could immediately try it out with a few messages. Once everything was set,
I could quickly move on to actually testing a full download of a torrent.

This worked wonderfully. It allowed me to focus on one feature at a time,
e.g. I added seeding quite late in the process. But with this approach I didn't
have to worry about that while first working on downloads.

## Result

The result is nothing to write home about (although arguably that's what I'm
doing now). but without any micro-optimizations, just sane architectural
decisions, the performance is quite good out of the gate. A download of Ubuntu
20.04 (~2.8 GB), which is a well seeded torrent, takes about 5 minutes, so about
9 MBps. This is what a speedtest shows my downlink capacity to be,

### Limitations

It only runs on Linux due to using Linux-only syscalls for fast file IO.[7] It
also doesn't support most features that a fully baked torrent client nowadays
has. It's just a toy project, after all. In the future, I might develop it into
something full fledged.

## A few thoughts on this small journey

Rust's strong aliasing guarantees do wonders in keeping sane such a relatively
complex tangle of moving parts. I still have slight PTSD episodes when I think
about getting segmentation faults while testing my C++ based attempt. It's been
years...

Admittedly I was _much_ less experienced at the time, so the fault doesn't
entirely lie in C++, and this is definitely not meant to incite flame war
(please). However, Rust makes writing this type of code so much easier and more
pleasant. But also a little restrictive, which is probably a good thing. And the
resulting architecture is entirely different from what I had in C++.

However, race conditions can still occur, just not data races. E.g. if you
structure your code in such a way that `await` yield points are followed by
another task that manipulates the same shared (but synchronized) data, a logic
race could occur that Rust doesn't (and cannot) prevent. Care must still be
taken.

TODO: good rust example

Then, there are some questions...

It is not entirely clear how to structure high-performance, highly concurrent
Tokio based software. I feel more advanced tutorials are needed in this space as
the Tokio docs don't really go into that much detail beyond basic usage.

E.g.  should we perfer `mpsc` or us `RWLock` fine? How many tasks to spawn?
Should we use
[`LocalSet`](https://docs.rs/tokio/0.2.16/tokio/task/struct.LocalSet.html) in
some places instead of regular tasks? The questions go on.

### `plans.next().await?`

I would like to investigate some of these questions by profiling and
benchmarking various solutions to hopefully arrive at answers backed by data.
I might also explore other areas of cratetorrent that could prove interesting.

Stay tuned.

---

[0]: Nowadays trackers are largely replaced by a _distributed
  hash-table_, or DHT, a decentralized data-store which in the case of BitTorrent,
  contains peers and the torrents that they have available. But even that needs
  to be bootstrapped on the first run.
[1]: And while the spec merely recommends this, in practice
  clients deal exclusively in these blocks and will even reject different sized
  ones altogether.
  This is presumably because internet speeds were much lower at the time
  BitTorrent was created some 20 years ago, and 16 KiB was probably a good
  choice. Chunking up pieces into smaller blocks enables downloading the piece
  concurrently from multiple peers--finishing the piece sooner. The reason
  this is important is because a finished piece can immediately be shared with
  other peers that don't yet have it, thereby increasing availability, a key
  feature of torrents.
[2]: The [BitTorrent V2](https://www.bittorrent.org/beps/bep_0052.html)
  addresses this and pads files. 20 years late but still welcome.
[3]: This is because TCP is an arbitrary byte stream, and so the first message
  must correspond to an expected value that can be verified.  
[4]: Usually peers pick the pieces that are the least available in the swarm,
  to--again--increase availability.
[5]: The idea is from libtorrent.
[6]: Really. With some tests the last few pieces took a staggering 30% of the
  overall download time!
[7]: [`pwritev`](https://linux.die.net/man/2/pwritev) and
  [`preadv`](https://linux.die.net/man/2/preadv). It would be quite trivial to
  feature gate these to Linux only and fallback to e.g. the std lib APIs for other
  platforms, but this is an MVP. I might do so later.
