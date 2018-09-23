---
title: "Servo Internals: Loading Pages"
date: 2018-09-15T23:47:55+02:00
draft: false
tags: [rust, servo]
author: mandreyel
---

This blog post is part of a
[series](/post/servo-internals/) I'm doing on Servo.
It's a deep dive into how Servo loads a page given a URL.
Please note, though, that it is still heavily work-in-progress. Some details may
be missing or incorrect.

<!--more-->

Also, I'm not going to give a full explanation of all components involved in
this blog post (such as `Constellation`, `Pipeline`, `ScriptThread`,`Compostior`
etc), so it's best to read [the ofificial design
note](https://github.com/servo/servo/wiki/Design) to see the bigger picture and
know what the details to follow are referring to.

## Entry points

There are currently four ways in which a URL may be loaded:

- the first time the browser is opened (when a new top-level browsing context is
  created);
- when the user clicks on a link or a script navigates the page (both are
  handled by the script thread);
- when the user types a URL (this is handled by the compositor);
- and finally the WebDriver can also initiate URL loads.

What all four have in common is that they're routed through the `Constellation`,
which orchestrates most operations in Servo.

However, each case boils down to one of two execution paths, which eventually
coalesce. Therefore I'm only going to cover these two cases, and abstract away
the minor differences.

### I. New top-level browsing context

Let's examine the first case, when a page is loaded for the first time (that is,
no browsing context exists), up until the point when the `Pipeline` for this
page is spawned.

The compositor sends the constellation a `CompositorMsg::NewBrowser` message,
which includes the URL and the ID for the to-be-created top-level browsing
context. This message is handled by `Constellation` with
[`handle_new_top_level_browsing_context`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L1632),
which sets up fields like the window size, the `LoadData` instance (which
besides the URL includes other metadata, like the HTTP headers, data, referrer
policy, referrer URL, and others), the `PipelineId` for the `Pipeline` of this
page, among others.  Then, it proceeds to create this pipeline by calling
`Constellation::new_pipeline` and also creates a `SessionHistoryChange` with
`Constellation::add_pending_change`.  But before delving into these two
functions, let's first examine the other major case that leads to calling the
same two functions.


### II. {FromScriptMsg, FromCompositor, WebDriverCommandMsg}::LoadUrl

In the second case--where either a typed URL, a click on a link (either by user
or some script), or a WebDriver command initiates a page load--is all handled by
calling
[`Constellation::load_url`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L2035)
(though in the case of WebDriver there are a few extra steps preceding this, but
they are irrelevant for understanding the larger picture).

#### The browsing context must exist

One very important distinction from the previous case is that `load_url` is
*always* invoked in an existing browsing context. However, you'll find that no
hard asserts are made, as it is preferred not to panic in `Constellation` and
instead issue a `warn!` message and return early from the method.

There are two further sub-cases within this method. In the first case, the
pipeline that initiated the load is located in an iframe (which is a nested
browsing context), or it's in a top-level browsing context (i.e. a window or
tab).

#### a) Loading a URL in an IFrame

