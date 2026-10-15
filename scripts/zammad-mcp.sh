#!/usr/bin/env bash
exec env -u PYTHONPATH -u PYTHONHOME mcp-zammad "$@"
