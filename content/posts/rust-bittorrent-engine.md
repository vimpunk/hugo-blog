---
title: "Writing a Bittorrent engine in Rust"
date: 2020-12-26
draft: false
tags: [rust, bittorrent]
---

This post recounts the journey of writing
[cratetorrent](https://github.com/mandreyel/cratetorrent), interesting
optimizations, and some of the insights gained.

<!--more-->

## Prologue

Growing up, torrenting was a big thing around me. I was always curious how it
worked.

This curiosity only grew after I had gotten into programming and understood more
details. There is a piece of technology that is so effective yet simple, that,
without any marketing, it gained widespread adoption due to sheer technical
superiority. It just worked and people used it.

So why not write one? I tried, in C++. It was never finished and it's probably
better that way. Let's forget it.

Fast-forward a few years, I got into Rust and needed a familiar playground to
practice the language. I did what anyone in such a situation would do: I wrote
another torrent engine. It's torrent engines all the way back.

Thus was cratetorrent born. The name is a wordplay on the C++
[`libtorrent` library](https://github.com/arvidn/libtorrent). Its code and
blog were highly educational during my first attempt. This is my thanks.

## Torrent 101

So how _do_ torrents work?

A brief overview of the BitTorrent V1
protocol follows. For those familiar, feel free to skip to the [next
section](#key-optimizations).

### What is it?

BitTorrent is a _mostly_ decentralized file-sharing protocol: it consists of
potentially many symmetrical clients exchanging arbitrary data.

Its advantage over downloading from a single host is that the load is
distributed among all participants in the torrent, thereby increasing
availability, scalability, and often download speed, too.

It used to be highly popular, as everyone used it to share...Linux distros, yes,
and other _definitely legal content_. Nowadays it's still in use, but its
use cases are more subtle: e.g. Windows 10 uses BitTorrent, or something like
it, to [distribute
updates](https://lifehacker.com/windows-10-uses-your-bandwidth-to-distribute-updates-d-1721091469)
among its users.

### Who's in a torrent?

The first actor on the stage is the torrent _metainfo_ file. It contains basic
metadata about the torrent, most importantly its name, its files with their
paths and lengths, and its _trackers_. These files are usually hosted by
torrenting sites and this is what you download when starting a torrent.

So what are these trackers? While the download of the content itself is fully
decentralized, a client needs to know which other clients it can download from.
Such other clients in the torrent's _swarm_ are called _peers_. Peers that have
all the data are _seeds_, the rest are _leeches_. A bit of an uncomfortable
term.

Therefore at the beginning of a download a client asks trackers about
peers. Trackers are the only centralized part of the protocol.[^dht] Once done,
the client connects these peers and begins downloading data.

### Data representation

A torrent may have one or more files but from the point of view of the wire
protocol they are all just one big contiguous sequence of bytes.

This byte sequence is cut up into equal sized _pieces_, which are further cut up
into 16 KiB _blocks_. Peers exchange these blocks of data and use them to
reassemble the torrent's files.[^block_size]

A peer can only share the complete pieces it has. However, breaking up a piece
into blocks enables downloading it from multiple peers, potentially
completing it sooner. Once complete, the peer can immediately share it with
other peers, even if it does not have all pieces itself. This increases
availability, a key feature of the protocol.

A tricky part here is that files are not padded to align with piece boundaries.

![data representation](/images/cratetorrent-data-repr.svg)

This has two consequences:

- the last piece may be smaller than the rest,
- and pieces may not align with file boundaries, both shown above.

Therefore when writing blocks to disk, they may have to be split across several
files. The logic can get quite gnarly here if done optimally.[^file_padding]

### The peer protocol

- After the client connected the peer via TCP, they exchange handshakes.
- One or both tells the other that it can start requesting blocks.
- The client then requests a block from a piece it chose[^pick_piece], its peer sends it,
  and the client saves it.
- Repeat until finished.

That's about it, but perhaps surprising no one, a real world implementation will
be quite a bit more complex. Let's see some of the complications.

## Key optimizations

(But nothing premature, promise!)

### Download pipelining

A naive implementation might do what was outlined above: send requests
sequentially, one after the previous request was served. The problem with it is
that it doesn't utilize the connection's capacity.

To do so, we try to estimate a connection's [bandwidth-delay
product](https://en.wikipedia.org/wiki/Bandwidth-delay_product) for each peer
that the client is downloading from. This is the maximum amount of data that can
be on the link at any given time--that is, the sent but not yet received bytes.

So to get the best performance we keep as many requests outstanding as would
fill the link's capacity.

A picture makes this explanation a lot more pleasant:

![download pipelining benefits](/images/cratetorrent-request-pipeline.svg)

It's clearly visible that in the same amount of time, a lot more requests could
be fulfilled. This is the number one most important optimization, strongly
recommended by the spec itself.

Cratetorrent uses a running average for the download rate and a simplified model
of the BDP, by assuming the latency to be a constant 1 second, to get the
request queue size:

```rust
let request_queue_size = download_rate / BLOCK_LEN;
```

The 1 second value was chosen for simplicity, but it's a reasonable guess if we
take the link to mean the full request round-trip from one peer's disk to that
of another.

### Slow start

The above suggests an interesting problem: what's the fastest way of
arriving at the link's capacity? Taking time to get to this optimum number costs
time. No good.

It turns out that this is a solved problem. To find the answer we just have
to peek one layer below in the network stack: **TCP**.

When a TCP connection is set up, the protocol tries to find the right congestion
window size. This is a fancy way of saying "the number of bytes to send that
doesn't choke the remote host and everything else in between but still makes use
of the network capacity." Our purposes are similar.

This is roughly what TCP does:

1. At the start of the connection, set the congestion window size to some
   constant.
2. Send an equivalent number of segments to peer.
3. For each ACK (acknowledgement message) received, increase the window size by
   1.

Each time all ACKs are received for a volley of segments, the window size
doubles. This growth is exponential, yet the algorithm is confusingly called
[slow start](https://en.wikipedia.org/wiki/TCP_congestion_control#Slow_start)
(presumably named after the thing it tries to avoid).

TCP stops growing the window when the first timed out or dropped segment is
detected. This would be difficult to replicate in user-space, so cratetorrent
instead increases the request queue size every time a block is received, and
[stops](https://github.com/mandreyel/cratetorrent/blob/master/cratetorrent/src/peer/state.rs#L300-L316)
when the download rate isn't increasing much anymore.[^slow_start]

![download pipelining benefits](/images/cratetorrent-slow-start.svg)

With each served request, more requests are sent, and the connection is getting
closer to fully using the available bandwidth (the non-blue area is shrinking).

### Endgame mode

I noticed that sometimes the last phase of a download gets stagnant, barely
progressing from one block to the next.

This happens when the last pending pieces are downloaded from slow peers, which
can delay the completion of a download by a surprising amount.[^endgame]

Similarly, this issue is also solved--mentioned in the spec, in fact:

While normally each block is requested from a single peer, blocks in the last
pending pieces should be downloaded from all peers, on a "whoever sends it
first" basis. Once they arrive, requests to the slower peers are simply
cancelled. This wastes some bandwidth but saves quite a bit of time.

---

These were the most significant design choices in terms of how they affected
performance. There are a few more but neither you nor I have forever. So let's
move on and see how all this translates into Rust.

## Architecture

Cratetorrent employs asynchronous IO on the network side, and a thread-pool
backed blocking IO on the disk side. It uses
[Tokio](https://github.com/tokio-rs/tokio) for both, the de facto async IO
runtime in Rust.

The engine's main components are:

- The **engine** itself, which manages torrents and executes the library user's
  commands.
- One or more **torrents**, each corresponding to a single torrent
  upload/download. They manage their peers and trackers.
- Torrents have an arbitrary number of **peer sessions**, which represent
  connections with peers from start to finish. This entity implements the
  BitTorrent wire protocol and is as such on the lowest layer.
- **Disk IO** is handled by an entity of its own, for clarity and separation of
  concerns.

All of these are separate [tasks](https://docs.rs/tokio/0.2.13/tokio/task)
(essentially application level [green
threads](https://en.wikipedia.org/wiki/Green_threads)). Because tasks are
as good as separate threads from the point of view of the borrow-checker, shared
access is not permitted without synchronization. There are two ways to do that.

### Task event loop

Control flow between tasks is primarily implemented via asynchronous [_message
passing_](https://en.wikipedia.org/wiki/Message_passing), using
multiple-producer single-consumer
[_channels_](https://tokio.rs/tokio/tutorial/channels). Each task is
reactive: it has an _event loop_ and it reacts to internal events and messages
from other tasks.

Torrents and peer sessions perform a periodic "tick" (like the tick of a clock),
once a second currently, to update their internal state and broadcast messages.
This is when alerts (such as periodic download statistics or "download
complete") are sent to the library user for example.[^tick_freq]

A torrent's event loop might look like this:

```rust
loop {
    select! {
        // periodic tick
        _ = tick_timer.select_next_some() => {
            self.tick().await?;
        }
        // peers wanting to connect
        peer_conn_result = incoming.select_next_some() => {
            if let Ok(socket) = peer_conn_result {
                self.handle_incoming_peer(socket)?;
            }
        }
        // commands from other parts of the engine
        cmd = self.cmd_rx.select_next_some() => {
            self.handle_cmd(cmd).await?;
        }
    }
}
```

(`select!` is a macro that waits on all streams and returns the item produced by
the first ready stream. And streams are just types that eventually produce a
_stream_ of values over time.)

Another component in the engine might send it a message like so:

```rust
torrent_cmd_tx.send(torrent::Command::PieceCompletion(Ok(piece)))?;
```

And that's pretty much it. This approach cleanly separates concerns and makes it
a breeze to scale the code. But in rare cases it is not the most ergonomic way.

### Shared data: channels or locking?

While most tasks are concerned with their own data, peer sessions in a torrent
need to access or mutate a part of the torrent state.

For read-only shared data (which is the majority), this is a simple
[`Arc`](https://doc.rust-lang.org/std/sync/struct.Arc.html) away. But for
shared mutable access, this was not so clear when
I started: do I use
[locks](https://docs.rs/tokio/0.2.16/tokio/sync/struct.RwLock.html) or full
channel round-trips?

To be more concrete, the two entities that peer sessions need to interact with
all the time:

- **piece picker**: keeps track of what is already downloaded and is used by
  all sessions to choose which piece to download next.
- **piece downloads**: the pending downloads. It is used to
  continue existing downloads and to administer received blocks.

It would be possible to keep these in torrent and let peer sessions use
messages to manipulate them, but since they are used in many places, it is more
straightforward to use locks. Which one was the better overall solution, in
terms of performance, though? Is there a drastic difference between the two that
would make choosing one the obvious solution?

I did not trust my intuition so I set up a synthetic benchmark to simulate the
two approaches. While not exactly representing the real world, I wanted to
have a rough idea to help guide my decision.

It was simple: spawn the specified number of tasks, let each simulate
a "request" one block at a time, delay the task some amount of time while
"receiving" the block, and finally sending a notification to the main task for
administration. Then repeat until all pieces are "downloaded." (No actual network
IO took place, hence the quotes.)

The results:

- If the delay was set to 0, channels left locks in the dust. The difference was
  especially drastic as the number of tasks grew.
- But surprisingly, with as little as 10ms of a delay, the results were pretty
  much even, up until about 500 tasks.

After that, channels started to emerge victorious even if a delay was set. Thus
a takeaway here (and not just for Rust): if you need _very_ high concurrency,
message passing is the way to go.[^lock_contention]

However, I ended up going with the lock based solution, for a few reasons:

- It's not expected to have much more than a 100 peers per torrent. Most clients
  set a default of 50. So if this solution scales till around 500, I considered
  that good enough, for the MVP anyway.
- There is actually an additional not so trivial to simulate logic around
  downloads: timeouts and salvaging late blocks. It is outside the scope to
  explain, but it meant accessing the above data in other places that
  would have made a channels based solution more convoluted.

I'll go into more detail in a dedicated post as I feel this might be of
interest.

### Disk IO

I mentioned that reading from and writing to disk uses blocking IO. Why not
`tokio::fs` (which provides async versions of the standard lib equivalent)?
This requires a little explanation...

While I tried not to make excessive premature optimizations, a torrent client _is_
the type of application where performance matters: besides actually downloading
things, the second most important thing is that it does so _as fast as
possible_.

In line with this, I made two assumptions to drive my decisions, which I believe
are sensible:

- Many context switches (and syscalls) are expensive and have become even more
  so due to speculative execution mitigations as of late. Use batching where
  possible.
- Avoid copying block buffers, of which there could be many. Copying many 16 KiB
  buffers is an unnecessary cost.

Thus downloaded blocks of a piece are queued in a write buffer and are
only written to disk once the piece is complete. This happens using a single
syscall and without additional buffer copies, using _positional vectored IO_:
[`pwritev`](https://linux.die.net/man/2/pwritev).

This kernel API allows writing a list of byte buffers at a given position in the
file in one atomic operation.[^pwritev_atomicity] There is no need to seek, nor
is there one to write each block separately, or to coalesce buffers into a
single buffer.[^write_all_vectored]

An interesting discussion around this has evolved on
[reddit](https://www.reddit.com/r/rust/comments/kiah3q/i_wrote_cratetorrent_a_bittorrent_engine_in_rust/ggprwcd).

## How do I test this?

Was the first thing I asked myself before starting. I wasn't sure
how to do end-to-end integration and functional testing most easily.

The reason my younger self's first stab at this fell apart is because I hadn't
had set up proper testing. I knew better now.

Since I was planning to iterate in small steps, I knew I wouldn't have the full
feature set necessary to test cratetorrent against another cratetorrent instance
(requires basically all features present in the MVP). This is what I did:

- I used Docker to create a virtual LAN on my localhost in which I could spawn
  containers that acted as disparate hosts.
- This is great because it's easy to automate and reproduce.
- I took a well known torrent client (Transmission), spawned some instances of
  it to act as seeds, and connected them with my cratetorrent client.

I set this up before writing any of the Rust code. Once I got rolling,
actually testing exchanging handshakes, sending protocol messages, then a
partial download, and not long after a full download, were all effortless.

This has worked wonderfully. It allowed me to focus on one feature at a time
which resulted in rapid iteration. For example, I added seeding quite late in
the process yet I was able to test full downloads way before that.

Another benefit was that even though everything was local and mostly
reproducible, I was still testing against a real world client. This meant that
it ensured that my implementation was compatible with the rest of the ecosystem.

If you're curious how this was all setup, you can check it out
[here](https://github.com/mandreyel/cratetorrent/tree/master/tests).

## Result

It's nothing to write home about (although arguably that's exactly what I'm
doing), but without any micro-optimization, only a little profiling, and mostly
just sane architectural decisions, the performance is quite good out of the
gate.

A real-life download of Ubuntu 20.04 (~2.8 GB):

- with 40-50 peers;
- 20% CPU usage on the leech;
- downlink capacity is around 9 MBps;
- and so is the download rate: 9 MBps.

The above didn't tell us much. What about the **theoretical limit**?

- On localhost, using the virtual loopback device;
- with 1 cratetorrent seed and leech:
- 160-200 MBps on the first run and 270 MBps on the second with saturated caches.
- Caveat: 100% CPU usage on the seed.[^high_cpu]
- The same setup with Transmission (with rate limiting turned off), maxed out at
  35 MBps! That's 4-7x slower! But I'll do a proper showdown at some point. :)

## You can try it out!

Really! There is both a crate (or library), as well as a _very_ anemic CLI app.

However, there are some notable **limitations**:

- It only works on Linux at the moment, due to the above mentioned use of
  Linux-only syscalls.[^linux_only]
- It's missing many features that a fully baked torrent client would have.
- There are no facilities to _limit_ resource usage (e.g. backpressure or rate
  limiting), so it may not be suitable for slow systems.

Use `libtorrent` or something else if you want a battle tested solution.

## What's next?

There is a lot more to come: profiling and optimizing, discussing other
interesting aspects of both cratetorrent and tokio based apps in general, many
features, and more.

Also, I was asked on reddit whether the current design is
theoretically suitable for gigabit thruputs (125 MBps). As per the above, it
seems so! But it is unlikely in practice: finding a seed that can push these
numbers, ISP throttling, slow networking hardware, etc. But I'm confident I can
take this even further--as said, the code hasn't really been optimized. What
about _gigabyte_ thruputs?

Stay tuned.[^stay_tuned_how]

---

[^dht]:
    Nowadays trackers are largely replaced by a _distributed hash-table_, or
    DHT, a decentralized data-store which in the case of BitTorrent, contains
    peers and the torrents that they have available. But even that needs to be
    bootstrapped on the first run.

[^block_size]:
    It's interesting that the spec doesn't specify this 16 KiB size,
    it simply says that this tends to be the value used. So much so that in
    practice clients deal exclusively in these blocks and will probably reject
    requests for blocks with different sizes.
    I'm not quite sure why exactly 16
    KiB. With today's internet speeds, this value seems a little on the lower end.
    It was presumably chosen to match internet speeds at the time BitTorrent was
    created, some 20 years ago.

[^file_padding]:
    The [BitTorrent
    V2](https://www.bittorrent.org/beps/bep_0052.html) addresses this and pads
    files. 20 years late but still welcome.

[^pick_piece]:
    Usually peers pick the pieces that are the least available in the
    swarm, to--again--increase availability.

[^slow_start]: The idea is from libtorrent.
[^endgame]:
    Really. With some tests the last few pieces took a staggering 30% of
    the overall download time!

[^pwritev_atomicity]:
    However, the kernel APIs don't guarantee
    writing the full contents of all buffers to disk. Therefore most
    implementations, including cratetorrent, call `pwritev` repeatedly until all
    bytes are written.

[^linux_only]:
    It's fairly easy to feature-gate these to Linux and use a
    different fallback on other platforms. I didn't want to complicate this MVP,
    but I'll probably do this soon.

[^write_all_vectored]:
    There is also
    [`Write::write_all_vectored`](https://doc.rust-lang.org/std/io/trait.Write.html#tymethod.write),
    but it still requires a seek, and while cross-platform, on Windows it is
    actually just a shim over calling `Write::write` repeatedly, which is most
    probably worse than just copying the blocks into a single buffer and performing
    a single write (due to the cumulative cost of repeatedly context switching into
    kernel-space).

[^lock_contention]:
    We're talking differences of 150ms versus 25s for large
    number of tasks (in favor of channels). This is not so surprising, however:
    since the actual work done is very little, when there is no delay or the
    number of tasks is very high, most of the time among tasks is spent contending
    for locks. This doesn't scale because the more tasks there are, less CPU time
    is given to each as they all need to work on the same data. Even worse,
    with each mutation, CPUs have to synchronize their caches, further slowing
    down the program. Whereas with the channels based solution, the data is only
    ever mutated by one CPU, therefore no cache pollution occurs. And sending
    messages via channels is very cheap as, depending on the channel
    implementation, it most likely uses a lock-free queue, making it
    probably the only place that CPUs have to synchronize among each other.

[^stay_tuned_how]:
    E.g. you can add this blog to your RSS reader, but I'll also
    be posting to reddit.com/r/rust and news.ycombinator.com.

[^tick_freq]:
    Ticks occur once a second because stats don't need to be sent more
    frequently, and nothing else internally requires more frequent ticks. By the
    way, most clients update their UI once a second or even once every few
    seconds, so there is little need to do more work than that. But of course
    there may be other use cases, so this will likely be configurable in the
    future.

[^high_cpu]:
    Profiling points to the disk read routine, with `preadv` and
    `__memset_avgx2__erms` each taking up about half the CPU time there. I have a
    suspicion as to what this might be but I'll leave this for another time.
