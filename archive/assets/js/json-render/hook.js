import React from "react"
import { createRoot } from "react-dom/client"
import {
  Renderer,
  StateProvider,
  VisibilityProvider,
  ActionProvider,
} from "@json-render/react"
import { nestedToFlat, parseSpecStreamLine, applySpecPatch } from "@json-render/core"
import { registry } from "./registry"

/**
 * LiveView hook that mounts a json-render React renderer.
 *
 * Supports two data formats (indicated by the `data-format` attribute):
 *
 * 1. **JSONL patches** (`data-format="jsonl"`):
 *    The element's `data-spec` contains JSONL lines — one RFC 6902 JSON Patch
 *    operation per line (the library's native ```spec format).  The hook
 *    applies the patches sequentially to build the flat spec.
 *
 * 2. **JSON spec** (no `data-format`, or legacy):
 *    The element's `data-spec` contains a single JSON object.  If nested
 *    (root is an object with type/props), it is converted to flat format
 *    via `nestedToFlat`.
 */
export const JsonRender = {
  mounted() {
    this._renderSpec()
  },

  updated() {
    this._renderSpec()
  },

  destroyed() {
    if (this._root) {
      this._root.unmount()
      this._root = null
    }
  },

  _renderSpec() {
    try {
      const format = this.el.dataset.format
      const rawText = this.el.dataset.spec
      let spec

      if (format === "jsonl") {
        spec = buildSpecFromJsonl(rawText)
      } else {
        spec = buildSpecFromJson(rawText)
      }

      if (!spec || !spec.root) {
        throw new Error("Spec has no root element")
      }

      if (!this._root) {
        this._root = createRoot(this.el)
      }

      this._root.render(
        React.createElement(
          StateProvider,
          { initialState: spec.state ?? {} },
          React.createElement(
            VisibilityProvider,
            null,
            React.createElement(
              ActionProvider,
              null,
              React.createElement(Renderer, { spec, registry })
            )
          )
        )
      )
    } catch (e) {
      console.error("[JsonRender] Failed to render spec:", e)
      this.el.innerHTML =
        '<div class="rounded-lg bg-error/10 border border-error/30 p-3 text-xs">' +
        '<p class="font-semibold text-error mb-1">Failed to render visual response</p>' +
        '<pre class="text-base-content/70 overflow-x-auto whitespace-pre-wrap">' +
        escapeHtml(this.el.dataset.spec) +
        "</pre></div>"
    }
  },
}

/**
 * Parse JSONL lines (RFC 6902 patches) and apply them to build a flat spec.
 */
function buildSpecFromJsonl(text) {
  let spec = { root: "", elements: {} }

  const lines = text.split("\n")
  for (const line of lines) {
    const trimmed = line.trim()
    if (!trimmed) continue

    const patch = parseSpecStreamLine(trimmed)
    if (patch) {
      spec = applySpecPatch(spec, patch)
    }
  }

  return spec
}

/**
 * Parse a single JSON object as a spec (nested or flat format).
 */
function buildSpecFromJson(text) {
  const raw = JSON.parse(text)

  // Already flat format (root is a string key, elements map exists)
  if (typeof raw.root === "string" && raw.elements) {
    return raw
  }

  // Nested format: root is an object with type/props/children
  if (raw.root && typeof raw.root === "object") {
    return nestedToFlat(raw.root)
  }

  // Bare nested node (no wrapper object)
  return nestedToFlat(raw)
}

function escapeHtml(str) {
  return str
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
}
