---
title: "Rust BitTorrent engine"
date: 2020-03-29T21:39:04+02:00
draft: true
tags: [rust, bittorrent]
---

I am writing a BitTorrent engine in Rust, a crate called `cratetorrent`, and
  this is the beginning of a series walking through its research, design, and
  implementation.

<!--more-->

## Introduction

The name is a slight wordplay paying homage to the C++ [`libtorrent`
library](https://github.com/arvidn/libtorrent). I tried to write a BitTorrent
engine a few years back and libtorrent and its dev blog was the source of many
lessons and "aha" moments. I suppose this is a rather convoluted way of
saying thank you, as reading the source of libtorrent has in some way helped me
to be where I am today in my career.

The short-term goal of this project is primarily self-education, but later
I would like to turn cratetorrent into a very fast and full-featured torrent
  library that others can build their apps upon.

The crate also has a binary that will eventually be a torrent client for the
command line. Developing it alongside the library ensures that feedback for the
library API is quickly integrated.

<!--outline:-->
<!--- intro: what, why, and how-->
<!--- philosophy: well testable, design first, then test, and finally the-->
<!--implementation-->
<!--- approach, set out milestones-->
<!--- write about pre-milestone steps (step and design set up)-->
<!--- detail first milestone-->


## The approach

- Each feature is a separate iteration.
- Design solutions up front.
- Test driven.

#### Iteration
This comes from my [previous
attempt](https://github.com/mandreyel/tide) of writing a torrent engine where I
tried to incorporate nearly all the features of a torrent client at the same
time. Needless to say that this resulted in a mess.
So now each iteration focuses on one specific, well-defined target, aggressively
cutting down scope, so that development can be highly focused on just one goal
at a time.

#### Designing up front
Designing first (using design docs) comes as I have found that thinking (about
the larger picture) while coding doesn't work so well (for me), and having to
spell out one's ideas often leads to better solutions than an ad-hoc approach
would. Catching bugs early, so to speak.

#### Test driven
Then, the second step after having come up with a design is to devise a way to
reproducibly test the solution. This is not strictly about TDD or what framework
to use but that testability should be a high priority from the start, as I have
come to believe that it is the only sane way of ensuring that a system works as
intended.

#### Implementation
And only after this comes the implementation, which should mostly just be
translating the design to code. Of course the world is not an ideal place, so in
just my brief stint with this project I've already found that things don't
always work in code as devised in the design (especially when the borrow checker
thinks otherwise of one's plans).


## Milestones

These are the initial milestones that guide the development:

1. Perform a single in-memory download of a file with a single peer connection
   if given the address of a seed and the path to the torrent metainfo.
2. Extend 1. with actually saving the downloaded file to disk after
   verification.
3. Download a directory of files using a single peer connection.
4. Download a torrent using multiple connections.
5. Optimize download performance to use self-adjusting optimal request queue
   sizes and slow start mode for ramping up download throughput.
6. Seed a torrent.
7. Optimize disk IO performance by introducing the concept of backpressure
   between the network IO and disk IO, in both ways (i.e. for both seeds and
   downloads), write buffers, async hashing and file IO.


## Reproducible integration tests

Before beginning, I wanted to come up with how to test something as
non-deterministic as a torrent run. Doing purely unit testing of each component
would not be enough to test that the whole works.

My recent experience of working with Dockerized Rust microservices has given me
inspiration to test various torrenting scenarios within local Docker networks,
where each container would act as a separate peer in the torrent swarm.

Another factor to consider is that given the milestones, cratetorrent won't be
able to seed for quite some time, so it is not possible to test cratetorrent
against itself. This gave the idea of using existing clients (such as
Transmission or libtorrent) to test against.

#### Implications

1. Cratetorrent can be tested against popular existing clients from the get go,
   ensuring compatibility with the ecosystem.
2. It doesn't have to have full functionality to test it, meaning that just
   testing peer handshakes or other individual messages is possible with this
   approach (and has in fact been done).
3. The combination of reusing existing clients and Docker networks means that
   there are endless ways of testing all sorts of scenarios and edge cases, and
   each test case can define a relevant scenario in a self-contained manner.
4. Most importantly, the entire torrent swarm is controlled by the test runner,
   so tests can be reproduced in an almost* deterministic fashion. This is huge.

\* Almost, because we can't control the finer working of external torrent
clients, e.g. when a seed would start allowing us to download, but it is a
good enough approach.

Note that all of this assumes that cratetorrent directly connects to these
peers, as I haven't incorporated trackers or DHT into this approach, but I'm
sure it is possible to set up a tracker as its own container. Tracker and DHT
support is a far later step in the development, though.

#### The solution

The rough idea is to have a [Transmission
container](https://hub.docker.com/r/linuxserver/transmission/) that acts as the
seed, a pre-generated random file with its associated [torrent metainfo
file](https://en.wikipedia.org/wiki/Torrent_file), and a shell script for each
test case that sets up the seed, runs cratetorrent against it, and asserts that
the file has been downloaded. Since for now only downloading is desired, this is
it, but later more nuanced tests will most likely be added.

If you're curious how all of this is set up, you can check the integration
tests folder and its design doc
[here](https://github.com/mandreyel/cratetorrent/tree/master/tests).

## Design outline

Since the design is well
[documented](https://github.com/mandreyel/cratetorrent/blob/master/DESIGN.md),
I'd like to focus on my thoughts and experience coming up with it.

Realization: bittorrent peer protocol is mostly reactive: even if we're
downloading, beyond initiating the connection, we wait to be unchoked, then we
maek requests, then we wait for blocks, etc. Seeds are completely reactive: they
wait for a connection to be opened, unchoke the peer (this is determined by the
torrent, not the session itself), and then send blocks to requests and not doing
anything else. This means that the peer session loop can be based on reading
from the socket stream (there will be other events that drive the loop, but this
is the primary one).
