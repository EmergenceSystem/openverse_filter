# openverse_filter

A source filter for **[EmergenceSystem](https://github.com/EmergenceSystem)**, a distributed
discovery network of small agents. It joins the em_pop gossip mesh and answers
`POST /agent/query`: it searches openly-licensed images and audio from Openverse (api.openverse.org), returned as media embryos (thumbnail, source url, license) that render as image / audio / video cards in the Emquest UI.

Emquest fans a query out to many such filters in parallel and aggregates the results,
so each filter stays small and focused on a single source.

## Run

```sh
rebar3 shell
```

Built on [em_filter](https://github.com/EmergenceSystem/em_filter). Apache-2.0.
