---
title: "Servo Internals"
date: 2018-09-15T23:44:50+02:00
draft: false
---

## Motivation

I recently started contributing to Mozilla's
[Servo](https://github.com/servo/servo), a new browser engine experiment,
eventually intended to be merged into Firefox.

I take a lot of notes as I walk through the code base (it's quite vast--at the
time of writing the Rust portions alone are 1.5M CLOC), and I thought I'd put
them online, primarily for myself as future reference, but also in hopes that it
may be useful for others starting out.

## Disclaimer

I'll try to keep the posts up-to-date as best I can, but it's conceivable that
some of the information may get out-of-date if some changes land that escape my
attention.

All that said, please take everything with a *massive* grain of salt--I'm merely
a hobbyist enjoying contributing to a project that I feel matters, but
ultimately the information described herein may not only be out-of-date, but
also wrong. Therefore the canonical source of information should always be
reading through the code and docs yourself (most of it is rather readable
and quite well documented!), and if all else fails, asking the core devs on the
#servo Mozilla IRC channel.

So I kindly ask you to treat this guide merely as a hint.

(This means that I'd appreciate your pointing out errors a great deal! Simply
open an issue or a pull request on this site's repo and I'll update it ASAP.)

## Table of contents

This is an in-progress series, entries will (hopefully) be constantly added and
updated.

<!--- Bootstrapping Servo-->
<!--- Creating an IFrame-->
- [Loading a URL](https://mandreyel.github.io/posts/servo-internals-load-url)
