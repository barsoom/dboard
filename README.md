[![Ruby CI](https://github.com/barsoom/dboard/actions/workflows/ci.yml/badge.svg)](https://github.com/barsoom/dboard/actions/workflows/ci.yml)

A dashboard framework.

It handles collecting data from user defined sources (simple ruby classes) and provides a simple API to poll for updates. See the [example app](https://github.com/joakimk/dboard_example) for information on how to use it.

It's stable and has been in use for quite a while.

Dboard is two parts:

* The collection process you run on your server. It polls sources for data and sends it to your dashboard web server.
* The API which combined with for example sinatra (and memcached) becomes a dashboard web server.

Things dboard do for you:

* Calls your classes for data as often as you have specified.
* Sends the data to the dashboard web app.
* Receives and stores the data in the dashboard web app.
* Provides an API to get data to display on the dashboard.
* Keeps the latest data in memcache so that all data is available when you visit the databoard, even data from slow or rarely updated sources (like external APIs).
* Provides a javascript client that knows how to talk to the API (for now it's only included in the [example app](https://github.com/joakimk/dboard_example))
* Only calls your javascript widgets when there is new data.

Refreshing sources:

Each source defines `update_interval` (seconds), and the collector polls it on that cadence.

You can also trigger an out-of-band refresh (e.g. from an inbound webhook) with `Dboard::Collector.request_update(:key)`, where `:key` is the key the source was registered under. This is throttled: the first trigger refreshes immediately, and further triggers inside the floor window are coalesced into a single trailing refresh, so a flood of triggers never causes more than one refresh per floor. The poll and manual triggers share one clock, so a manual refresh lets the next poll cycle skip its fetch.

The floor defaults to 30 seconds. A source may override it by defining `min_update_interval` (seconds). The effective floor is capped at the source's `update_interval`, so it can never exceed the poll interval.

Targeted refreshes:

`request_update` also takes an optional argument for a targeted refresh: `Dboard::Collector.request_update(:key, arg)`. The argument is opaque; the framework forwards it verbatim to the source and never inspects it. Omitting it (or passing `nil`) means a full refresh of the whole source.

A source opts in by defining `fetch(args = nil)`. It receives `nil` for a full refresh (a scheduled poll or a no-arg `request_update`) and an array of the accumulated arguments for a targeted refresh. Arguments are batched the same way triggers are coalesced: the leading refresh carries the first argument, and any arguments that arrive during the active window are delivered together in the one trailing refresh. A no-arg (full) request queued during a burst wins over pending arguments, since a full refresh already covers them. The poll shares the same clock and floor as targeted refreshes, so both together still fetch at most once per floor.

Publishing stays wholesale: the collector always replaces the stored blob for the key. A source doing a targeted refresh must therefore read its current state (e.g. from the cache) and return the full merged blob, not only the refreshed part.

Data flow:

    +-----------------+              +--------------------+
    |                 |              |                    |
    |   Collector     | Pushes data  |   Dashboard web    |
    |                 +--------------+   server           +----+
    |                 |              |                    |    |
    +-----------------+              +--------------------+    | Polls for updates
       |           |                                           |
       |           |                                           |
    +--+--+     +--+--+                         +--------------+-------------+
    |     |     |     |                         |                            |
    |     |     |     |                         |  Dashboard page            |
    +-----+     +-----+                         |                            |
    Source A    Source B                        |                            |
                                                |  See the example app.      |
                                                |                            |
                                                |                            |
                                                |                            |
                                                |                            |
                                                |                            |
                                                |                            |
                                                |                            |
                                                |                            |
                                                |                            |
                                                +----------------------------+

The ASCII drawing above was created using [http://www.asciiflow.com/](http://www.asciiflow.com/).

Todo:

* Include the client side dashboard script (see the [example app](https://github.com/joakimk/dboard_example) for now).
* Provide additional tools for creating dashboards (layout css, graphical widgets, etc). Probably as another gem.
* Tools for deployment (if it can be made generic enough), otherwise a general guide.
* Make the example app a bit more realistic. Dev-mode tools (foreman, guard, auto-reload-sources), use the collector, layout, more sources, etc.
* If someone wants to add it: support for pushing data to the client using web sockets.
