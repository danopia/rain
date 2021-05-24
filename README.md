# rain

☔

Minimal IRC client in elm.

This port of erik's rain is adapted to connect directly to IRCds
which implement the IRCv3 WebSocket extension.

![screenshot](http://i.imgur.com/PwdHbsl.png)

build dependencies:

  - [elm](https://guide.elm-lang.org/install.html)
  - ~~[node](https://nodejs.org/en/download/) - for `wsproxy`~~
  - [entr](https://github.com/clibs/entr) - for `make watch`

```
    # Install dependencies, build, and run:
    make all dev

    # Frontend:
    http://localhost:8000
```
