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
import {hooks as colocatedHooks} from "phoenix-colocated/flux_vale"
import topbar from "../vendor/topbar"
import "../vendor/posthog-js-tracing-headers"
import posthog from "../vendor/posthog-js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Generic <details> dismissal (#284): native <details> only closes on a
// summary re-click; this adds the GitHub-style outside-click + Escape
// close. Escape also returns focus to the summary (APG disclosure
// pattern) when focus is inside the panel. Attach to any <details>
// host (phx-hook requires a unique DOM id) — it only flips the host's
// own `open` attribute, so it manages no DOM children and needs no
// phx-update="ignore".
const DetailsDismiss = {
  mounted() {
    this.onDocClick = event => {
      if (this.el.open && !this.el.contains(event.target)) this.el.open = false
    }
    this.onKeyDown = event => {
      if (event.key === "Escape" && this.el.open) {
        if (this.el.contains(document.activeElement)) {
          this.el.querySelector("summary")?.focus()
        }
        this.el.open = false
      }
    }
    document.addEventListener("click", this.onDocClick)
    document.addEventListener("keydown", this.onKeyDown)
  },
  destroyed() {
    document.removeEventListener("click", this.onDocClick)
    document.removeEventListener("keydown", this.onKeyDown)
  },
}

// No longpoll fallback (#215 — phx.new scaffold default, not a decision):
// on a slow edge its poll cycle resurrects the socket mid-sign-out and
// LiveView's isUnloaded guard reloads /, aborting the pending /sign-in
// navigation. WebSocket-only; revisit with an upstream fix for the
// resurrect-after-disconnect race.
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, DetailsDismiss},
})

// #219: the sign-in forms carry native POST fallbacks (action + method)
// for networks that block the WebSocket handshake. LiveView's document
// submit handler intercepts any phx-submit form unconditionally — a
// disconnected push is silently dropped — so let a flagged form submit
// natively while the socket is down. Capture phase runs before
// LiveView's listener; stopping propagation keeps the dropped push from
// ever running. Connected, LiveView owns the submit as before.
document.addEventListener(
  "submit",
  event => {
    const form = event.target
    if (!(form instanceof HTMLFormElement)) return
    if (!form.hasAttribute("data-native-fallback")) return
    if (liveSocket.isConnected()) return
    event.stopImmediatePropagation()
  },
  true,
)

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// In-app PostHog (ADR-0049), gated on the server-rendered hook: absent,
// nothing here runs — no init, no network. Armed, the cookieless
// posture: memory persistence and person_profiles "never" (nothing is
// written to the visitor's device; identity is an event attribute),
// session recording off (replay is off at launch), autocapture on but
// element text dropped by mask_all_text ("which buttons you press",
// never surrounding copy). capture_pageview "history_change" tracks
// LiveView's pushState navigations — the SPA pageview guarantee this
// SDK version documents, so no phx:navigate listener on top (it would
// double-capture). tracing_headers marks our own origin, so same-origin
// fetch/XHR calls carry x-posthog-distinct-id/-session-id for the
// server plug to correlate backend errors to this browser session —
// the patcher covers the app's JS HTTP calls as they appear; LiveView
// itself rides the WebSocket, which the patcher does not touch.
// disable_external_dependency_loading keeps the client fully bundled:
// the SDK would otherwise fetch feature scripts (recorder, surveys,
// the tracing-headers patch) from its asset CDN at runtime — the
// tracing-headers patch is vendored beside it instead, and everything
// else is off in this posture.
const analyticsConfig = document.getElementById("posthog-config")

if (analyticsConfig) {
  const distinctId = analyticsConfig.getAttribute("data-distinct-id")

  posthog.init(analyticsConfig.getAttribute("data-api-key"), {
    api_host: analyticsConfig.getAttribute("data-api-host"),
    persistence: "memory",
    person_profiles: "never",
    disable_session_recording: true,
    disable_external_dependency_loading: true,
    autocapture: true,
    mask_all_text: true,
    capture_pageview: "history_change",
    tracing_headers: [window.location.hostname],
    // Server-known identity (the hook's data-distinct-id): the
    // documented bootstrapping shape. Absent — anonymous surfaces —
    // no identity at all.
    ...(distinctId ? {bootstrap: {distinctID: distinctId, isIdentifiedID: true}} : {}),
  })
}

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

