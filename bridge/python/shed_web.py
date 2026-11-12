"""Web search and page reading from Python, through Shed's web provider (Firecrawl).

Shed writes this module to ~/.agent-remote/python and puts that folder on the PYTHONPATH of the agents it starts.
It runs the `shed-web` command, which holds the provider's key; see `shed-web --help` for every option.

    from shed_web import search, fetch

    for hit in search("rust async runtimes", limit=5):
        print(hit["title"], hit["url"])

    page = fetch("https://example.com")             # Markdown by default
    print(page["title"], len(page["markdown"]))
    page = fetch("https://example.com", formats=["markdown", "links", "screenshot"])
    print(page["links"][:10], page["screenshotFile"])

Results are whole, however long: print only the part you need.
"""

import json
import os
import shutil
import subprocess

__all__ = ["search", "fetch", "WebError"]


class WebError(RuntimeError):
    """The provider refused the request, or isn't set up on this Mac."""


def _command():
    found = shutil.which("shed-web")
    if found:
        return found
    return os.path.expanduser("~/.agent-remote/bin/shed-web")


def _flag(name):
    return "--" + name.replace("_", "-")


# The query or URL goes after `--` so text starting with `-` is never read as an option; flags go before it.
def _run(subcommand, options, target, timeout):
    try:
        done = subprocess.run(
            [_command(), subcommand, *options, "--json", "--full", "--", target],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except FileNotFoundError:
        raise WebError("shed-web isn't installed on this Mac (it comes with Shed's bridge)") from None
    if done.returncode != 0:
        raise WebError(done.stderr.strip().removeprefix("shed-web: ") or "shed-web failed")
    return json.loads(done.stdout)


def _options(options):
    args = []
    body = options.pop("body", None)
    for name, value in options.items():
        if value is None or value is False:
            continue
        if value is True:
            args.append(_flag(name))
        elif isinstance(value, (list, tuple)):
            args += [_flag(name), ",".join(str(v) for v in value)]
        elif isinstance(value, dict):
            args += [_flag(name), json.dumps(value)]
        else:
            args += [_flag(name), str(value)]
    if body:
        args += ["--body", json.dumps(body)]
    return args


def search(query, *, limit=5, sources=None, categories=None, tbs=None, location=None, country=None,
           scrape=False, body=None, timeout=120):
    """Search the web. Returns a list of results: dicts with `url`, `title`, `snippet`, `kind` (web, news, images)
    and, for news, `publishedAt`. With `scrape=True`, each result also has its page as `markdown` (and `file`, where
    it was saved).

    sources: ["web", "news", "images"]; categories: ["github", "research", "pdf"]; tbs: "qdr:d" (past day), "qdr:w",
    "qdr:m", "qdr:y"; body: more fields for Firecrawl's search request.
    """
    options = _options(dict(
        limit=limit, sources=sources, categories=categories, tbs=tbs, location=location, country=country,
        scrape=scrape, body=body,
    ))
    return _run("search", options, query, timeout)["sources"]


def fetch(url, *, formats=None, prompt=None, schema=None, all_content=False, include_tags=None,
          exclude_tags=None, wait=None, mobile=False, max_age=None, timeout=None, proxy=None, country=None,
          languages=None, out=None, body=None):
    """Read a page. Returns a dict with `url`, `statusCode`, `title`, `metadata`, and one entry per format asked
    for: `markdown` (the default), `summary`, `html` and `rawHtml` (also saved, as `htmlFile` and `rawHtmlFile`),
    `screenshotFile` (a PNG on this Mac), and every other format under the key Firecrawl gives it (`links`,
    `images`, `json`, `answer`, `product`, `audio`, `video`, `branding`, ...; `shed-web --help` lists them).

    formats: e.g. ["markdown", "links", "screenshot@fullPage"]; for "json", give `prompt` (what to extract) and/or
    `schema` (a JSON schema dict); for "query", "question" and "highlights", `prompt` is what to ask the page. all_content: keep navigation, headers and footers. wait, max_age, timeout: in ms.
    country, languages: load the page from a country ("DE"), in languages (["de-DE"]).
    body: more fields for Firecrawl's scrape request.
    """
    options = _options(dict(
        format=formats, prompt=prompt, schema=schema, all_content=all_content, include_tags=include_tags,
        exclude_tags=exclude_tags, wait=wait, mobile=mobile, max_age=max_age, timeout=timeout, proxy=proxy,
        country=country, languages=languages, out=out, body=body,
    ))
    seconds = (timeout or 60_000) / 1000 + 60
    return _run("fetch", options, url, seconds)