In the first case, the constellation sends a `ConstellationControlMsg::Navigate`
message to the event loop of the pipeline that encapsulates this iframe (that
is, it is the iframe's browsing context's parent, as reflected by
`BrowsingContext::parent_pipeline_id`). This is handled by
[`ScriptThread::handle_navigate`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L2897),
which first looks for the iframe this load targets among
`ScriptThread::documents`, where all documents handled by this `ScriptThread`
are stored, and calls
[`navigate_or_reload_child_browsing_context`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/htmliframeelement.rs#L103)
on the `HTMLIFrameElement` instance. 

This method is invoked with the argument `NavigationType::Regular`. This is
important because there are two cases when loading a page in an iframe: the
initial `about:blank` load, which occurs when first constructing the iframe, and
when the iframe already exists and a "normal" page is being loaded. I'm not
going to examine the first case for now as this is involved enough to deserve
its own post and the point of this one is to examine "normal" page loads. So
this method, after setting up some data, sends a
`ScriptMsg::ScriptLoadedURLInIFrame` to `Constellation`.

This in turn is handled by
[`Constellation::handle_script_loaded_url_in_iframe_msg`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L1755),
which spawns a new `Pipeline` for the iframe's browsing context with
`Constellation::new_pipeline`, inheriting the properties (such as private
browsing mode, visibility, and others from the existing browsing context), and
as above, a `SessionHistoryChange` is created via
`Constellation::add_pending_change`.

It's perhaps important to point out that at this point the page the URL is
referring to isn't actually loaded, as perhaps the "loaded URL" names may
suggest. Instead, the load is merely *initiated*. Perhaps
`ScriptInitiatedIFrameURLLoad` and `handle_script_iframe_url_load_start` would
be less ambiguous names, but I'm not sure.

#### b) Loading a URL in a top-level browsing context

In the second case, the code first makes sure that there is no other pending
change for this browsing context. This is why trying to click on a link when
a page is already loading, the browser stubbornly ignores it and sticks to
loading the first page you clicked on. The load is also disregarded if the
pipeline is inactive.

A document (or from `Constellation`'s point of view, the `Pipeline`) can be in
three states: inactive, active, and fully active. This is explained in the
[living
standard](https://html.spec.whatwg.org/multipage/browsers.html#fully-active]).

TODO replace?

Finally, a new `Pipeline` is constructed with `Constellation::new_pipeline` and
a `SessionHistoryChange` is created with `Constellation::add_pending_change`,
the exact same steps in which the previous cases conclude.

## Execution paths coalesce

We arrive at the point where all the paths from various starting points join:
creating the `Pipeline` and `SessionHistoryChange` objects. All three functions
(`handle_new_top_level_browsing_context`,
`handle_script_loaded_url_in_iframe_msg`, and `load_url`) conclude in these two
steps.

The
[`new_pipeline`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L677)
method contains steps to spawn a new `Pipeline`, whose logic mostly consists of
choosing an existing `EventLoop` (which is basically an `IpcSender` to a
`Pipeline`'s `ScriptThread`) if this load is not sandboxed and has an opener or
parent `Pipeline`, and is either an `about:blank` load or the URL for the new
page shares the same host with an existing event loop.  Otherwise this event
loop will be `None` if none of these conditions are fulfilled.

Then,
[`Pipeline::spawn`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/pipeline.rs#L184)
is invoked with this optional `EventLoop`, many fields from `Constellation`, and
a bunch of load specific arguments passed to `new_pipeline` (like the browsing
context and pipeline IDs, whether the page was loaded in private browsing mode,
the `LoadData`, and others--best to look at the relevant code for details). More
details follow in a bit.

In each of the two cases,
[`Constellation::add_pending_change`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L858)
is called to add a `SessionHistoryChange` object to the
[`Constellation::pending_changes`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L290)
hash map, which is used to later retrieve information about this load when the
`Constellation::pending_changes` document becomes active.  This is necessary
because a page load is asynchronous and we need a way to maintain state until a
message from script thread indicating traversal maturation is received. Among
others, this object holds a
[`NewBrowsingContextInfo`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/browsingcontext.rs#L17)
field wrapped in an `Option`, which is used to indicate that the pending change
introduces a new browsing context (used in the case of creating a new top-level
browsing context or new iframes, which is not covered here), or `None` if the
page load was kicked off in an existing browsing context.

### Pipeline

A
[`Pipeline`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/pipeline.rs#L51)
is not in itself an entity that really does anything. Instead, it is used to
hold everything that's needed to produce a web page and run its JavaScript event
loop. More broadly speaking, it acts as a document's frontend for
`Constellation`.

Each `Pipeline` has an event loop and a layout thread. Multiple `Pipeline`s may
share the same event loop (`ScriptThread`) if their document shares the same
host, so as to enable them to become same-origin via `document.domain` (though
there is ongoing discussion on whether this is the desired behaviour in
[#21206](https://github.com/servo/servo/issues/21206)), but in all cases each
`Pipeline` has its own layout thread, responsible for rendering the page.

#### Spawning a Pipeline

If `Pipeline::spawn` was called with `Some(event_loop)`, it sends a message to
this event loop requesting to attach to it a new `LayoutThread` associated with
the new `Pipeline`, and kicks off the page load.
If this argument is `None`, and depending on whether multiprocess is enabled,
the pipeline is spawned as such, or `UnprivilegedPipelineContent::start_all` is
called, which starts the layout and script threads (with `LayoutThread::create`
and `ScriptThread::create`, respectively). TODO expand on multiprocess

[`ScriptThread::create`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L628-L631)
spawns a new thread on which the event loop will be run.  But before starting
the event loop,
[`ScriptThread::pre_page_load`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L3012)
is invoked, which sets up the request and sends a
`ScriptMsg::InitiateNavigateRequest` to `Constellation`.

This then is handled by
[`Constellation::handle_navigate_request`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L1735),
which sets ups a `NetworkListener` and invokes
[`initiate_fetch`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/network_listener.rs#L46)
on it. Confusingly, there are two classes with the same name, but this the one
found inside the `constellation` folder.

### Fetch

`Constellation` uses its `mspc` channel pairs, [`network_listener_sender` and
`network_listener_receiver`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L189-L192),
to communicate with the asynchronous fetch operation.
`NetworkListener::initiate_fetch` is passed `network_listener_sender`, which it
routes through an IPC router. I'm not 100% sure but I believe this is because
the resource thread may be running in another process, and therefore we need a
uniform way to send messages between threads and/or processes, and as such the
IPC router is used to handle this.

TODO could a `CoreResourceMsg::FetchRedirect` msg be sent as well in the case of
`load_url`?

Then, `NetworkListener::initiate_fetch` sends to the public resource thread
(responsible for abstracting away IO operations) a `CoreResourceMsg::Fetch`,
with the request data and the IPC sender (routed to
`Constellation::network_listener_receiver`). This message is processed by
`CoreResourceManager::fetch` which spawns *yet another thread* and calls
[`fetch/methods.rs:fetch`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/net/fetch/methods.rs#L86).

All of this is rather involved with lots of details--and at the time of writing
this, unfinished--, so I'm skipping a lot of it so as not to get swamped by the
minutiae. You can, however, read up all the details of a fetch operation in the
[living standard](https://fetch.spec.whatwg.org/). For the purposes of this post
the most interesting step is the `scheme_fetch` function, which depending on the
URL scheme ('data', 'http', 'about:blank', 'file' etc) launches different fetch
operations.

One thing worth expounding on that had initially confused me is that the
`IpcSender` passed to the resource thread and then to `fetch/methods.rs:fetch`
is subsequently treated as a type implementing the
[`FetchTaskTarget`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/net_traits/lib.rs#L162)
and `Send` traits.

`FetchTaskTarget` defines the following methods: `process_response`,
`process_response_eof`, `process_request_body`, and `process_request_eof`.
`IpcSender` is `Send` by default (meaning it's safe to be sent across threads),
but `FetchTaskTarget` is
[implemented](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/net_traits/lib.rs#L212)
for `IpcSender<FetchResponseMsg>` in `net_traits/lib.rs`. This is how the fetch
  responses are communicated to `Constellation`.

Back to fetch, the scheme fetch function returns a `Response` instance, which is
then passed to one of `FetchTaskTarget` sender's `process_response`,
`process_response_eof`, `process_request_body`, or `process_request_eof`
methods. Each method sends a `FetchResponseMsg` message to the `Constellation`,
which without any processing at all forwards it to `ScriptThread` wrapped in a
`ConstellationControlMsg::NavigationResponse` with arguments of types
`PipelineId` and `FetchResponseMsg`.

Let's see how each of them is handled by script:

### > ProcessResponse

[`ScriptThread::handle_fetch_metadata`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L3045)
finds the `ParserContext` for this `Pipeline` and invokes
[`ParserContext::process_response`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/servoparser/mod.rs#L676).
This is the `ParserContext` in `script_thread/dom/servoparser/mod.rs`.

So this part is a bit weird: since each thread only runs a single
`ScriptThread`, a pointer to the instance is
[set](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L653-L655)
in a file global [thread local
variable](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L138).
I'm guessing this is so that methods outside `ScriptThread` (like the parser)
need not be passed a reference to the actual `ScriptThread`, which would couple
code more tightly and probably mess with the borrow-checker as well. This allows
`process_response` to invoke the static method
[`ScriptThread::page_headers_available`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L764),
which retrieves a reference to the `ScriptThread` instance running on this
thread, and invokes
[`handle_page_headers_available`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L2053)
on it.

Then,
[`ScriptThread::load`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L2514)
is invoked, which is the entry point to loading a document. It defines bindings,
sets up the
[`Window`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/window.rs#L171),
[`WindowProxy`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/windowproxy.rs#L58),
and
[`Document`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/document.rs#L253),
starts HTML and CSS parsing, and kicks off the initial layout.  Most important
in our case is the `ScriptMsg::ActivateDocument` message sent to the
`Constellation`.

#### Applying session history change

`Constellation`'s
[`handle_activate_document_msg`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L3308)
is invoked on the other side of the channel. If the load is targeting an iframe,
the iframe's parent pipeline is notified that the document changed. Then,
[`change_session_history`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L3092)
is invoked.  If the currently focused pipeline is the same as, or the child of
the one where the load is occurring, the focused pipeline is changed to the one
which is loading the page.

#### a) New browsing context

If this load is the very first pipeline for its browsing context (i.e. in a new
window or iframe), then that browsing context does not exist yet and is created
now. Recall all the information pertaining to a load stored in
`SessionHistoryChange`? That change is retrieved (in the previous method) and
its fields are passed to
[`new_browsing_context`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L830)
to create the
[`BrowsingContext`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/browsingcontext.rs#L36).
This inserts the new browsing context in `Constellation`'s' `browsing_contexts`
map and if the load targets an iframe, the browsing context is inserted into its
parent pipeline's iframe list (`Pipeline::children`). The document's activity is
set after `new_browsing_context` and a notification is sent to embedder that the
browsing context's history has changed. 

#### b) Existing browsing context

If on the other hand the load is happening in an existing browsing context, the
new pipeline is inserted in the browsing context's session history entries
(`BrowsingContext::pipelines`) and its current entry is updated to be this one
(`BrowsingContext::pipeline`). Then, the current document is
[unloaded](https://html.spec.whatwg.org/multipage/#unload-a-document).

Further, each
[`SessionHistoryChange`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/session_history.rs#L105)
has an optional `replace` field which describes whether the pipeline the load is
replacing needs to be replaced.  `replace` is only not `None` if the load was
initiated in an existing browsing context. If change has such a field and it's
an enum with the variant `NeedsToReload::No(pipeline_id)`, meaning the pipeline
hasn't been closed yet, it is closed now.

On the other hand, if it doesn't have a `replace` field, the
[`JointSessionHistory`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/session_history.rs#L15)
entry for this load's top-level browsing context is retrieved and a
[`SessionHistoryDiff`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/session_history.rs#L169)
is created for the current load, which represents the difference between two
adjacent session history entries. It is an enum with three variants:

- `BrowsingContextDiff`, which represents the change of the active pipeline of
  the browsing context;
- `PipelineDiff`, which is used when the active state of a `Pipeline` changed
  (TODO elaborate);
- and `HashDiff`, about which I quite frankly don't yet know much.

So this part I still don't fully understand but from what I can tell this new
diff is pushed onto the `JointSessionHistory` entry and in exchange other
history entries to close are returned as determined by
`JointSessionHistory::push_diff`.  

Before we go on to remove the pipelines, the activity of the old pipeline in
browsing context and as well as the new one is updated.

##### Closing a pipeline

After having gathered the pipelines and states to close,
[`close_pipeline`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L3716)
is called for each pipeline. This method removes the pipeline id from
`BrowsingContext::pipelines`, closes each, if any, browsing context (iframe) in
pipeline's document via
[`close_browsing_context`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L3616)
(which closes nested pipelines, meaning this and `close_pipeline` end up being
called recursively until the bottom of the frame tree), and if any pending
change is associated with this pipeline, that is also removed.

Note, however, that the `Pipeline` instance isn't actually removed from
`Constellation::pipelines` (and thus dropped) until the pipeline's script thread
indicates it is safe to do so. Thus,
[`Pipeline::exit`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/pipeline.rs#L355)
is called, which sends a `CompositorMsg::PipelineExited` message to the
compositor and a `ConstellationControlMsg::ExitPipeline` to the script thread.

[`ScriptThread::handle_exit_pipeline_msg`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L2190)
picks it up on the other side of the `ConstellationControlMsg::ExitPipeline`
message, and it first removes any incomplete loads associated with this
pipeline, then it shuts down pipeline's layout thread before removing the
document. Finally, a `ScriptMsg::PipelineExited` message is sent back to the
constellation, which removes the pipeline from `Constellation::pipelines`.

##### Trimming the history

Finally, since this load is in an existing browsing context, by calling
[`trim_history`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L3246)
the session history is trimmed for the *top-level browsing context* of the
pipeline handling this load, that is, *its entire frame tree*.

This is rather straight forward. The maximum number of loaded pipelines that may
stay in memory is retrieved from the preferences ("session-history.max-length")
and the same number of fewer pipelines are taken from the past history, then the
same number is taken from the future history. Then we iterate over these
pipelines and close each with `close_pipeline`, as before. Finally, some
bookkeeping is performed and the closed pipelines are updated in the
`JointSessionHistory` so that they are marked as dead and need to be reloaded
the next time they're traversed.

For some reason, `notify_history_changed` is invoked again, which means it's
invoked twice in both cases--once above in each case, and once after the
`match`. Finally, `update_frame_tree_if_active` is invoked on the top-level
browsing context of the session change, which sends the frame tree to the
compositor (i.e. embedder).

### > ProcessResponseChunk

`ScriptThread::handle_fetch_chunk`, as `handle_fetch_metadata` above, finds the
`ParserContext` for this `Pipeline` and invokes
`ParserContext::process_response_chunk`, after which we eventually end up in
[`ParserContext::do_parse_sync`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/servoparser/mod.rs#L472).
This does the heavy-lifting and if the entire response body was received,
[`ParserContext::finish`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/servoparser/mod.rs#L545)
is invoked. Otherwise, we wait for more chunks or an explicit EOF signal.

### > ProcessResponseEOF

`ScriptThread::handle_fetch_eof`, like the previous two, finds the
`ParserContext` for this `Pipeline` and invokes `process_response_eof`, and
here, too, we end up in `do_parse_sync`.

This time, however, if nothing went wrong and the parser is not suspended, the
`finish` member is invoked, which sets the document's read state to interactive,
clears the document's parser, and invokes
[`Document::finish_load`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/document.rs#L1691).
Unless the document loader is blocked (TODO what does this mean?), the same way
as above, `ScriptThread`'s `mark_document_with_no_blocked_loads` is invoked,
which is a static function and merely inserts this document into
[`docs_with_no_blocking_loads`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L583).

The interesting thing is that the document is not immediately finalized, because
there may be other events the script thread need process first. The event loop
is run in
[`ScriptThread::start`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L1075),
continuously invoking `handle_msgs` until shutdown. This does a bunch of things
not (directly) related to this blog post right now, so I'm skipping over to the
part where this `Document` and potentially others are
[dequeued](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/script_thread.rs#L1252-L1256)
from `ScriptThread`'s `docs_with_no_blocking_loads` and
[`maybe_queue_document_completion`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/document.rs#L1869)
method is invoked on each `Document` instance.

This again does a whole host of things, but the important bits are that the
document state is set to complete (`DocumentReadyState::Complete`), the window
is reflowed and scrolled to a fragment if present in the URL, and the
constellation is
[notified](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/document.rs#L1922)
of the document load, via `ScriptMsg::LoadComplete`.

`Constellation` handles this with
[`handle_load_complete_msg`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L2199).
If the load occurred in a top-level browsing context, the embedder is notified
that its document finished loading.  Otherwise it's an iframe and
`handle_subframe_loaded` is called. This sends a
`ConstellationControlMsg::DispatchIFrameLoadEvent` to iframe's parent pipeline's
event loop.

[`ScriptThread::handle_iframe_load_event`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/constellation/constellation.rs#L1699)
takes over, and finds the iframe's encompassing `Document`, then the
`HTMLIFrameElement` in which the load matured and invokes
[`iframe_load_event_steps`](https://github.com/servo/servo/blob/9d52fb88abf3843c7db338120e9f518a1834f80f/components/script/dom/htmliframeelement.rs#L396)
on it. This fires the load event for the iframe, terminates the `LoadBlocker`
(TODO what's this?) and issues a window reflow.

### > ProcessRequestBody and ProcessRequestEOF

These are not implemented at the time of this post's writing.

## Fin

As far as I can tell, these are most of the steps necessary to load a page in
Servo.
