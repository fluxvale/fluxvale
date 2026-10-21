// FluxVale Storybook JS (#178) — loaded just before PhoenixStorybook's
// own JS. The design-system components need no LiveView hooks yet; this
// registers the (empty) surface so the workshop is hook-ready.
(function () {
  window.storybook = window.storybook || {};
})();
