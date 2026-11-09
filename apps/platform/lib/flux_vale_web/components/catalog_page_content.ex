defmodule FluxValeWeb.CatalogPageContent do
  @moduledoc """
  The catalog app page's generated copy (#611 plan §5.3, S3): the
  platform constants one edit changes every page with — benefits rows,
  FAQ answers, CTA text — plus the pure generators that shape an app's
  FAQ columns and similar-app peers. No HTML, no reads: generators take
  plain app/version-shaped maps and return render-ready items, so the
  copy tests never boot the endpoint. Every static string is a gettext
  msgid (the public surfaces' rule); data (names, rates, credit) rides
  placeholders, never the msgid.
  """

  use Gettext, backend: FluxValeWeb.Gettext

  alias FluxVale.Accounts
  alias FluxVale.Pricing
  alias FluxValeWeb.CatalogPageComponents

  @type benefit :: %{title: String.t(), body: String.t()}

  @type faq_item :: %{
          question: String.t(),
          answer: String.t(),
          open: boolean(),
          link: %{href: String.t(), label: String.t()} | nil
        }

  @sso_guide_path "/docs/guides/sso"

  @doc """
  The benefits checklist (plan §7.4, D8): seven platform constants plus
  the SSO row when the version declares an OIDC surface and the WebDAV
  row when the app declares file access. Deliberately no
  automatic-update claim — versions are pinned and tested, and an
  update flow is not shipped.
  """
  @spec benefits(%{oidc?: boolean(), file_access?: boolean()}) :: [benefit()]
  def benefits(%{oidc?: oidc?, file_access?: file_access?}) do
    [
      %{
        title: gettext("Predictable pricing"),
        body: gettext("One rate for the resources you pick, billed hourly. No subscriptions.")
      },
      %{
        title: gettext("Sleep by default"),
        body:
          gettext(
            "An idle app sleeps after an hour and wakes on the next visit, usually in seconds."
          )
      },
      %{
        title: gettext("Your data stays yours"),
        body: gettext("No ads, no profiling, no platform-side copies of your app data.")
      },
      %{
        title: gettext("Backups to your own bucket"),
        body:
          gettext(
            "Nightly encrypted snapshots to your S3-compatible storage, restorable in place."
          )
      },
      %{
        title: gettext("Free HTTPS, your own domain"),
        body:
          gettext(
            "Every instance gets a fluxvale.app address and a certificate. Custom domains ride the private-access lane."
          )
      },
      %{
        title: gettext("Pinned, tested upstream versions"),
        body: gettext("We publish one tested version per app and track upstream releases.")
      },
      %{
        title: gettext("One region, honestly"),
        body: gettext("Everything runs in Nuremberg, EU. More regions are planned.")
      }
    ]
    |> append_row(oidc?, %{
      title: gettext("SSO with Pocket ID"),
      body: gettext("Connect apps that speak OpenID Connect to your own Pocket ID.")
    })
    |> append_row(file_access?, %{
      title: gettext("Files over WebDAV"),
      body: gettext("Move a library in over WebDAV, no SSH needed.")
    })
  end

  @doc """
  The FAQ's setup column (plan §7.5): five platform rows, then the
  Pocket ID row when the version declares OIDC and the files row when
  the app declares file access. `newest_version` nil (no versions)
  keeps the column whole — every row then reads its fallback.
  """
  @spec faq_setup_items(map(), map() | nil) :: [faq_item()]
  def faq_setup_items(app, newest_version) do
    [
      setup_item(app.name, newest_version),
      server_item(),
      cost_item(app.name, newest_version),
      sleep_item(),
      backup_item()
    ]
    |> append_item(oidc?(newest_version), pocket_id_item())
    |> append_item(app.file_access, webdav_item())
  end

  @doc """
  The FAQ's about column (plan §7.5): the platform constants with the
  data-ownership answer open (D11), the alternatives row only when the
  app carries alternatives, then the app's own FAQ items appended
  here — once, in the about column only. The plan's §7.5 table lists
  `App.faq` under both columns; rendering the same questions twice
  would read as a bug, so this is the one deliberate divergence.
  """
  @spec faq_about_items(map()) :: [faq_item()]
  def faq_about_items(app) do
    platform_rows = [ownership_item(), replace_item(app), export_item(), region_item()]
    platform_items = Enum.reject(platform_rows, &is_nil/1)

    platform_items ++ Enum.map(app.faq || [], &app_item/1)
  end

  @doc """
  The similar-apps peers (plan §6.4): same category, excluding self,
  name order, capped at 4. Fewer than two peers is the caller's
  fallback case (the browse card) — honest, no invented similarity.
  """
  @spec similar_apps(map(), [map()]) :: [map()]
  def similar_apps(app, category_apps) do
    category_apps
    |> Enum.reject(&(&1.id == app.id))
    |> Enum.sort_by(& &1.name)
    |> Enum.take(4)
  end

  @doc """
  The closing CTA copy (plan §7.6). The welcome-credit figure reads
  `Accounts.welcome_grant_cents/0` through `Pricing.format_usd/1` —
  never a literal.
  """
  @spec closing_cta(String.t()) :: %{
          heading: String.t(),
          sub: String.t(),
          primary: String.t(),
          ghost: String.t()
        }
  def closing_cta(name) do
    amount = Pricing.format_usd(Accounts.welcome_grant_cents())

    %{
      heading: gettext("Ready to run %{name}?", name: name),
      sub:
        gettext(
          "New accounts start with %{amount} in welcome credit. Deploy in minutes.",
          amount: amount
        ),
      primary: gettext("Deploy %{name}", name: name),
      ghost: gettext("Browse the catalog")
    }
  end

  # The setup column's rows, in plan order. The first row's answer is
  # the newest version's first-run guidance, else the out-of-box
  # constant — a no-versions app falls to the same constant.
  defp setup_item(name, newest_version) do
    answer =
      case first_run_guidance(newest_version) do
        nil ->
          gettext("Deploy it and open the URL. %{name} is ready to use out of the box.",
            name: name
          )

        guidance ->
          guidance
      end

    question(gettext("How do I set up %{name}?", name: name), answer)
  end

  defp first_run_guidance(nil), do: nil

  defp first_run_guidance(version) do
    case version.first_run do
      nil -> nil
      %{guidance: guidance} -> guidance
    end
  end

  defp server_item do
    question(
      gettext("Do I need my own server or Docker?"),
      gettext(
        "No. FluxVale runs it on managed Kubernetes. You pick a name and resources, and the platform handles the rest."
      )
    )
  end

  defp cost_item(name, version) do
    answer =
      case rates(version) do
        %{monthly_cents: monthly_cents} ->
          gettext(
            "Starts at %{rate}/mo at the recommended size, billed hourly from your wallet. Storage bills per GB and keeps billing while the app sleeps.",
            rate: Pricing.format_usd(monthly_cents)
          )

        nil ->
          gettext(
            "It depends on the resources you pick. Compute bills hourly from your wallet at one flat rate. Storage bills per GB and keeps billing while the app sleeps. The deploy step shows the exact figure before you confirm."
          )
      end

    question(gettext("What does %{name} cost?", name: name), answer)
  end

  defp sleep_item do
    question(
      gettext("Does it stop when nobody uses it?"),
      gettext(
        "An idle app sleeps after an hour and wakes on the next visit, usually in seconds. You pay only storage while it sleeps. Turn on always-on for an app that must never sleep."
      )
    )
  end

  defp backup_item do
    question(
      gettext("How do I back it up?"),
      gettext(
        "Backups go to your own S3-compatible bucket, encrypted before they leave the cluster. Snapshots run daily, and you can restore the latest one from the instance page."
      )
    )
  end

  defp pocket_id_item do
    %{
      question: gettext("Can I sign in with my Pocket ID?"),
      answer:
        gettext(
          "Yes. This app speaks OpenID Connect, so it can hand its sign-in to your own Pocket ID instance. Some apps wire up at deploy time and others in their own settings. The guide covers each app."
        ),
      open: false,
      link: %{href: @sso_guide_path, label: gettext("Read the SSO guide")}
    }
  end

  defp webdav_item do
    question(
      gettext("How do I move files in?"),
      gettext(
        "Over WebDAV. The instance page shows the app's /dav address and its username and password. Point any WebDAV client there and copy your files in."
      )
    )
  end

  # The about column's rows, in plan order.

  defp ownership_item do
    %{
      question: gettext("Who owns the data I keep on FluxVale?"),
      answer:
        gettext(
          "You do. Your app data lives on your instance's volume. Enable file access or your own backup bucket and it is there to download, migrate, edit, or delete. The platform takes no copies."
        ),
      # D11: the strongest promise starts open, matching the reference.
      open: true,
      link: nil
    }
  end

  defp replace_item(app) do
    case CatalogPageComponents.alternative_to(app.alternatives) do
      nil -> nil
      answer -> question(gettext("What does %{name} replace?", name: app.name), answer)
    end
  end

  defp export_item do
    question(
      gettext("Can I export my data and leave?"),
      gettext(
        "Yes. The apps are open-source and their formats are yours. Backups land in your own bucket in standard restic format, so the data leaves with you. Apps with file access also serve their files over WebDAV."
      )
    )
  end

  defp region_item do
    question(
      gettext("Which region does it run in?"),
      gettext(
        "Nuremberg, in the European Union. There is one region today, and the architecture is built so more can follow."
      )
    )
  end

  # An App.faq item (Types.FaqList shape) into the row shape — never
  # open, never linked.
  defp app_item(%{question: question, answer: answer}), do: question(question, answer)

  defp question(question, answer),
    do: %{question: question, answer: answer, open: false, link: nil}

  defp rates(nil), do: nil

  defp rates(version), do: Pricing.version_rates(version)

  # The version declares an OIDC consumer surface either way (the
  # oidc_callback_path stance) — a deliberate twin of the components'
  # private oidc?/1 (the price_badge precedent: one shape, two lanes).
  defp oidc?(nil), do: false

  defp oidc?(version),
    do: not is_nil(version.oidc_callback_path) or not is_nil(version.oidc_wiring)

  defp append_row(rows, false, _row), do: rows
  defp append_row(rows, true, row), do: rows ++ [row]

  defp append_item(items, false, _item), do: items
  defp append_item(items, true, item), do: items ++ [item]
end
