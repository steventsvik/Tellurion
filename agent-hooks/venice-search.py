#!/usr/bin/env python3
"""The web search a Codex session on Venice gets, as an MCP server on stdin and stdout.

Commands in a session have no network, and Codex's own search runs on OpenAI's servers, so this is
how it searches. It tries Exa's hosted server, which needs no key, and goes to SearXNG when Exa is
limited or down. Exa's code limits keyless use by IP address to 2 searches a second and 50 a day.

Usage: venice-search.py --folder FOLDER
FOLDER may hold "searxng-url", the SearXNG to use; otherwise it's the one `tellurion venice search
setup` runs. Only the standard library, so it runs wherever Python does.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

EXA_URL = "https://mcp.exa.ai/mcp"
SEARXNG_URL = "http://127.0.0.1:8899"
TIMEOUT = 25
MAX_RESPONSE = 8 * 1024 * 1024
MAX_RESULTS = 10
USER_AGENT = "Tellurion"
# A daily limit reports a long wait, and a session shouldn't ask again until it's over.
LONGEST_COOLDOWN = 24 * 3600

SEARCH_TOOL = {
    "name": "web_search",
    "description": "Search the web. Returns titles, addresses and text from the results.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "query": {"type": "string", "description": "What to search for"},
            "num_results": {"type": "integer", "minimum": 1, "maximum": MAX_RESULTS},
        },
        "required": ["query"],
    },
    "annotations": {"readOnlyHint": True, "openWorldHint": True},
}
FETCH_TOOL = {
    "name": "web_fetch",
    "description": "Read web pages by address. Only works while Exa is available.",
    "inputSchema": {
        "type": "object",
        "properties": {"urls": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 5}},
        "required": ["urls"],
    },
    "annotations": {"readOnlyHint": True, "openWorldHint": True},
}


class Unavailable(Exception):
    """This source can't answer now. The message is for the person reading the session."""


def read_limited(response):
    data = response.read(MAX_RESPONSE + 1)
    if len(data) > MAX_RESPONSE:
        raise Unavailable("the answer was too large")
    return data.decode("utf-8", "replace")


