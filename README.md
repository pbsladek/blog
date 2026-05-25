# pbsladek blog

Jekyll blog using the [Minimal Mistakes](https://github.com/mmistakes/minimal-mistakes) theme and GitHub Pages.

## Running locally with Docker

```bash
make dev
```

Open `http://localhost:4100/`.

`make dev` starts at port `4100` and automatically moves to the next open port if `4100` is already busy. LiveReload also uses the next open port starting at `35729`.

## Build check

```bash
make test
```

Run `make help` for the full command list.
