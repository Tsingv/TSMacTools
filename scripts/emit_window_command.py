#!/usr/bin/env python3

import json

print(json.dumps({
    "command": "window.show",
    "id": "python-demo",
    "title": "Python Demo",
    "format": "markdown",
    "body": "# Hello from Python\n\nThis JSON command is the first external scripting contract."
}))
