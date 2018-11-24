---
title: "Servo Internals: Creating Documents"
date: 2018-11-23T10:37:21+01:00
draft: true
tags: [rust, servo, dom]
author: mandreyel
---

As part of a [series](/post/servo-internals/) I'm doing on Servo, this post
walks through how documents are initially fetched and parsed, and how the DOM is
constructed. A tl;dr version of the call chain is
[here](/post/servo-create-document/#tl-dr).

<!--more-->

## Entry point

Continuing from where Servo [spawned a
pipeline](/post/servo-internals-load-url/#spawning-a-pipeline) for the page
load, after which a script thread (or event loop, in JS parlance) was spawned
for the document--or if the document attaches to an existing script thread and a
new layout thread is attached to the document (because remember,
similar-origin documents may share an event loop, but they always have their
own layout thread)--eventually `ScriptThread::pre_page_load` will be invoked,
which initiates the navigation request.


## TL;DR

### Initiate page load

- `ScriptThread::pre_page_load`: create `ParserContext`, put into
`incomplete_parser_contexts`, initiate navigation request
- [...] All the steps involved in loading a page, as described
[here](/post/servo-internals-load-url/), up until the point where the
fetch responses are sent back to `Constellation::network_listener_receiver` and
forwarded to `ScriptThread` as a `ConstellationControlMsg::NavigationResponse`.
The various 

### Parse response chunks

- `ScriptThread::handle_fetch_metadata`: find parser context for this laod
- `ParserContext::process_response`: parse HTTP headers, look for errors
- `ScriptThread::handle_page_headers_available`
- `ScriptThread::load`: create `Document`, `Window`, `WindowProxy`, start HTML
parsing
- document becomes Active
- `ServoParser::parse_html_document`: create new parser that is not returned,
instead an empty `DOMString` is parsed with`ServoParser::parse_string_chunk` to
set the parser as the current parser of document; parser is obtained via
`Document::get_current_parser`
- `ScriptThread::handle_fetch_chunk`
- `ParserContext::process_response_chunk`
- `ServoParser::parse_bytes_chunk`: unless suspended, call `do_parse_sync`

### Tokenize input

- `ServoParser::tokenize`: in a loop, check if we need to reflow via associated
`Window`, and then feed input to tokenizer (which may be either HTML, AsyncHTML,
or XML) through a lambda passed to `tokenize`, so that the input source (either
network or `document.write()`) can be abstracted away, and suspend parser if
a pending blocking script is present
- (for simplicity let's assume sync HTML parsing)
- `servoparser::html::Tokenizer::feed`
- [html5ever] `Tokenizer<Sink>::feed` where `Sink =
html5ever::tree_builder::TreeBuilder<Dom<Node>, servoparser::Sink>`
- [html5ever] `Tokenizer<Sink>::run`: repeatedly call `Tokenizer::step` to emit tags parsed
into tokens into Sink via `Sink::process_token`, until step result is
either `ProcessResult::Suspend` or a `<script>` tag is encountered
- [html5ever] `TreeBuilder<Dom<Node>, Sink>::process_token`
- [html5ever] `TreeBuilder<Dom<Node>, Sink>::process_to_completion`: call `step`
on token and if the result is not `Done`, a plain text, script, or raw data
token, continue by either splitting the token on white space or reprocessing as
a foreign token (which a MathML or SVG token, I believe) 
- [html5ever] `TreeBuilder<Dom<Node>, Sink>::step`: advance the tokenizer state
machine and call one of the insertion methods (`insert_element_for`,
`insert_and_pop_element_for`, `insert_appropriately`, etc)

### Create element

- [html5ever] `TreeBuilder<Dom<Node>, Sink>::create_element`: call
`TreeSink::create_element`
- `servoparser::Sink::create_element`
- `servoparser::create_element_for_token`: look up custom element definition if
it exists
- `Element::create`
- `create.rs:create`
- `create.rs:create_html_element`: construct custom or native HTML element
- `create.rs:create_native_html_element`: depending on the tag name, lookup the
corresponding type's constructor, invoke `<type>::new` and return it by
upcasting it to `DomRoot<Element>` via `DomRoot::upcast`
- in the `new` constructor of an element, the new element is returned by first
  creating a `Node`, wrapping that in an `Element`, further wrapping that in an
  `HTMLElement`, and finally wrapping that in the actual element, and reflecting
  the result as a DOM node via `Node::reflect_node` (which calls
  `reflect_dom_object`)
- return to the original insert method

### Insert element in the DOM tree

- [html5ever] `TreeBuilder<Dom<Node>, Sink>::insert_at`: depending on the
insertion point, call one of the `TreeSink` trait's append methods
- `servoparser::Sink::append` 
- `servoparser::insert`
- `Node::InsertBefore` 
- `Node::pre_insert`: ensure insertion validity, adopt node into document
(enqueue script reaction for adoption)
- `Node::insert`
- `Node::add_child`: invoke element's `bind_to_tree` method
