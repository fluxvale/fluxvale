defmodule FluxValeWeb.InstanceLive.DavSnippet do
  @moduledoc """
  The file-access panel's rclone quick-start (#253, ADR-0035 Am. 3):
  one hand-held five-step sequence per platform — install (only if
  needed) → create the local source → `rclone config create` →
  `rclone lsd` verify → `rclone copy` — with the instance's real
  URL and username inline and the password standing in as
  `YOUR_PASSWORD` until the panel's reveal.

  Presentational on purpose: the active tab is server state (the
  instance page's `set-dav-platform` event), so a re-render — the
  password reveal mid-sequence — can't yank the visitor back to the
  default tab. `on_select`/`on_detect` carry the event names; stories
  leave them unset and the tabs render inert.

  The OS-detected default is client-side but server-mapped: the
  `.DavOsDefault` hook pushes the browser's platform string once on
  mount, `guess_platform/1` maps it, and an unrecognized string keeps
  the Linux default. Detection assists, never traps — an explicit tab
  click (which locks the choice, LiveView-side) always wins.
  """

  use FluxValeWeb, :html

  # Tab order per #253: Windows · macOS · Linux. The keys are atoms
  # from this fixed set — user input is matched against it, never
  # converted (no String.to_atom on a client string).
  @platforms [
    %{key: :windows, label: "Windows"},
    %{key: :macos, label: "macOS"},
    %{key: :linux, label: "Linux"}
  ]

  @platform_keys_by_string Map.new(@platforms, fn p -> {Atom.to_string(p.key), p.key} end)

  @doc """
  The platform tabs, in tab order — `{key, label}` shapes keyed for
  testids and DOM ids.
  """
  @spec platforms() :: [%{key: atom(), label: String.t()}]
  def platforms, do: @platforms

  @doc """
  Maps a platform string from the click's `phx-value` to its tab key.
  `nil` for anything unrecognized — callers keep their current tab.
  """
  @spec platform_key(String.t()) :: atom() | nil
  def platform_key(string), do: Map.get(@platform_keys_by_string, string)

  @doc """
  Maps the browser's platform string to a tab key — the server half of
  the OS-detected default. The hook sends `navigator.userAgentData
  .platform` (Chromium) or the legacy `navigator.platform`, either of
  which can also be a full UA string; the substrings below cover all
  three shapes. Mac matches first: "darwin" contains "win". Unknown
  platforms — Android, iOS, empty, or any non-string a client pushes
  over the socket — return `nil`: none of the three sequences serves
  them, so the Linux default stands.
  """
  @spec guess_platform(term()) :: :windows | :macos | :linux | nil
  def guess_platform(platform_string) when is_binary(platform_string) do
    string = String.downcase(platform_string)

    cond do
      string =~ "mac" or string =~ "darwin" -> :macos
      string =~ "win" -> :windows
      string =~ "linux" -> :linux
      true -> nil
    end
  end

  def guess_platform(_other), do: nil

  @doc """
  The five-step sequence for `platform`, `values` (`remote`, `url`,
  `username`, `password`) interpolated inline. Steps 1, 2 and 5 are
  per-platform (installer, shell path syntax); connect and verify are
  the same commands everywhere — Windows folds the connect command to
  one line because PowerShell has no backslash continuation.
  """
  @spec steps(atom(), map()) :: [
          %{title: String.t(), command: String.t(), note: String.t() | nil}
        ]
  def steps(:windows, values) do
    [
      %{
        title: "Install rclone (only if needed)",
        command: "winget install Rclone.Rclone",
        note: "PowerShell — or scoop install rclone · choco install rclone."
      },
      %{
        title: "Create the local source",
        command: "mkdir $env:USERPROFILE\\Books",
        note: source_note()
      },
      connect_step(values, :one_line),
      verify_step(values),
      %{
        title: "Copy",
        command: "rclone copy $env:USERPROFILE\\Books #{values.remote}:library/books --progress",
        note: nil
      }
    ]
  end

  def steps(:macos, values) do
    [
      %{
        title: "Install rclone (only if needed)",
        command: "brew install rclone",
        note: "Via Homebrew (brew.sh) — rclone.org has direct downloads."
      },
      %{title: "Create the local source", command: "mkdir -p ~/Books", note: source_note()},
      connect_step(values, :continued),
      verify_step(values),
      %{
        title: "Copy",
        command: "rclone copy ~/Books #{values.remote}:library/books --progress",
        note: nil
      }
    ]
  end

  def steps(:linux, values) do
    [
      %{
        title: "Install rclone (only if needed)",
        command: "curl https://rclone.org/install.sh | sudo bash",
        note: "Or your distro's package: sudo apt install rclone · sudo dnf install rclone."
      },
      %{title: "Create the local source", command: "mkdir -p ~/Books", note: source_note()},
      connect_step(values, :continued),
      verify_step(values),
      %{
        title: "Copy",
        command: "rclone copy ~/Books #{values.remote}:library/books --progress",
        note: nil
      }
    ]
  end

  @doc """
  The active tab's commands, newline-joined — the copy button's value.
  One platform's sequence, so a Windows visitor can't paste a bash
  line by accident.
  """
  @spec commands(atom(), map()) :: String.t()
  def commands(platform, values) do
    platform
    |> steps(values)
    |> Enum.map_join("\n", & &1.command)
  end

  @doc """
  The quick-start: platform tabs (the active one visible) and the
  per-platform sequences, plus the update-semantics and app-scan notes
  every platform shares (ADR-0035 Am. 2).

  `on_select` names the tab-click event, `on_detect` the OS-detection
  event (rendered as the `.DavOsDefault` hook). Both stay unset in
  stories — no LiveView events fire there.
  """
  attr(:id, :string, required: true, doc: "id prefix — panels, tabs, and testids hang off it")

  attr(:platform, :atom,
    values: [:windows, :macos, :linux],
    required: true,
    doc: "the active tab"
  )

  attr(:url, :string, required: true, doc: "the instance's WebDAV URL")
  attr(:username, :string, required: true, doc: "the WebDAV username")

  attr(:password, :string,
    default: nil,
    doc: "the revealed password; nil renders the placeholder"
  )

  attr(:remote, :string, required: true, doc: "the rclone remote name, e.g. fluxvale-<slug>")

  attr(:on_select, :string,
    default: nil,
    doc: "tab-click event name for the host LiveView; unset renders inert tabs"
  )

  attr(:on_detect, :string,
    default: nil,
    doc: "OS-detection event name; set only on the live instance page"
  )

  def dav_snippet(assigns) do
    values = %{
      remote: assigns.remote,
      url: assigns.url,
      username: assigns.username,
      password: assigns.password || "YOUR_PASSWORD"
    }

    assigns =
      assign(assigns,
        platforms: @platforms,
        steps_by_platform: Map.new(@platforms, fn p -> {p.key, steps(p.key, values)} end),
        copy_value: commands(assigns.platform, values)
      )

    ~H"""
    <%!-- The hook name must be a LITERAL dotted string: the LiveView
    compiler rewrites `.Name` to the colocated registry's qualified
    `Module.Name` only for literal attributes — a dynamic expression
    (`@on_detect && ".Name"`) ships unrewritten and the hook never
    binds (caught by the hostile pre-PR pass). It is attached
    unconditionally like copy_button's; the hook itself no-ops unless
    `data-detect-event` names an event (stories leave it unset). --%>
    <div
      id={"#{@id}-snippet"}
      class="min-w-0 w-full space-y-3"
      phx-hook=".DavOsDefault"
      data-detect-event={@on_detect}
    >
      <div class="flex flex-wrap items-center justify-between gap-2">
        <span class="text-xs font-medium text-ink-muted">rclone setup</span>
        <.copy_button id={"copy-#{@id}-snippet"} value={@copy_value} label="Copy commands" />
      </div>

      <%!-- The tab idiom rides the nav_link states: primary-muted wash
      for the active tab, muted-ink hover for the rest. Plain buttons
      (no roving tabindex): every tab stays keyboard-reachable —
      detection assists, never traps. --%>
      <div
        class="flex gap-1 rounded-lg border border-line bg-panel p-1"
        role="tablist"
        aria-label="Operating system"
        data-testid={"#{@id}-platform-tabs"}
      >
        <button
          :for={platform <- @platforms}
          type="button"
          id={"#{@id}-tab-#{platform.key}"}
          role="tab"
          aria-selected={to_string(platform.key == @platform)}
          aria-controls={"#{@id}-panel-#{platform.key}"}
          phx-click={@on_select}
          phx-value-platform={platform.key}
          class={[
            "flex-1 rounded-md px-3 py-1.5 text-xs font-medium transition-colors",
            platform.key == @platform && "bg-primary-muted text-link",
            platform.key != @platform && "text-ink-muted hover:bg-panel-raised hover:text-ink"
          ]}
          data-testid={"#{@id}-tab-#{platform.key}"}
        >
          {platform.label}
        </button>
      </div>

      <%!-- All three sequences render server-side; the inactive ones
      carry `hidden` (so the tab specs can assert on every platform's
      content without switching). --%>
      <div
        :for={platform <- @platforms}
        id={"#{@id}-panel-#{platform.key}"}
        role="tabpanel"
        aria-labelledby={"#{@id}-tab-#{platform.key}"}
        hidden={platform.key != @platform}
        data-testid={"#{@id}-panel-#{platform.key}"}
      >
        <%!-- The active sequence's list keeps #190's panel-level
        testid (dav-rclone-snippet on the real page); the panels carry
        their own per-platform testids. --%>
        <ol
          class="space-y-3"
          data-testid={platform.key == @platform && "#{@id}-rclone-snippet"}
        >
          <li
            :for={{step, index} <- Enum.with_index(@steps_by_platform[platform.key])}
            class="space-y-1.5"
          >
            <div class="flex items-center gap-2">
              <span
                class="flex size-6 shrink-0 items-center justify-center rounded-full border border-line bg-panel text-xs font-medium text-ink-muted"
                aria-hidden="true"
              >
                {index + 1}
              </span>
              <span class="text-xs font-medium text-ink">{step.title}</span>
            </div>
            <pre
              class="overflow-x-auto rounded-lg bg-panel-raised p-3 text-xs leading-relaxed text-ink-muted"
              phx-no-curly-interpolation
            ><code><%= step.command %></code></pre>
            <p :if={step.note} class="text-xs text-ink-subtle">{step.note}</p>
          </li>
        </ol>
      </div>

      <%!-- ADR-0035 Am. 2's semantics, shared by every platform: copy
      is the safe default (incremental, never deletes), and the app's
      index is separate from the file layer. --%>
      <div class="space-y-1 text-xs text-ink-subtle">
        <p>
          <span class="font-medium text-ink-muted">Keeping it updated:</span>
          <code>rclone copy</code> is incremental and never deletes — re-run it after adding or
          changing files locally; new and changed files upload.
        </p>
        <p>
          <span class="font-medium text-ink-muted">After uploading:</span>
          tell the app — register the folder in its settings and trigger a scan (Kavita:
          Settings → Libraries → add the path, then Scan).
        </p>
      </div>

      <%!-- #253's client half: read the browser's platform string and
      push it once on mount — but only where a host event name is set
      (stories render the hook inert). The server maps the string
      (guess_platform/1) and may switch the default tab; an explicit
      click has already locked the choice by then. --%>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DavOsDefault">
        export default {
          mounted() {
            const event = this.el.dataset.detectEvent
            if (!event) return
            const uaData = navigator.userAgentData
            const platform = (uaData && uaData.platform) || navigator.platform || ""
            this.pushEvent(event, { platform: platform })
          }
        }
      </script>
    </div>
    """
  end

  # The connect command, `--obscure` load-bearing (ADR-0035 Am. 1:
  # rclone misreads the generated 43-char password as pre-obscured
  # ~99% of the time; the flag forces the plaintext reading). Same
  # tokens on every platform — Windows gets one line because
  # PowerShell has no backslash continuation (a trailing-space
  # backtick is a paste trap, not a continuation).
  defp connect_step(values, :continued) do
    %{
      title: "Connect",
      command:
        "rclone config create #{values.remote} webdav \\\n" <>
          "    url #{values.url} vendor rclone user #{values.username} pass '#{values.password}' --obscure",
      note: "Paste the password the Show password button reveals above."
    }
  end

  defp connect_step(values, :one_line) do
    %{
      title: "Connect",
      command:
        "rclone config create #{values.remote} webdav url #{values.url} vendor rclone user #{values.username} pass '#{values.password}' --obscure",
      note: "Paste the password the Show password button reveals above."
    }
  end

  defp verify_step(values) do
    %{
      title: "Verify",
      command: "rclone lsd #{values.remote}:",
      note: "Lists the instance's root directories — auth and URL proven before any transfer."
    }
  end

  defp source_note do
    "Books is an example — any local folder works; the copy step uses the same one."
  end
end
