// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/liteskill"
import topbar from "../vendor/topbar"
import {SectionEditor, WikiEditor} from "./codemirror_hook"
import {JsonRender} from "./json-render/hook"

const Hooks = {
  SectionEditor,
  WikiEditor,
  JsonRender,

  OpenExternalUrl: {
    mounted() {
      this.handleEvent("open_external_url", ({ url }) => {
        // In Tauri desktop, open in system browser via shell:open plugin.
        // __TAURI_INTERNALS__ is injected by Tauri into all webview pages.
        if (window.__TAURI_INTERNALS__) {
          window.__TAURI_INTERNALS__.invoke('plugin:shell|open', { path: url })
            .catch((err) => {
              console.error('Tauri shell:open failed, falling back to webview navigation:', err)
              window.location.href = url
            })
        } else {
          window.location.href = url
        }
      })
    }
  },

  SidebarNav: {
    mounted() {
      this.handleEvent("nav", () => {
        if (window.innerWidth < 640) {
          this.pushEvent("close_sidebar", {})
        }
      })
      this.handleEvent("set-accent", ({color}) => {
        if (color && color !== "purple") {
          localStorage.setItem("phx:accent", color)
          document.documentElement.setAttribute("data-accent", color)
        } else {
          localStorage.removeItem("phx:accent")
          document.documentElement.removeAttribute("data-accent")
        }
      })
    }
  },

  ScrollBottom: {
    mounted() {
      this.scrollToBottom()
      this.observer = new MutationObserver(() => {
        if (this.isNearBottom()) this.scrollToBottom()
      })
      this.observer.observe(this.el, { childList: true, subtree: true, characterData: true })
      this.setupCiteHighlight()
    },
    updated() {
      if (this.isNearBottom()) this.scrollToBottom()
    },
    destroyed() {
      if (this.observer) this.observer.disconnect()
    },
    isNearBottom() {
      return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 100
    },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    },
    setupCiteHighlight() {
      this.el.addEventListener("mouseenter", (e) => {
        const cite = e.target.closest(".rag-cite")
        if (!cite) return
        const docId = cite.getAttribute("phx-value-doc-id")
        if (!docId) return
        document.querySelectorAll(`.source-item[data-doc-id="${docId}"]`).forEach(el => {
          el.classList.add("source-item-highlight")
        })
      }, true)
      this.el.addEventListener("mouseleave", (e) => {
        const cite = e.target.closest(".rag-cite")
        if (!cite) return
        const docId = cite.getAttribute("phx-value-doc-id")
        if (!docId) return
        document.querySelectorAll(`.source-item[data-doc-id="${docId}"]`).forEach(el => {
          el.classList.remove("source-item-highlight")
        })
      }, true)
    }
  },

  CopyCode: {
    mounted() { this.addCopyButtons() },
    updated() { this.addCopyButtons() },
    addCopyButtons() {
      this.el.querySelectorAll('pre').forEach(pre => {
        if (pre.querySelector('.copy-btn')) return
        const btn = document.createElement('button')
        btn.className = 'copy-btn'
        btn.type = 'button'
        btn.setAttribute('aria-label', 'Copy code')
        btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>'
        btn.addEventListener('click', () => {
          const code = pre.querySelector('code')
          const text = code ? code.textContent : pre.textContent
          navigator.clipboard.writeText(text).then(() => {
            btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6 9 17l-5-5"/></svg>'
            setTimeout(() => {
              btn.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></svg>'
            }, 2000)
          })
        })
        pre.appendChild(btn)
      })
    }
  },

  DownloadMarkdown: {
    mounted() {
      this.handleEvent("download_markdown", ({filename, content}) => {
        const blob = new Blob([content], {type: "text/markdown"})
        const url = URL.createObjectURL(blob)
        const a = document.createElement("a")
        a.href = url
        a.download = filename
        a.click()
        URL.revokeObjectURL(url)
      })
    }
  },

  PipelineChart: {
    mounted() {
      const COLORS = [
        "#6366f1", "#f59e0b", "#10b981", "#ef4444", "#3b82f6",
        "#8b5cf6", "#ec4899", "#14b8a6", "#f97316", "#06b6d4"
      ]
      import("https://cdn.jsdelivr.net/npm/chart.js@4/+esm").then((mod) => {
        const { Chart, ArcElement, PieController, Tooltip, Legend } = mod
        Chart.register(ArcElement, PieController, Tooltip, Legend)
        const data = JSON.parse(this.el.dataset.chart || "[]")
        const canvas = this.el.querySelector("canvas")
        this.chart = new Chart(canvas, {
          type: "pie",
          data: {
            labels: data.map(d => d.source_name),
            datasets: [{
              data: data.map(d => d.chunk_count),
              backgroundColor: data.map((_, i) => COLORS[i % COLORS.length])
            }]
          },
          options: {
            responsive: true,
            plugins: {
              legend: { position: "bottom", labels: { boxWidth: 12, padding: 8 } }
            }
          }
        })
      })
      this.handleEvent("pipeline_chart_update", ({data}) => {
        if (!this.chart) return
        const parsed = typeof data === "string" ? JSON.parse(data) : data
        this.chart.data.labels = parsed.map(d => d.source_name)
        this.chart.data.datasets[0].data = parsed.map(d => d.chunk_count)
        this.chart.data.datasets[0].backgroundColor = parsed.map((_, i) => COLORS[i % COLORS.length])
        this.chart.update()
      })
    },
    destroyed() { if (this.chart) this.chart.destroy() }
  },

  RunTimer: {
    mounted() {
      this.tick()
      const status = this.el.dataset.status
      if (status === "running") {
        this.interval = setInterval(() => this.tick(), 1000)
      }
    },
    updated() {
      const status = this.el.dataset.status
      if (status !== "running" && this.interval) {
        clearInterval(this.interval)
        this.interval = null
      }
      this.tick()
    },
    destroyed() {
      if (this.interval) clearInterval(this.interval)
    },
    tick() {
      const startedAt = this.el.dataset.startedAt
      if (!startedAt) {
        this.el.innerText = "-"
        return
      }
      const start = new Date(startedAt + "Z")
      const completedAt = this.el.dataset.completedAt
      const end = completedAt ? new Date(completedAt + "Z") : new Date()
      const diffMs = Math.max(0, end - start)
      this.el.innerText = this.formatDuration(diffMs)
    },
    formatDuration(ms) {
      const totalSec = Math.floor(ms / 1000)
      const h = Math.floor(totalSec / 3600)
      const m = Math.floor((totalSec % 3600) / 60)
      const s = totalSec % 60
      if (h > 0) return `${h}h ${m}m ${s}s`
      if (m > 0) return `${m}m ${s}s`
      return `${s}s`
    }
  },

  TextareaAutoResize: {
    mounted() {
      this.el.addEventListener("input", () => this.resize())
      this.el.addEventListener("keydown", (e) => {
        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault()
          this.el.closest("form").dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
        }
      })
      this.resize()
    },
    updated() {
      this.resize()
    },
    resize() {
      this.el.style.height = "auto"
      this.el.style.height = this.el.scrollHeight + "px"
    }
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