class Exa:
    def __init__(self, url):
        self.url = url
        self.session = None
        self.resting_until = 0.0
        self.next_id = 0

    def _post(self, method, params):
        self.next_id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params}).encode()
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                   "User-Agent": USER_AGENT}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        request = urllib.request.Request(self.url, data=body, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
                self.session = response.headers.get("Mcp-Session-Id") or self.session
                text = read_limited(response)
        except urllib.error.HTTPError as error:
            if error.code == 429:
                self.resting_until = time.time() + self._wait(error.headers.get("Retry-After"))
                raise Unavailable("Exa's free limit is reached") from error
            if error.code in (400, 404):  # the session ended: the next call starts another
                self.session = None
            raise Unavailable(f"Exa answered {error.code}") from error
        except (OSError, ValueError) as error:
            raise Unavailable(f"Exa can't be reached ({error})") from error
        return self._parse(text)

    @staticmethod
    def _wait(retry_after):
        try:
            return min(max(float(retry_after), 1.0), LONGEST_COOLDOWN)
        except (TypeError, ValueError):
            return 60.0

    @staticmethod
    def _parse(text):
        """Exa answers as JSON or as server-sent events."""
        lines = [line[5:].strip() for line in text.splitlines() if line.startswith("data:")] or [text]
        for line in lines:
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if isinstance(message, dict) and ("result" in message or "error" in message):
                return message
        raise Unavailable("Exa's answer couldn't be read")

    def call(self, tool, arguments):
        if time.time() < self.resting_until:
            raise Unavailable("Exa's free limit is reached")
        if not self.session:
            self._post("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                      "clientInfo": {"name": "tellurion", "version": "1"}})
        message = self._post("tools/call", {"name": tool, "arguments": arguments})
        result = message.get("result")
        if not isinstance(result, dict) or result.get("isError"):
            raise Unavailable("Exa couldn't answer that")
        return "\n".join(part.get("text", "") for part in result.get("content", []) if isinstance(part, dict))


def searxng(base, query, count):
    address = base.rstrip("/") + "/search?" + urllib.parse.urlencode({"q": query, "format": "json"})
    if not address.lower().startswith(("http://", "https://")):
        raise Unavailable("the SearXNG address isn't http or https")
    request = urllib.request.Request(address, headers={"Accept": "application/json", "User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            answer = json.loads(read_limited(response))
    except urllib.error.HTTPError as error:
        if error.code == 403:
            raise Unavailable("SearXNG refuses JSON: add json under search.formats in its settings") from error
        raise Unavailable(f"SearXNG answered {error.code}") from error
    except ValueError as error:
        raise Unavailable("SearXNG's answer couldn't be read") from error
    except OSError as error:
        raise Unavailable("SearXNG isn't running (set it up with: tellurion venice search setup)") from error
    results = answer.get("results") if isinstance(answer, dict) else None
    if not isinstance(results, list):
        raise Unavailable("SearXNG's answer couldn't be read")
    blocks = [f"Title: {item.get('title', '')}\nURL: {item.get('url', '')}\n{item.get('content', '')}".rstrip()
              for item in results[:count] if isinstance(item, dict)]
    if not blocks:
        engines = answer.get("unresponsive_engines") or []
        if engines:
            raise Unavailable("SearXNG's search engines didn't answer")
        return "No results."
    return "\n\n".join(blocks)


class Search:
    def __init__(self, exa_url, searxng_url):
        self.exa = Exa(exa_url)
        self.searxng_url = searxng_url

    def web_search(self, arguments):
        query = arguments.get("query")
        if not isinstance(query, str) or not query.strip():
            return "Give a query to search for.", True
        count = arguments.get("num_results", 5)
        count = min(max(count, 1), MAX_RESULTS) if isinstance(count, int) and not isinstance(count, bool) else 5
        problems = []
        try:
            return self.exa.call("web_search_exa", {"query": query, "objective": query, "numResults": count}), False
        except Unavailable as problem:
            problems.append(str(problem))
        try:
            return searxng(self.searxng_url, query, count), False
        except Unavailable as problem:
            problems.append(str(problem))
        return self._stop(problems), True

    def web_fetch(self, arguments):
        urls = arguments.get("urls")
        if not isinstance(urls, list) or not urls or not all(isinstance(url, str) for url in urls):
            return "Give the addresses to read.", True
        try:
            return self.exa.call("web_fetch_exa", {"urls": urls[:5]}), False
        except Unavailable as problem:
            # Not fetched from here: this runs outside the sandbox, and could reach this Mac's own services.
            return self._stop([str(problem)]), True

    @staticmethod
    def _stop(problems):
        # An agent told only that this failed goes looking for another way, and pays for each try.
        return ("The web isn't available right now: " + "; ".join(problems) +
                ". Don't look for another way to reach it. Carry on without it, or tell the user.")


def handle(search, message):
    method, identifier = message.get("method"), message.get("id")
    if identifier is None:
        return None
    if method == "initialize":
        version = (message.get("params") or {}).get("protocolVersion") or "2025-06-18"
        result = {"protocolVersion": version, "capabilities": {"tools": {}},
                  "serverInfo": {"name": "tellurion-search", "version": "1"}}
    elif method == "ping":
        result = {}
    elif method == "tools/list":
        result = {"tools": [SEARCH_TOOL, FETCH_TOOL]}
    elif method == "tools/call":
        params = message.get("params") or {}
        tool = {"web_search": search.web_search, "web_fetch": search.web_fetch}.get(params.get("name"))
        if tool is None:
            return {"jsonrpc": "2.0", "id": identifier, "error": {"code": -32602, "message": "No such tool"}}
        arguments = params.get("arguments")
        text, failed = tool(arguments if isinstance(arguments, dict) else {})
        result = {"content": [{"type": "text", "text": text}], "isError": failed}
    else:
        return {"jsonrpc": "2.0", "id": identifier, "error": {"code": -32601, "message": "No such method"}}
    return {"jsonrpc": "2.0", "id": identifier, "result": result}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--folder", required=True)
    parser.add_argument("--exa-url", default=EXA_URL)
    parser.add_argument("--searxng-url", default=SEARXNG_URL)
    arguments = parser.parse_args()
    address = arguments.searxng_url
    try:
        with open(os.path.join(arguments.folder, "searxng-url"), encoding="utf-8") as file:
            address = file.read().strip() or arguments.searxng_url
    except OSError:
        pass
    search = Search(arguments.exa_url, address)
    for line in sys.stdin:
        try:
            message = json.loads(line)
        except ValueError:
            continue
        if isinstance(message, dict):
            reply = handle(search, message)
            if reply is not None:
                sys.stdout.write(json.dumps(reply) + "\n")
                sys.stdout.flush()


if __name__ == "__main__":
    main()
