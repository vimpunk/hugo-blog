---
title: "Servo Internals: Loading & Parsing CSS"
date: 2018-11-24T19:09:19+01:00
draft: true
tags: [rust, servo, css]
author: mandreyel
---


As part of a [series](/post/servo-internals/) I'm doing on Servo, this post
walks through how stylesheets are initially fetched and parsed. It does not
detail how CSS rules are computed and rendered with the document. A tl;dr
version of the execution path can be found
[here](post/servo-internals-load-parse-css/#tl-dr).

<!--more-->

## Entry point

Continuing from where Servo parsed a raw HTML source into a DOM, and more
specifically when each newly created HTML element is [bound to the DOM
tree](/post/servo-create-document.md/#bind-to-tree), the creation of the CSS
stylesheet begins.

There are various ways to include the CSS rules with a document. The first is
defining inline styling on each individual HTML element itself. This is not a
recommended best practice so I'm skipping it. Another would be to define the
stylesheet in a `<style>` tag within the document. Then, there is the `<link
rel="stylesheet" type="text/css href="..">"` way.

## TL;DR

In this summary I only cover loading and parsing a stylesheet from a `<link>`
tag since (as far as I know) that's the most common way, moreover it involves
asynchrony by having to fetch the resource, and thus I deem it a more
interesting case study.

### Bind to tree

- `HTMLLinkElement::bind_to_tree`
- `HTMLLinkElement::handle_stylesheet_url`: parse link URL, parse media list of
  the tag (the `media=".."` attribute), create `style::parser::ParserContext`
  and `script::stylesheet_loader::StylesheetLoader` for the link element

### Load stylesheet

- `StylesheetLoader::load`: create an `Arc` `Mutex` of
  `crate::StylesheetContext` (contains the data, element, document, etc), a
  networking task source, and a `script::network_listener::NetworkListener`
  containing the context (which servers as its generic `Listener`) and the task
  source, a channel pair for async fetch result communication rerouted to call
  `NetworkListener::notify_fetch` on receiving
- `Document::fetch_async`
- `DocumentLoader::fetch_async`: create new `LoadBlocker`
- `DocumentLoader::fetch_async_background`: send `CoreResourceMsg::Fetch` to
  `ResourceChannelManager` with `FetchChannels::ResponseMsg` encapsulating the
  above sender
- `CoreResourceManager::fetch`: spawn new thread
- `fetch::methods::fetch`: [...]
- eventually responses are sent back via the sender passed to `fetch` and
  forwarded by the router
- `NetworkListener::notify_fetch`
- `NetworkListener::notify` (where the generic `action` parameter is
  `FetchResponseMsg` implementing the `Action<StylesheetContext>` trait): create
  `ListenerTask` with the listener's `StylesheetContext` and the
  `FetchResponseMsg` argument and queue task on document's event loop with the
  networking task source

### Process response

- `ScriptThread::handle_msg_from_script`
- `TaskBox::run_box`, which is `ListenerTask::run_box`
- `ListenerTask::run_once`: a bit awkwardly, the `Action<T:
  FetchResponseListener>` trait is implemented for `FetchResponseMsg`, which
  demultiplexes the response type and invokes the appropriate
  `process_request_*` and `process_response*` on the `T` parameter depending on
  the `FetchResponseMsg` variant, passing the variant's field to it, if any
- `StylesheetContext` implements `FetchResponseListener`, where
  `process_response` creates metadata and `process_response_chunk` appends data
  to the context's buffer
- `StylesheetContext::process_response_eof`: if the response's status is OK and
  if mime-type is CSS, and depending on whether this was a link element or an
    `@import` directive in the stylesheet, the raw data is parsed via
    `Stylesheet::{,update_}from_bytes`

### Parse raw input

Let's assume this is the initial link load and not an import load.

- `Stylesheet::from_bytes` (defined separately in `style/encoding_support.rs`)
- `style::encoding_support::decode_stylesheet_bytes`: convert `&[u8]` to
  `Cow<str>`
- `Stylesheet::from_str`
- `StylesheetContents::from_str`
- `Stylesheet::parse_rules`: create `stylesheet::parser::ParserContext`,
  `stylesheet::rule_parser::TopLevelRuleParser`, and iterate over the parsed
  rules by passing top level rule parser to
  `cssparser::RuleListParser::new_for_stylesheet` and collect them in a `Vec`

(in cssparser)

- `RuleListParser::next`: if next byte is `@`, parse an at-rule, otherwise a
  qualified rule

#### Parse at-rule

- parse the at-keyword with `next_including_whitespace_and_comments` and the
  rule with `parse_at_rule`, which is either a block or a non-block at-rule

##### Non-block rule

(back in servo)

- `AtRuleParser::rule_without_block`, which is
  `TopLevelRuleParser::rule_without_block`: parse either an `@import` rule
  (which must come first) or a namespace rule
- for import rules, use the fields in `TopLevelRuleParser` and load stylesheet
- `StylesheetLoader::request_stylesheet`: initiates load with
`StylesheetLoader::load` (just like above) but creates an `Arc` `Mutex` with an
empty `StylesheetContents`, which it gives as a source to `load` and also
returns it (since it's ref counted) to where `RuleListParser::next` was invoked

##### Block rule

- `parse_nested_block` -> `AtRuleParser::parse_block`, which is
  `TopLevelRuleParser::parse_block`
- `NestedRuleParser::parse_block`
- TODO

#### Parse qualified rule

- `parse_qualified_rule`: first parse prelude (the part before the `{ /* … */
  }`) then the rule

##### Parse prelude

- `parse_until_before`: parse prelude by creating a new `Parser` delimited by
  `Delimiter::CurlyBracketBlock`
- `Parser::parse_entirely`
- `QualifiedRuleParser::parse_prelude`, which
  is`TopLevelRuleParser::parse_prelude`

(back in Servo)

- `NestedRuleParser::parse_prelude`: create
  `style::selector_parser::SelectorParser`
- `selectors::parser::SelectorList::parse`: in a loop, parse list of selectors
  with `cssparser::Parser::parse_until_before` and
  `selectors::parser::parse_selector` and finally return
  `SelectorList<SelectorImpl>` (where `SelectorImpl` is an empty struct
  implementing a trait of the same name with type aliases for the various
  selector types (why not an enum?))

###### Parse declaration block

- `parse_nested_block`: parse block by creating a new `Parser` delimited by
  `Delimiter::CurlyBracketBlock`
- `Parser::parse_entirely`
- `QualifiedRuleParser::parse_block`, which is `TopLevelRuleParser::parse_block`

(back in Servo)

- `NestedRuleParser::parse_block`: create `style::parser::ParserContext` from
  own context with overriden CSS rule type
- `style::properties::declaration_block::parse_property_declaration_list`:
  create `PropertyDeclarationParser` with above context and declarations buffer
  and pass to `cssparser::DeclarationListParser` and iterate over results

(in cssparser)

- `DeclarationListParser::next`: in a loop, first parse the declaration
  identifier (with `next_including_whitespace_and_comments`), and if it's an
  identifier (and not an at-keyword or something else), parse value with
  `DeclarationParser::parse_value` by passing property name to it

(in servo)

- `PropertyDeclarationParser::parse_value`: convert property name string to
  `PropertyId` via its `parse` method and then


### Final steps

- after parsing the stylesheet, set it as the link element's stylesheet (which
  will add it to its document), do some cleaning up, and fire a `load` event
